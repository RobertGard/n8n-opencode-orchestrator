#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="${OPENCODE_WORKSPACE_ROOT:-/workspace}"
CATALOG_FILE="${OPENCODE_CONFIG_FILE:-}"
ALLOW_POST_BOOTSTRAP="${OPENCODE_ALLOW_POST_BOOTSTRAP:-0}"
WORKSPACE_ROOT_REAL="$(realpath -m -- "${WORKSPACE_ROOT}")"

if [ -z "${CATALOG_FILE}" ] || [ ! -f "${CATALOG_FILE}" ]; then
  printf 'info: repo catalog not found at %s; skipping repo bootstrap\n' "${CATALOG_FILE:-<unset>}"
  exit 0
fi

github_authenticate_url() {
  local repo_url="$1"
  if [ -n "${GITHUB_TOKEN:-}" ] && [[ "${repo_url}" == https://github.com/* ]]; then
    printf '%s' "https://${GITHUB_TOKEN}@github.com/${repo_url#https://github.com/}"
    return
  fi
  printf '%s' "${repo_url}"
}

repo_items() {
  jq -c 'if type == "array" then . else .repos // [] end | map(select((.enabled // true) == true))[]' "${CATALOG_FILE}"
}

compose_file_for_repo() {
  local repo_dir="$1"
  local declared_file="$2"

  if [ -n "${declared_file}" ] && [ -f "${declared_file}" ]; then
    printf '%s\n' "${declared_file}"
    return
  fi

  if [ -n "${declared_file}" ] && [ -f "${repo_dir}/${declared_file}" ]; then
    printf '%s\n' "${repo_dir}/${declared_file}"
    return
  fi

  if [ -f "${repo_dir}/compose.yaml" ]; then
    printf '%s\n' "${repo_dir}/compose.yaml"
    return
  fi

  if [ -f "${repo_dir}/docker-compose.yml" ]; then
    printf '%s\n' "${repo_dir}/docker-compose.yml"
    return
  fi
}

resolve_workspace_path() {
  local input_path="$1"
  local label="$2"
  local resolved

  if [ -z "${input_path}" ]; then
    printf 'error: empty %s is not allowed\n' "${label}" >&2
    exit 1
  fi

  if [[ "${input_path}" = /* ]]; then
    printf 'error: absolute %s is not allowed: %s\n' "${label}" "${input_path}" >&2
    exit 1
  fi

  resolved="$(realpath -m -- "${WORKSPACE_ROOT_REAL}/${input_path}")"
  case "${resolved}" in
    "${WORKSPACE_ROOT_REAL}"|"${WORKSPACE_ROOT_REAL}"/*) printf '%s' "${resolved}" ;;
    *)
      printf 'error: %s escapes workspace root: %s\n' "${label}" "${input_path}" >&2
      exit 1
      ;;
  esac
}

resolve_repo_relative_path() {
  local repo_dir="$1"
  local input_path="$2"
  local label="$3"
  local repo_dir_real
  local resolved

  repo_dir_real="$(realpath -m -- "${repo_dir}")"

  if [ -z "${input_path}" ]; then
    return 0
  fi

  if [[ "${input_path}" = /* ]]; then
    printf 'error: absolute %s is not allowed: %s\n' "${label}" "${input_path}" >&2
    exit 1
  fi

  resolved="$(realpath -m -- "${repo_dir_real}/${input_path}")"
  case "${resolved}" in
    "${repo_dir_real}"|"${repo_dir_real}"/*) printf '%s' "${resolved}" ;;
    *)
      printf 'error: %s escapes repo root: %s\n' "${label}" "${input_path}" >&2
      exit 1
      ;;
  esac
}

post_bootstrap_allowed() {
  case "${ALLOW_POST_BOOTSTRAP}" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

install_repo_dependencies() {
  local repo_dir="$1"
  local package_manager="$2"

  case "${package_manager}" in
    pnpm)
      pnpm install --dir "${repo_dir}"
      ;;
    bun)
      bun install --cwd "${repo_dir}"
      ;;
    npm-ci)
      npm ci --prefix "${repo_dir}"
      ;;
    npm)
      npm install --prefix "${repo_dir}"
      ;;
    auto)
      if [ -f "${repo_dir}/pnpm-lock.yaml" ]; then
        pnpm install --dir "${repo_dir}"
      elif [ -f "${repo_dir}/bun.lockb" ] || [ -f "${repo_dir}/bun.lock" ]; then
        bun install --cwd "${repo_dir}"
      elif [ -f "${repo_dir}/package-lock.json" ]; then
        npm ci --prefix "${repo_dir}"
      elif [ -f "${repo_dir}/package.json" ]; then
        npm install --prefix "${repo_dir}"
      fi
      ;;
  esac
}

run_turbo_smoke() {
  local repo_dir="$1"
  local tasks_csv="$2"

  if [ ! -f "${repo_dir}/turbo.json" ]; then
    return
  fi

  local tasks=()
  IFS=',' read -r -a tasks <<< "${tasks_csv}"
  if [ "${#tasks[@]}" -eq 0 ]; then
    return
  fi

  turbo run "${tasks[@]}" --continue --cache-dir .turbo --cwd "${repo_dir}" || true
}

docker_compose() {
  if docker compose "$@" 2>/dev/null; then
    return 0
  fi
  docker-compose "$@"
}

while IFS= read -r repo; do
  slug="$(printf '%s' "${repo}" | jq -r '.slug')"
  repo_url="$(printf '%s' "${repo}" | jq -r '.url')"
  repo_ref="$(printf '%s' "${repo}" | jq -r '.ref // "main"')"
  repo_path="$(printf '%s' "${repo}" | jq -r '.path // .slug')"
  package_manager="$(printf '%s' "${repo}" | jq -r '.package_manager // "auto"')"
  turbo_smoke="$(printf '%s' "${repo}" | jq -r '.turbo_smoke // false')"
  turbo_tasks="$(printf '%s' "${repo}" | jq -r '(.turbo_tasks // ["build","test"]) | join(",")')"
  # install_gsd_local removed — tooling.npm handles all package installation
  post_bootstrap="$(printf '%s' "${repo}" | jq -r '.post_bootstrap // empty')"
  auto_start_docker="$(printf '%s' "${repo}" | jq -r '.auto_start_docker // false')"
  docker_file="$(printf '%s' "${repo}" | jq -r '.docker_file // empty')"
  repo_dir="$(resolve_workspace_path "${repo_path}" 'repo path')"

  mkdir -p "$(dirname "${repo_dir}")"

  auth_url="$(github_authenticate_url "${repo_url}")"

  if [ ! -d "${repo_dir}/.git" ]; then
    git clone "${auth_url}" "${repo_dir}"
  fi

  git -C "${repo_dir}" remote set-url origin "${repo_url}"
  git -C "${repo_dir}" fetch "${auth_url}" --all --prune || true
  git -C "${repo_dir}" checkout "${repo_ref}" || true
  git -C "${repo_dir}" pull --ff-only "${auth_url}" "${repo_ref}" || true

  install_repo_dependencies "${repo_dir}" "${package_manager}"

  if [ "${turbo_smoke}" = "true" ]; then
    run_turbo_smoke "${repo_dir}" "${turbo_tasks}"
  fi

  if [ -n "${post_bootstrap}" ]; then
    if post_bootstrap_allowed; then
      (cd "${repo_dir}" && bash -lc "${post_bootstrap}") || true
    else
      printf 'warn: skipping post_bootstrap for %s; set OPENCODE_ALLOW_POST_BOOTSTRAP=1 to allow config-defined commands\n' "${slug}"
    fi
  fi

  if [ "${auto_start_docker}" = "true" ]; then
    if [ -n "${docker_file}" ]; then
      docker_file="$(resolve_repo_relative_path "${repo_dir}" "${docker_file}" 'docker_file')"
    fi
    compose_file="$(compose_file_for_repo "${repo_dir}" "${docker_file}")"
    if [ -n "${compose_file}" ]; then
      docker_compose -f "${compose_file}" up -d || true
    fi
  fi

  printf 'bootstrapped repo %s at %s\n' "${slug}" "${repo_dir}"
done < <(repo_items)
