#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${HOME}/.config/opencode"
PLUGIN_DIR="${CONFIG_DIR}/plugins"
CONFIG_FILE="${CONFIG_DIR}/opencode.json"
STATE_FILE="${CONFIG_DIR}/.bootstrap-complete"
WORKSPACE_ROOT="${OPENCODE_WORKSPACE_ROOT:-/workspace}"
REPO_CATALOG_FILE="${OPENCODE_REPO_CATALOG_FILE:-/workspace-config/repos.json}"
INSTANCE_NAME="${OPENCODE_INSTANCE_NAME:-worker}"
TEMPLATE_ROOT="${OPENCODE_TEMPLATE_ROOT:-/opt/opencode/templates}"

mkdir -p "${CONFIG_DIR}" "${PLUGIN_DIR}" "${WORKSPACE_ROOT}" "${WORKSPACE_ROOT}/.opencode/commands"

cat > "${PLUGIN_DIR}/inject-env.js" <<'EOF'
export const InjectEnvPlugin = async () => {
  return {
    "shell.env": async (_input, output) => {
      const allowlist = [
        "OPENAI_API_KEY",
        "DEEPSEEK_API_KEY",
        "ANTHROPIC_API_KEY",
        "OPENROUTER_API_KEY",
        "CONTEXT7_API_KEY",
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

if [ -n "${CONTEXT7_API_KEY:-}" ]; then
  context7_mcp=$(cat <<'EOF'
    "context7": {
      "type": "remote",
      "url": "https://mcp.context7.com/mcp",
      "enabled": true,
      "headers": {
        "CONTEXT7_API_KEY": "{env:CONTEXT7_API_KEY}"
      }
    },
EOF
)
else
  context7_mcp=$(cat <<'EOF'
    "context7": {
      "type": "remote",
      "url": "https://mcp.context7.com/mcp",
      "enabled": true
    },
EOF
)
fi

cat > "${CONFIG_FILE}" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "autoupdate": false,
  "server": {
    "hostname": "${OPENCODE_SERVER_HOST:-0.0.0.0}",
    "port": ${OPENCODE_SERVER_PORT:-4096}
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
  "permission": {
    "external_directory": {
      "/workspace/**": "allow",
      "/workspace-config/**": "allow",
      "/opt/**": "allow"
    },
    "bash": {
      "*": "deny",
      "git *": "allow",
      "gh *": "allow",
      "docker *": "allow",
      "docker compose *": "allow",
      "npm *": "allow",
      "npx *": "allow",
      "pnpm *": "allow",
      "bun *": "allow",
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
      "serena *": "allow",
      "ctx7 *": "allow",
      "jq *": "allow",
      "ls *": "allow",
      "pwd": "allow"
    }
  },
  "plugin": [
    "superpowers@git+https://github.com/obra/superpowers.git"
  ],
  "provider": {
    "anthropic": {
      "options": {
        "timeout": ${OPENCODE_PROVIDER_TIMEOUT_MS:-1800000},
        "chunkTimeout": ${OPENCODE_PROVIDER_CHUNK_TIMEOUT_MS:-900000}
      }
    },
    "openai": {
      "options": {
        "timeout": ${OPENCODE_PROVIDER_TIMEOUT_MS:-1800000},
        "chunkTimeout": ${OPENCODE_PROVIDER_CHUNK_TIMEOUT_MS:-900000}
      }
    },
    "openrouter": {
      "options": {
        "timeout": ${OPENCODE_PROVIDER_TIMEOUT_MS:-1800000},
        "chunkTimeout": ${OPENCODE_PROVIDER_CHUNK_TIMEOUT_MS:-900000}
      }
    }
  },
  "mcp": {
${context7_mcp}    "serena": {
      "type": "local",
      "command": ["serena", "start-mcp-server", "--context", "ide", "--project-from-cwd"],
      "enabled": true,
      "timeout": ${OPENCODE_MCP_TIMEOUT_MS:-120000}
    },
    "filesystem": {
      "type": "local",
      "command": ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/workspace"],
      "enabled": false,
      "timeout": ${OPENCODE_MCP_TIMEOUT_MS:-120000}
    },
    "gitmcp": {
      "type": "local",
      "command": ["npx", "-y", "@modelcontextprotocol/server-git", "/workspace"],
      "enabled": false,
      "timeout": ${OPENCODE_MCP_TIMEOUT_MS:-120000}
    },
    "memory": {
      "type": "local",
      "command": ["npx", "-y", "@modelcontextprotocol/server-memory"],
      "enabled": false,
      "timeout": ${OPENCODE_MCP_TIMEOUT_MS:-120000}
    }
  }
}
EOF

install -m 0644 "${TEMPLATE_ROOT}/verify.md" "${WORKSPACE_ROOT}/.opencode/commands/verify.md"
install -m 0644 "${TEMPLATE_ROOT}/docker-up.md" "${WORKSPACE_ROOT}/.opencode/commands/docker-up.md"
install -m 0644 "${TEMPLATE_ROOT}/repair.md" "${WORKSPACE_ROOT}/.opencode/commands/repair.md"
install -m 0644 "${TEMPLATE_ROOT}/bootstrap-repo.md" "${WORKSPACE_ROOT}/.opencode/commands/bootstrap-repo.md"

if [ ! -f "${WORKSPACE_ROOT}/AGENTS.md" ]; then
  cat > "${WORKSPACE_ROOT}/AGENTS.md" <<EOF
# ${INSTANCE_NAME}

- Workspace root: ${WORKSPACE_ROOT}
- Repo catalog: ${REPO_CATALOG_FILE}
- Default agent: ${OPENCODE_AGENT:-build}
- Docker access is provided through the mounted host socket.
- Use serena for semantic code navigation and symbol-aware refactors.
- Use context7 when you need current library and framework docs.
- Do not read .env files unless the operator explicitly asks for it.
- Prefer .opencode/commands for repeatable verification, bootstrap, and Docker workflows.
EOF
fi

if [ ! -f "${STATE_FILE}" ] && [ "${OPENCODE_AUTO_INSTALL_TOOLING:-1}" = "1" ]; then
  npx -y get-shit-done-cc@latest --opencode --global || true
  npm install -g ctx7 @upstash/context7-mcp \
    @modelcontextprotocol/server-filesystem \
    @modelcontextprotocol/server-git \
    @modelcontextprotocol/server-github \
    @modelcontextprotocol/server-memory \
    @modelcontextprotocol/server-postgres || true
  uv tool install -p 3.13 serena-agent@latest --prerelease=allow || true
  serena init || true
  touch "${STATE_FILE}"
fi
