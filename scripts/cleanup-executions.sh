#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
ENV_LIB_FILE="${ROOT_DIR}/scripts/lib/load-env.sh"

log_info()  { printf '[INFO] %s\n' "$1"; }
log_ok()    { printf '[ OK ] %s\n' "$1"; }
log_warn()  { printf '[WARN] %s\n' "$1" >&2; }
die()       { printf '[ERR ] %s\n' "$1" >&2; exit 1; }

RETENTION_HOURS="${N8N_EXECUTION_RETENTION_HOURS:-1}"
PAGE_SIZE=500
MAX_PAGES=10

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
CUTOFF_DATE="$(date -u -d "${RETENTION_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -v-${RETENTION_HOURS}H +%Y-%m-%dT%H:%M:%S.000Z)"

log_info "Удаляю execution старше ${RETENTION_HOURS} ч (ранее ${CUTOFF_DATE})"

total_deleted=0
page=0

while [ "$page" -lt "$MAX_PAGES" ]; do
  page=$((page + 1))
  
  # Fetch a page of executions
  resp="$(curl -fsS -H "X-N8N-API-KEY: ${N8N_API_KEY}" "${N8N_URL}/api/v1/executions?limit=${PAGE_SIZE}" 2>/dev/null)" || {
    log_warn "Не удалось получить список executions (страница ${page})"
    break
  }
  
  # Filter old ones
  old_ids="$(printf '%s' "$resp" | jq -r --arg cutoff "$CUTOFF_DATE" '.data[]? | select(.stoppedAt != null and .stoppedAt < $cutoff) | .id')"
  
  if [ -z "$old_ids" ]; then
    log_info "Старых execution больше нет на странице ${page}"
    break
  fi
  
  page_deleted=0
  while IFS= read -r exec_id; do
    [ -z "$exec_id" ] && continue
    curl -fsS -X DELETE -H "X-N8N-API-KEY: ${N8N_API_KEY}" "${N8N_URL}/api/v1/executions/${exec_id}" >/dev/null 2>&1 || true
    page_deleted=$((page_deleted + 1))
  done <<< "$old_ids"
  
  total_deleted=$((total_deleted + page_deleted))
  log_info "Страница ${page}: удалено ${page_deleted}"
done

log_ok "Всего удалено execution: ${total_deleted}"
