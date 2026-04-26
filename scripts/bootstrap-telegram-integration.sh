#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
INGRESS_TEMPLATE="${ROOT_DIR}/n8n/local-files/workflows/templates/telegram-task-ingress.template.json"
DISPATCH_TEMPLATE="${ROOT_DIR}/n8n/local-files/workflows/templates/telegram-task-dispatcher.template.json"
INGRESS_WORKFLOW="${ROOT_DIR}/n8n/local-files/workflows/telegram-task-ingress.json"
DISPATCH_WORKFLOW="${ROOT_DIR}/n8n/local-files/workflows/telegram-task-dispatcher.json"
TASKS_TABLE_NAME="agent_tasks"
STATE_FILE="${ROOT_DIR}/.n8n-bootstrap-state.json"

log_info() {
  printf '[INFO] %s\n' "$1"
}

log_ok() {
  printf '[ OK ] %s\n' "$1"
}

log_warn() {
  printf '[WARN] %s\n' "$1" >&2
}

log_error() {
  printf '[ERR ] %s\n' "$1" >&2
}

die() {
  log_error "$1"
  exit 1
}

STEP_COUNTER=0
TOTAL_STEPS=6

step_start() {
  STEP_COUNTER=$((STEP_COUNTER + 1))
  printf '\n[INFO] [%s/%s] %s\n' "$STEP_COUNTER" "$TOTAL_STEPS" "$1"
}

if [ ! -f "$ENV_FILE" ]; then
  die ".env не найден: ${ENV_FILE}"
fi

set -a
. "$ENV_FILE"
set +a

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
  log_warn 'TELEGRAM_BOT_TOKEN не задан, Telegram интеграция пропущена.'
  exit 0
fi

