#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${HOME}/.config/opencode"
PLUGIN_DIR="${CONFIG_DIR}/plugins"
CONFIG_FILE="${CONFIG_DIR}/opencode.json"
STATE_DIR="/tmp/.opencode-tooling-state"
WORKSPACE_ROOT="${OPENCODE_WORKSPACE_ROOT:-/workspace}"
WORKSPACE_CFG="${OPENCODE_CONFIG_FILE:-/workspace-config/config.json}"
INSTANCE_NAME="${OPENCODE_INSTANCE_NAME:-worker}"
TEMPLATE_ROOT="${OPENCODE_TEMPLATE_ROOT:-/opt/opencode/templates}"

mkdir -p "${CONFIG_DIR}" "${PLUGIN_DIR}" "${STATE_DIR}" "${WORKSPACE_ROOT}" "${WORKSPACE_ROOT}/.opencode/commands"

cat > "${PLUGIN_DIR}/inject-env.js" <<'EOF'
export const InjectEnvPlugin = async () => {
  return {
    "shell.env": async (_input, output) => {
      const allowlist = [
        "OPENAI_API_KEY",
        "DEEPSEEK_API_KEY",
        "ANTHROPIC_API_KEY",
        "OPENROUTER_API_KEY",
        "GITHUB_TOKEN",
        "NPM_TOKEN",
        "CI",
        "TZ"
      ]

      for (const key of allowlist) {
        if (process.env[key]) output.env[key] = process.env[key]
      }
    },
  }
}

export const EnvProtectionPlugin = async () => {
  return {
    "tool.execute.before": async (input, output) => {
      if (input.tool === "read" && String(output.args.filePath || "").includes(".env")) {
        throw new Error("Do not read .env files without explicit operator approval")
      }
    },
  }
}
EOF

