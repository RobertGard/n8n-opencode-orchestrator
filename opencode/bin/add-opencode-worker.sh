#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 3 ]; then
  printf 'usage: %s <name> <host-port> <worker-config-dir>\n' "$0" >&2
  exit 1
fi

NAME="$1"
HOST_PORT="$2"
CONFIG_DIR="$3"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${ROOT_DIR}/compose.overrides"
OUT_FILE="${OUT_DIR}/opencode-${NAME}.yml"
WORKER_INDEX="$(printf '%s' "$NAME" | sed -n 's/^worker-\([0-9][0-9]*\)$/\1/p')"

if [ -z "$WORKER_INDEX" ]; then
  printf 'name must match worker-N, for example worker-2\n' >&2
  exit 1
fi

mkdir -p "${OUT_DIR}" "${ROOT_DIR}/${CONFIG_DIR}"

if [ ! -f "${ROOT_DIR}/${CONFIG_DIR}/repos.json" ]; then
  cat > "${ROOT_DIR}/${CONFIG_DIR}/repos.json" <<'EOF'
{
  "repos": []
}
EOF
fi

cat > "${OUT_FILE}" <<EOF
services:
  opencode-worker-${WORKER_INDEX}:
    build:
      context: ./opencode
    restart: unless-stopped
    init: true
    ports:
      - "127.0.0.1:${HOST_PORT}:4096"
    environment:
      TZ: \${TZ:-UTC}
      OPENAI_API_KEY: \${OPENAI_API_KEY:-}
      DEEPSEEK_API_KEY: \${DEEPSEEK_API_KEY:-}
      ANTHROPIC_API_KEY: \${ANTHROPIC_API_KEY:-}
      OPENROUTER_API_KEY: \${OPENROUTER_API_KEY:-}
      CONTEXT7_API_KEY: \${CONTEXT7_API_KEY:-}
      GITHUB_TOKEN: \${GITHUB_TOKEN:-}
      NPM_TOKEN: \${NPM_TOKEN:-}
      PNPM_HOME: \${PNPM_HOME:-}
      OPENCODE_AGENT: \${OPENCODE_AGENT:-build}
      OPENCODE_SERVER_HOST: 0.0.0.0
      OPENCODE_SERVER_PORT: 4096
      OPENCODE_SERVER_PASSWORD: change-me-${NAME}
      OPENCODE_INSTANCE_NAME: ${NAME}
      OPENCODE_WORKSPACE_ROOT: /workspace
      OPENCODE_CONFIG_ROOT: /workspace-config
      OPENCODE_REPO_CATALOG_FILE: /workspace-config/repos.json
      OPENCODE_AUTO_BOOTSTRAP_REPOS: "1"
      OPENCODE_AUTO_INSTALL_TOOLING: "1"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./opencode/shared:/opt/opencode-shared
      - ./${CONFIG_DIR}:/workspace-config
      - opencode_worker_${WORKER_INDEX}_config:/home/agent/.config/opencode
      - opencode_worker_${WORKER_INDEX}_local:/home/agent/.local/share/opencode
      - opencode_worker_${WORKER_INDEX}_workspace:/workspace
    networks:
      - control

volumes:
  opencode_worker_${WORKER_INDEX}_config:
  opencode_worker_${WORKER_INDEX}_local:
  opencode_worker_${WORKER_INDEX}_workspace:
EOF

printf 'wrote %s\n' "${OUT_FILE}"
