#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
ENV_LIB_FILE="${ROOT_DIR}/scripts/lib/load-env.sh"

log_info()  { printf '[INFO] %s\n' "$1"; }
log_ok()    { printf '[ OK ] %s\n' "$1"; }
log_warn()  { printf '[WARN] %s\n' "$1" >&2; }
die()       { printf '[ERR ] %s\n' "$1" >&2; exit 1; }

if [ ! -f "$ENV_FILE" ]; then
  die ".env не найден: ${ENV_FILE}"
fi

if [ ! -f "$ENV_LIB_FILE" ]; then
  die "Не найден helper загрузки env: ${ENV_LIB_FILE}"
fi

. "$ENV_LIB_FILE"
load_env_file "$ENV_FILE" || die 'Не удалось загрузить .env'

if [ -z "${N8N_API_KEY:-}" ]; then
  die 'N8N_API_KEY не задан. Добавь его в .env.'
fi

N8N_URL="http://127.0.0.1:${N8N_PORT:-5678}"
MAX_INACTIVE_SECONDS="${DISPATCHER_MAX_INACTIVE_SECONDS:-300}"

DISCOVERED_DISPATCHER_ID=""
if [ -n "${DISPATCHER_WORKFLOW_ID:-}" ]; then
  DISCOVERED_DISPATCHER_ID="${DISPATCHER_WORKFLOW_ID}"
else
  DISCOVERED_DISPATCHER_ID="$(curl -fsS -H "X-N8N-API-KEY: ${N8N_API_KEY}" "${N8N_URL}/api/v1/workflows" 2>/dev/null | jq -r '.data[] | select(.name == "Диспетчер задач Telegram") | .id')"
fi

if [ -z "$DISCOVERED_DISPATCHER_ID" ]; then
  log_warn 'Не удалось найти workflow диспетчера'
  exit 0
fi

last_exec="$(curl -fsS -H "X-N8N-API-KEY: ${N8N_API_KEY}" "${N8N_URL}/api/v1/executions?workflowId=${DISCOVERED_DISPATCHER_ID}&limit=1" 2>/dev/null | jq -r '.data[0].startedAt // empty')"

if [ -z "$last_exec" ]; then
  log_warn 'Не удалось получить время последнего запуска диспетчера'
  exit 0
fi

now_epoch="$(date -u +%s)"
last_epoch="$(date -u -d "$last_exec" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%S" "$last_exec" +%s 2>/dev/null)"

if [ -z "$last_epoch" ]; then
  log_warn 'Не удалось распарсить время последнего запуска'
  exit 0
fi

diff_seconds=$((now_epoch - last_epoch))
if [ "$diff_seconds" -gt "$MAX_INACTIVE_SECONDS" ]; then
  log_warn "Диспетчер не запускался ${diff_seconds} сек — перезапускаю Schedule Trigger"
  curl -fsS -X POST -H "X-N8N-API-KEY: ${N8N_API_KEY}" "${N8N_URL}/api/v1/workflows/${DISCOVERED_DISPATCHER_ID}/deactivate" >/dev/null 2>&1 || true
  sleep 2
  curl -fsS -X POST -H "X-N8N-API-KEY: ${N8N_API_KEY}" "${N8N_URL}/api/v1/workflows/${DISCOVERED_DISPATCHER_ID}/activate" >/dev/null 2>&1 || true
  log_ok 'Schedule Trigger диспетчера перезапущен'
else
  log_ok "Диспетчер жив (последний запуск ${diff_seconds} сек назад)"
fi