if [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
  log_error 'TELEGRAM_CHAT_ID не задан. Telegram интеграция должна быть привязана к одному чату.'
  printf 'Добавь TELEGRAM_CHAT_ID в .env и запусти:\n' >&2
  printf 'bash ./scripts/bootstrap-telegram-integration.sh\n' >&2
  exit 1
fi

if [ -z "${N8N_API_KEY:-}" ]; then
  log_error 'N8N_API_KEY не задан. По официальной документации REST API n8n требует API key.'
  printf 'Создай ключ в Settings -> n8n API и добавь его в .env, затем запусти:\n' >&2
  printf 'bash ./scripts/bootstrap-telegram-integration.sh\n' >&2
  exit 1
fi

N8N_URL="http://127.0.0.1:${N8N_PORT:-5678}"
TELEGRAM_CREDENTIAL_NAME="Telegram Bot"

BASE_COMPOSE=(docker compose -f docker-compose.yml)
if [ -d "${ROOT_DIR}/compose.overrides" ]; then
  while IFS= read -r file; do
    BASE_COMPOSE+=(-f "$file")
  done < <(ls "${ROOT_DIR}/compose.overrides"/*.yml 2>/dev/null || true)
fi

wait_for_n8n() {
  local attempt=1
  local max_attempts=60
  while [ "$attempt" -le "$max_attempts" ]; do
    if curl -fsS -u "${N8N_BASIC_AUTH_USER:-admin}:${N8N_BASIC_AUTH_PASSWORD}" "${N8N_URL}" >/dev/null 2>&1; then
      log_ok "n8n доступен по ${N8N_URL}"
      return 0
    fi
    log_info "n8n еще не отвечает: попытка ${attempt}/${max_attempts}, повтор через 5 секунд"
    sleep 5
    attempt=$((attempt + 1))
  done
  return 1
}

render_template() {
  local input="$1"
  local output="$2"
  local cred_id="$3"
  local cred_name="$4"
  local table_id="$5"
  sed \
    -e "s/__TELEGRAM_CREDENTIAL_ID__/${cred_id}/g" \
    -e "s/__TELEGRAM_CREDENTIAL_NAME__/${cred_name}/g" \
    -e "s/__TASKS_TABLE_ID__/${table_id}/g" \
    "$input" > "$output"
}

step_start 'Ожидаю готовность n8n'
if ! wait_for_n8n; then
  die 'n8n не поднялся вовремя.'
fi

step_start 'Проверяю Data Table agent_tasks'

if ! tasks_table_id="$(curl -fsS \
  -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
  "${N8N_URL}/api/v1/data-tables" | jq -r --arg name "$TASKS_TABLE_NAME" '.data // . // [] | map(select(.name == $name)) | first | .id // empty')"; then
  die 'Не удалось получить список Data Tables из n8n API.'
fi

if [ -z "$tasks_table_id" ]; then
  log_info 'Data Table agent_tasks не найден, создаю.'
  if ! tasks_table_id="$(curl -fsS \
    -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
    -H 'Content-Type: application/json' \
    -X POST \
    -d '{"name":"agent_tasks","columns":[{"name":"task_key","type":"string"},{"name":"source","type":"string"},{"name":"chat_id","type":"string"},{"name":"user_id","type":"string"},{"name":"username","type":"string"},{"name":"worker_alias","type":"string"},{"name":"mode","type":"string"},{"name":"command_name","type":"string"},{"name":"prompt","type":"string"},{"name":"context_json","type":"string"},{"name":"status","type":"string"},{"name":"queued_at","type":"date"},{"name":"session_id","type":"string"},{"name":"pending_question","type":"string"},{"name":"pending_options_json","type":"string"},{"name":"result_text","type":"string"}]}' \
    "${N8N_URL}/api/v1/data-tables" | jq -r '.id // .data.id')"; then
    die 'Не удалось создать Data Table agent_tasks.'
  fi
fi

if [ -z "$tasks_table_id" ] || [ "$tasks_table_id" = "null" ]; then
  die 'Не удалось создать или найти Data Table agent_tasks.'
fi

log_ok "Data Table agent_tasks готов: ${tasks_table_id}"

step_start 'Проверяю Telegram credential'

credential_id=""
if [ -f "$STATE_FILE" ]; then
  credential_id="$(jq -r '.telegramCredentialId // empty' "$STATE_FILE" 2>/dev/null || true)"
  [ -n "$credential_id" ] && log_info "Нашел сохраненный credential id в ${STATE_FILE}"
fi

if [ -z "$credential_id" ]; then
  log_info 'Создаю Telegram credential в n8n.'
  if ! credential_id="$(curl -fsS \
    -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
    -H 'Content-Type: application/json' \
    -X POST \
    -d "{\"name\":\"${TELEGRAM_CREDENTIAL_NAME}\",\"type\":\"telegramApi\",\"nodesAccess\":[{\"nodeType\":\"n8n-nodes-base.telegram\"},{\"nodeType\":\"n8n-nodes-base.telegramTrigger\"}],\"data\":{\"accessToken\":\"${TELEGRAM_BOT_TOKEN}\"}}" \
    "${N8N_URL}/api/v1/credentials" | jq -r '.data.id // .id')"; then
    die 'Не удалось создать Telegram credential в n8n.'
  fi
fi

if [ -z "$credential_id" ] || [ "$credential_id" = "null" ]; then
  die 'Не удалось создать Telegram credential в n8n.'
fi

log_ok "Telegram credential готов: ${credential_id}"

step_start 'Сохраняю bootstrap state и рендерю workflow'

printf '{"telegramCredentialId":"%s","tasksTableId":"%s"}\n' "$credential_id" "$tasks_table_id" > "$STATE_FILE"

render_template "$INGRESS_TEMPLATE" "$INGRESS_WORKFLOW" "$credential_id" "$TELEGRAM_CREDENTIAL_NAME" "$tasks_table_id"
render_template "$DISPATCH_TEMPLATE" "$DISPATCH_WORKFLOW" "$credential_id" "$TELEGRAM_CREDENTIAL_NAME" "$tasks_table_id"

log_ok 'Локальные workflow-файлы подготовлены.'

step_start 'Импортирую workflow в n8n'

if ! "${BASE_COMPOSE[@]}" exec -T n8n n8n import:workflow --input=/files/workflows/telegram-task-ingress.json >/dev/null; then
  die 'Не удалось импортировать workflow telegram-task-ingress.json.'
fi
if ! "${BASE_COMPOSE[@]}" exec -T n8n n8n import:workflow --input=/files/workflows/telegram-task-dispatcher.json >/dev/null; then
  die 'Не удалось импортировать workflow telegram-task-dispatcher.json.'
fi
if ! "${BASE_COMPOSE[@]}" exec -T n8n n8n update:workflow --id=900010 --active=true >/dev/null; then
  die 'Не удалось активировать workflow 900010.'
fi
if ! "${BASE_COMPOSE[@]}" exec -T n8n n8n update:workflow --id=900011 --active=true >/dev/null; then
  die 'Не удалось активировать workflow 900011.'
fi

log_ok 'Workflow импортированы и активированы.'

step_start 'Перезапускаю n8n и n8n-worker'
log_info 'Перезапуск сервисов может занять до нескольких десятков секунд.'
if ! "${BASE_COMPOSE[@]}" restart n8n n8n-worker >/dev/null; then
  die 'Не удалось перезапустить n8n и n8n-worker.'
fi

log_ok 'Telegram credential и workflow импортированы.'