# Генерируем MCP-секцию из tooling-конфига
generate_mcp_section() {
  local mcp_json
  if ! mcp_json="$(jq -c -n --argjson cfg "$(cat "${WORKSPACE_CFG}" 2>/dev/null || echo '{}')" \
    --arg timeout "${OPENCODE_MCP_TIMEOUT_MS:-120000}" '
    # Validate timeout is numeric
    ($timeout | test("^[0-9]+$")) as $valid_timeout |
    if $valid_timeout | not then error("OPENCODE_MCP_TIMEOUT_MS must be numeric, got: \($timeout)") else . end |

    def mcp_entry:
      .mcp as $m |
      if ($m | has("name") | not) then
        error("mcp entry missing required field: name")
      else . end |
      {
        key: $m.name,
        value: (({
          type: ($m.type // "local"),
          enabled: ($m.enabled // false),
          timeout: ($timeout | tonumber)
        } + if $m.type == "remote" then
          if ($m | has("url") | not) then error("remote mcp \($m.name) missing url") else . end |
          { url: $m.url }
        elif $m.command then
          { command: $m.command }
        else
          { command: (["npx", "-y", .package] + ($m.args // [])) }
        end) +
        if $m.env then { env: $m.env } else {} end)
      };

    [ ($cfg.tooling.npm[]? // empty | select(.mcp) | mcp_entry) ] +
    [ ($cfg.tooling.uv[]?  // empty | select(.mcp) | mcp_entry) ] |
    from_entries
  ' 2>&1)"; then
    echo "{}"
    printf 'warn: generate_mcp_section failed: %s\n' "${mcp_json}" >&2
    return
  fi

  # Проверяем что на выходе валидный JSON
  if ! echo "${mcp_json}" | jq empty >/dev/null 2>&1; then
    echo "{}"
    printf 'warn: generated MCP section is not valid JSON\n' >&2
    return
  fi

  echo "${mcp_json}"
}

cat > "${CONFIG_FILE}" <<'BASE_EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "autoupdate": false,
  "server": {
    "hostname": "__HOSTNAME__",
    "port": __PORT__
  },
  "compaction": {
    "auto": true,
    "prune": true,
    "reserved": 10000
  },
  "watcher": {
    "ignore": [
      "node_modules/**",
      "dist/**",
      ".git/**",
      "coverage/**",
      ".next/**",
      ".turbo/**",
      ".pnpm-store/**"
    ]
  },
  "lsp": {},
  "permission": {
    "external_directory": {
      "/workspace/**": "allow",
      "/workspace-config/**": "allow",
      "/opt/**": "allow"
    },
    "bash": {
      "*": "deny",
      "git *": "allow",
      "git diff": "allow",
      "git diff *": "allow",
      "git log *": "allow",
      "git show *": "allow",
      "git status": "allow",
      "git branch *": "allow",
      "git checkout *": "allow",
      "git stash *": "allow",
      "git tag *": "allow",
      "gh *": "allow",
      "docker *": "allow",
      "docker-compose *": "allow",
      "docker compose *": "allow",
      "npm *": "allow",
      "npx *": "allow",
      "pnpm *": "allow",
      "bun *": "allow",
      "yarn *": "allow",
      "deno *": "allow",
      "python *": "allow",
      "python3 *": "allow",
      "pip *": "allow",
      "pip3 *": "allow",
      "pytest *": "allow",
      "turbo *": "allow",
      "node *": "allow",
      "tsx *": "allow",
      "tsc *": "allow",
      "uv *": "allow",
      "jq *": "allow",
      "just *": "allow",
      "ls *": "allow",
      "pwd": "allow",
      "make *": "allow",
      "fzf *": "allow",
      "hyperfine *": "allow",
      "sg *": "allow",
      "xh *": "allow",
      "sd *": "allow"
    }
  },
  "plugin": [
    "superpowers@git+https://github.com/obra/superpowers.git"
  ],
  "provider": {
    "anthropic": {
      "options": {
        "timeout": __PROVIDER_TIMEOUT__,
        "chunkTimeout": __PROVIDER_CHUNK_TIMEOUT__
      }
    },
    "openai": {
      "options": {
        "timeout": __PROVIDER_TIMEOUT__,
        "chunkTimeout": __PROVIDER_CHUNK_TIMEOUT__
      }
    },
    "openrouter": {
      "options": {
        "timeout": __PROVIDER_TIMEOUT__,
        "chunkTimeout": __PROVIDER_CHUNK_TIMEOUT__
      }
    },
    "deepseek": {
      "options": {
        "timeout": __PROVIDER_TIMEOUT__,
        "chunkTimeout": __PROVIDER_CHUNK_TIMEOUT__
      }
    }
  },
  "mcp": __MCP_SECTION__
}
BASE_EOF

MCP_SECTION="{}"
if [ -f "${WORKSPACE_CFG}" ] && jq -e '.tooling' "${WORKSPACE_CFG}" >/dev/null 2>&1; then
  MCP_SECTION="$(generate_mcp_section)"
  if [ -z "${MCP_SECTION}" ]; then
    MCP_SECTION="{}"
  fi
fi

# Подставляем плейсхолдеры. __MCP_SECTION__ без кавычек — sed подставит JSON-объект
sed -i.bak \
  -e "s|__HOSTNAME__|${OPENCODE_SERVER_HOST:-0.0.0.0}|" \
  -e "s|__PORT__|${OPENCODE_SERVER_PORT:-4096}|" \
  -e "s|__PROVIDER_TIMEOUT__|${OPENCODE_PROVIDER_TIMEOUT_MS:-1800000}|" \
  -e "s|__PROVIDER_CHUNK_TIMEOUT__|${OPENCODE_PROVIDER_CHUNK_TIMEOUT_MS:-900000}|" \
  -e "s|__MCP_SECTION__|${MCP_SECTION}|g" \
  "${CONFIG_FILE}"
rm -f "${CONFIG_FILE}.bak"

# Проверяем что итоговый opencode.json — валидный JSON и форматируем
if jq empty "${CONFIG_FILE}" >/dev/null 2>&1; then
  jq '.' "${CONFIG_FILE}" > "${CONFIG_FILE}.pretty"
  mv "${CONFIG_FILE}.pretty" "${CONFIG_FILE}"
else
  printf 'warn: generated %s is not valid JSON\n' "${CONFIG_FILE}" >&2
fi

install -m 0644 "${TEMPLATE_ROOT}/verify.md" "${WORKSPACE_ROOT}/.opencode/commands/verify.md"
install -m 0644 "${TEMPLATE_ROOT}/docker-up.md" "${WORKSPACE_ROOT}/.opencode/commands/docker-up.md"
install -m 0644 "${TEMPLATE_ROOT}/repair.md" "${WORKSPACE_ROOT}/.opencode/commands/repair.md"
install -m 0644 "${TEMPLATE_ROOT}/bootstrap-repo.md" "${WORKSPACE_ROOT}/.opencode/commands/bootstrap-repo.md"
install -m 0644 "${TEMPLATE_ROOT}/review.md" "${WORKSPACE_ROOT}/.opencode/commands/review.md"
install -m 0644 "${TEMPLATE_ROOT}/debug.md" "${WORKSPACE_ROOT}/.opencode/commands/debug.md"
install -m 0644 "${TEMPLATE_ROOT}/deploy.md" "${WORKSPACE_ROOT}/.opencode/commands/deploy.md"
install -m 0644 "${TEMPLATE_ROOT}/security.md" "${WORKSPACE_ROOT}/.opencode/commands/security.md"
install -m 0644 "${TEMPLATE_ROOT}/perf.md" "${WORKSPACE_ROOT}/.opencode/commands/perf.md"
install -m 0644 "${TEMPLATE_ROOT}/deps.md" "${WORKSPACE_ROOT}/.opencode/commands/deps.md"

# Skills — on-demand reusable instructions for agents
mkdir -p "${CONFIG_DIR}/skills"
for skill_dir in "${TEMPLATE_ROOT}/skills/"*/; do
  skill_name="$(basename "${skill_dir}")"
  mkdir -p "${CONFIG_DIR}/skills/${skill_name}"
  install -m 0644 "${skill_dir}SKILL.md" "${CONFIG_DIR}/skills/${skill_name}/SKILL.md"
done

mkdir -p "${CONFIG_DIR}/agents"
if [ ! -f "${CONFIG_DIR}/agents/verifier.md" ]; then
  install -m 0644 "${TEMPLATE_ROOT}/verifier.md" "${CONFIG_DIR}/agents/verifier.md"
fi

if [ ! -f "${CONFIG_DIR}/agents/reviewer.md" ]; then
  install -m 0644 "${TEMPLATE_ROOT}/reviewer.md" "${CONFIG_DIR}/agents/reviewer.md"
fi

if [ ! -f "${CONFIG_DIR}/agents/planner.md" ]; then
  install -m 0644 "${TEMPLATE_ROOT}/planner.md" "${CONFIG_DIR}/agents/planner.md"
fi

if [ ! -f "${CONFIG_DIR}/agents/security-auditor.md" ]; then
  install -m 0644 "${TEMPLATE_ROOT}/security-auditor.md" "${CONFIG_DIR}/agents/security-auditor.md"
fi

if [ ! -f "${WORKSPACE_ROOT}/AGENTS.md" ]; then
  cat > "${WORKSPACE_ROOT}/AGENTS.md" <<EOF
# ${INSTANCE_NAME}

- Workspace root: ${WORKSPACE_ROOT}
- Config: ${CONFIG_FILE}
- Default agent: ${OPENCODE_AGENT:-build}
- Docker access is provided through the mounted host socket.
- Do not read .env files unless the operator explicitly asks for it.
- Prefer .opencode/commands for repeatable verification, bootstrap, and Docker workflows.
EOF
fi

# Global rules — apply to ALL OpenCode sessions on this worker
if [ ! -f "${CONFIG_DIR}/AGENTS.md" ]; then
  install -m 0644 "${TEMPLATE_ROOT}/global-agents.md" "${CONFIG_DIR}/AGENTS.md"
fi

if [ "${OPENCODE_AUTO_INSTALL_TOOLING:-1}" = "1" ]; then
  if [ -f "${WORKSPACE_CFG}" ] && jq -e '.tooling' "${WORKSPACE_CFG}" >/dev/null 2>&1; then

    # --- npm packages ---
    NPM_COUNT="$(jq -r '.tooling.npm | length' "${WORKSPACE_CFG}" 2>/dev/null || echo 0)"
    if [ "${NPM_COUNT}" -gt 0 ]; then
      if ! command -v npm >/dev/null 2>&1; then
        printf 'warn: npm not found, skipping npm packages\n' >&2
      else
        for row in $(jq -r '.tooling.npm[]? | @base64' "${WORKSPACE_CFG}" 2>/dev/null); do
          _pkg() { echo "${row}" | base64 -d | jq -r "${1}"; }
          pkg="$(_pkg '.package // ""')"
          if [ -z "${pkg}" ]; then
            printf 'warn: npm entry missing package field, skipping\n' >&2
            continue
          fi
          args="$(_pkg '.args // ""')"
          pkg_name="$(echo "${pkg}" | sed 's/@[^/@]*$//')"
          if [ -z "${pkg_name}" ]; then
            printf 'warn: could not parse package name from: %s\n' "${pkg}" >&2
            continue
          fi
          state_key="$(echo "${pkg_name}" | tr '/' '-')"
          if npm list -g --depth=0 "${pkg_name}" >/dev/null 2>&1; then
            echo "→ npm: ${pkg_name} (уже установлен)"
          else
            echo "→ installing npm: ${pkg}"
            if ! npm install -g "${pkg}"; then
              printf 'warn: npm install -g %s failed\n' "${pkg}" >&2
              continue
            fi
          fi
          if [ -n "${args}" ] && [ ! -f "${STATE_DIR}/.${state_key}-run" ]; then
            bin_name="$(_pkg '.binary // ""')"
            [ -z "${bin_name}" ] && bin_name="${pkg_name}"
            echo "→ running: ${bin_name} ${args}"
            if ${bin_name} ${args}; then
              touch "${STATE_DIR}/.${state_key}-run"
            else
              printf 'warn: %s %s failed\n' "${bin_name}" "${args}" >&2
            fi
          fi
        done
      fi
    fi

    # --- uv tools ---
    UV_COUNT="$(jq -r '.tooling.uv | length' "${WORKSPACE_CFG}" 2>/dev/null || echo 0)"
    if [ "${UV_COUNT}" -gt 0 ]; then
      if ! command -v uv >/dev/null 2>&1; then
        printf 'warn: uv not found, skipping uv tools\n' >&2
      else
        for row in $(jq -r '.tooling.uv[]? | @base64' "${WORKSPACE_CFG}" 2>/dev/null); do
          _pkg() { echo "${row}" | base64 -d | jq -r "${1}"; }
          pkg="$(_pkg '.package // ""')"
          if [ -z "${pkg}" ]; then
            printf 'warn: uv entry missing package field, skipping\n' >&2
            continue
          fi
          py="$(_pkg '.python // "3.13"')"
          args="$(_pkg '.args // ""')"
          pkg_name="$(echo "${pkg}" | sed 's/@[^/@]*$//')"
          if uv tool list --show-paths 2>/dev/null | grep -q "^${pkg_name} "; then
            echo "→ uv: ${pkg_name} (уже установлен)"
          else
            echo "→ installing uv: ${pkg} (python=${py})"
            if ! uv tool install -p "${py}" "${pkg}" ${args}; then
              printf 'warn: uv tool install %s failed\n' "${pkg}" >&2
            fi
          fi
        done
      fi
    fi

    # --- post-install ---
    POST_COUNT="$(jq -r '.tooling.post_install | length' "${WORKSPACE_CFG}" 2>/dev/null || echo 0)"
    if [ "${POST_COUNT}" -gt 0 ] && [ ! -f "${STATE_DIR}/.post-install-done" ]; then
      for row in $(jq -r '.tooling.post_install[]? | @base64' "${WORKSPACE_CFG}" 2>/dev/null); do
        cmd="$(echo "${row}" | base64 -d)"
        if [ -z "${cmd}" ]; then continue; fi
        echo "→ post-install: ${cmd}"
        if ! eval "${cmd}"; then
          printf 'warn: post-install command failed: %s\n' "${cmd}" >&2
        fi
      done
      touch "${STATE_DIR}/.post-install-done"
    fi

  else
    printf 'warn: tooling section not found in %s, skipping auto-install\n' "${WORKSPACE_CFG}" >&2
  fi
fi
