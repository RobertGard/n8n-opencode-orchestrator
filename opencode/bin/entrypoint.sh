#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/agent/.opencode/bin:/home/agent/.local/bin:/home/agent/.bun/bin:${PATH:-}"

AGENT_USER="agent"
AGENT_HOME="/home/${AGENT_USER}"
WORKSPACE_ROOT="${OPENCODE_WORKSPACE_ROOT:-/workspace}"
CONFIG_ROOT="${OPENCODE_CONFIG_ROOT:-/workspace-config}"
SOCKET_PATH="/var/run/docker.sock"

mkdir -p "${WORKSPACE_ROOT}" "${CONFIG_ROOT}" "${AGENT_HOME}/.config/opencode" "${AGENT_HOME}/.local/share/opencode"
chown -R "${AGENT_USER}:${AGENT_USER}" /workspace "${CONFIG_ROOT}" "${AGENT_HOME}/.config" "${AGENT_HOME}/.local"

if [ -S "${SOCKET_PATH}" ]; then
  SOCKET_GID="$(stat -c '%g' "${SOCKET_PATH}")"
  SOCKET_GROUP="$(getent group "${SOCKET_GID}" | cut -d: -f1 || true)"
  if [ -z "${SOCKET_GROUP}" ]; then
    groupadd -g "${SOCKET_GID}" dockersock
    SOCKET_GROUP="dockersock"
  fi
  usermod -aG "${SOCKET_GROUP}" "${AGENT_USER}"
fi

gosu "${AGENT_USER}" /opt/opencode/bin/bootstrap-opencode.sh

if [ "${OPENCODE_AUTO_BOOTSTRAP_REPOS:-1}" = "1" ]; then
  if ! gosu "${AGENT_USER}" /opt/opencode/bin/bootstrap-repos.sh; then
    printf 'warning: repo bootstrap failed; starting OpenCode anyway\n' >&2
  fi
fi

exec gosu "${AGENT_USER}" opencode serve --hostname "${OPENCODE_SERVER_HOST:-0.0.0.0}" --port "${OPENCODE_SERVER_PORT:-4096}"
