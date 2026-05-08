#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
ENV_LIB_FILE="${ROOT_DIR}/scripts/lib/load-env.sh"
INGRESS_TEMPLATE="${ROOT_DIR}/n8n/bootstrap/workflows/templates/telegram-task-ingress.template.json"
DISPATCH_TEMPLATE="${ROOT_DIR}/n8n/bootstrap/workflows/templates/telegram-task-dispatcher.template.json"
SESSION_MGR_TEMPLATE="${ROOT_DIR}/n8n/bootstrap/workflows/templates/session-manager.template.json"
TASK_LAUNCHER_TEMPLATE="${ROOT_DIR}/n8n/bootstrap/workflows/templates/task-launcher.template.json"
PENDING_INTERACTION_TEMPLATE="${ROOT_DIR}/n8n/bootstrap/workflows/templates/pending-interaction.template.json"
TASK_FINALIZER_TEMPLATE="${ROOT_DIR}/n8n/bootstrap/workflows/templates/task-finalizer.template.json"
ROUTING_FILE="${ROOT_DIR}/n8n/bootstrap/opencode-routing.json"
TASKS_TABLE_NAME="agent_tasks"
STATE_FILE="${ROOT_DIR}/.n8n-bootstrap-state.json"
INGRESS_WORKFLOW_NAME="Постановка задач через Telegram"
DISPATCH_WORKFLOW_NAME="Диспетчер задач Telegram"
SESSION_MGR_WORKFLOW_NAME="Менеджер сессий"
TASK_LAUNCHER_WORKFLOW_NAME="Запуск задачи"
PENDING_INTERACTION_WORKFLOW_NAME="Обработка интеракций"
TASK_FINALIZER_WORKFLOW_NAME="Завершение задачи"
INGRESS_WORKFLOW_TEMP=""
DISPATCH_WORKFLOW_TEMP=""

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

cleanup_temp_files() {
  [ -n "$INGRESS_WORKFLOW_TEMP" ] && rm -f "$INGRESS_WORKFLOW_TEMP"
  [ -n "$DISPATCH_WORKFLOW_TEMP" ] && rm -f "$DISPATCH_WORKFLOW_TEMP"
}

trap cleanup_temp_files EXIT

STEP_COUNTER=0
TOTAL_STEPS=6

step_start() {
  STEP_COUNTER=$((STEP_COUNTER + 1))
  printf '\n[INFO] [%s/%s] %s\n' "$STEP_COUNTER" "$TOTAL_STEPS" "$1"
}

if [ ! -f "$ENV_FILE" ]; then
  die ".env не найден: ${ENV_FILE}"
fi

if [ ! -f "$ENV_LIB_FILE" ]; then
  die "Не найден helper загрузки env: ${ENV_LIB_FILE}"
fi

. "$ENV_LIB_FILE"

if ! load_env_file "$ENV_FILE"; then
  die 'Не удалось безопасно загрузить .env'
fi

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

BASE_COMPOSE=(docker compose -f "${ROOT_DIR}/docker-compose.yml")
if [ -d "${ROOT_DIR}/compose.overrides" ]; then
  shopt -s nullglob
  for file in "${ROOT_DIR}/compose.overrides"/*.yml; do
    BASE_COMPOSE+=(-f "$file")
  done
  shopt -u nullglob
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
  local opencode_routing_json_escaped="$6"
  local cred_id_escaped="${cred_id//|/\\|}"
  local cred_name_escaped="${cred_name//|/\\|}"
  local table_id_escaped="${table_id//|/\\|}"
  local telegram_chat_id_escaped="${TELEGRAM_CHAT_ID//|/\\|}"
  local opencode_routing_json_sed_escaped="${opencode_routing_json_escaped//\\/\\\\}"
  opencode_routing_json_sed_escaped="${opencode_routing_json_sed_escaped//&/\\&}"
  opencode_routing_json_sed_escaped="${opencode_routing_json_sed_escaped//|/\\|}"
  sed \
    -e "s|__TELEGRAM_CREDENTIAL_ID__|${cred_id_escaped}|g" \
    -e "s|__TELEGRAM_CREDENTIAL_NAME__|${cred_name_escaped}|g" \
    -e "s|__TASKS_TABLE_ID__|${table_id_escaped}|g" \
    -e "s|__TELEGRAM_CHAT_ID__|${telegram_chat_id_escaped}|g" \
    -e "s|__OPENCODE_ROUTING_JSON__|${opencode_routing_json_sed_escaped}|g" \
    "$input" > "$output"
}

render_opencode_routing_json() {
  local password_env_name
  local missing_password_envs=()

  if [ ! -f "$ROUTING_FILE" ]; then
    die "Не найден routing файл OpenCode: ${ROUTING_FILE}"
  fi

  while IFS= read -r password_env_name; do
    [ -z "$password_env_name" ] && continue
    if [ -z "${!password_env_name:-}" ]; then
      missing_password_envs+=("$password_env_name")
    fi
  done < <(jq -r '.workers | to_entries[] | .value.passwordEnv // empty' "$ROUTING_FILE")

  if [ "${#missing_password_envs[@]}" -gt 0 ]; then
    die "Не заданы env с паролями OpenCode worker: ${missing_password_envs[*]}"
  fi

  jq --argjson requestTimeoutMs "${OPENCODE_PROVIDER_TIMEOUT_MS:-1800000}" '. + {requestTimeoutMs: $requestTimeoutMs} | .workers |= with_entries(.value |= (. + {authorizationHeader: ("Basic " + ((.username + ":" + (env[.passwordEnv] // "")) | @base64))} | del(.passwordEnv)))' "$ROUTING_FILE"
}

escape_json_string_content() {
  local raw="$1"
  local escaped
  escaped="$(printf '%s' "$raw" | jq -Rsa .)"
  printf '%s' "${escaped:1:${#escaped}-2}"
}

workflow_id_by_name() {
  local workflow_name="$1"
  curl -fsS \
    -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
    "${N8N_URL}/api/v1/workflows" | jq -r --arg name "$workflow_name" '.data // . // [] | map(select(.name == $name)) | first | .id // empty'
}

import_workflow_from_host_file() {
  local host_file="$1"
  local temp_file_name="$2"

  if [ ! -f "$host_file" ]; then
    die "Не найден workflow-файл для импорта: ${host_file}"
  fi

  if ! "${BASE_COMPOSE[@]}" exec -T n8n sh -lc "cat > /tmp/${temp_file_name} && n8n import:workflow --input=/tmp/${temp_file_name} && rm -f /tmp/${temp_file_name}" < "$host_file"; then
    die "Не удалось импортировать workflow: ${host_file}"
  fi
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
    -d '{"name":"agent_tasks","columns":[{"name":"task_key","type":"string"},{"name":"source","type":"string"},{"name":"chat_id","type":"string"},{"name":"username","type":"string"},{"name":"worker_alias","type":"string"},{"name":"command_name","type":"string"},{"name":"prompt","type":"string"},{"name":"parent_task_key","type":"string"},{"name":"parent_match_text","type":"string"},{"name":"context_json","type":"string"},{"name":"status","type":"string"},{"name":"queued_at","type":"date"},{"name":"session_id","type":"string"},{"name":"pending_question","type":"string"},{"name":"pending_options_json","type":"string"},{"name":"result_text","type":"string"}]}' \
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
  if [ -n "$credential_id" ]; then
    log_info "Нашел сохраненный credential id в ${STATE_FILE}: ${credential_id}"
    # Проверяем что креденшел реально существует в n8n (а не остался от предыдущего docker compose down -v)
    if ! curl -fsS -H "X-N8N-API-KEY: ${N8N_API_KEY}" "${N8N_URL}/api/v1/credentials/${credential_id}" >/dev/null 2>&1; then
      log_warn "Credential ${credential_id} не найден в n8n (возможно БД была очищена). Создам новый."
      credential_id=""
    fi
  fi
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

opencode_routing_json="$(render_opencode_routing_json)"
opencode_routing_json_escaped="$(escape_json_string_content "$opencode_routing_json")"
INGRESS_WORKFLOW_TEMP="$(mktemp)"
DISPATCH_WORKFLOW_TEMP="$(mktemp)"
SESSION_MGR_WORKFLOW_TEMP="$(mktemp)"
TASK_LAUNCHER_WORKFLOW_TEMP="$(mktemp)"
PENDING_INTERACTION_WORKFLOW_TEMP="$(mktemp)"
TASK_FINALIZER_WORKFLOW_TEMP="$(mktemp)"

printf '{"telegramCredentialId":"%s","tasksTableId":"%s"}\n' "$credential_id" "$tasks_table_id" > "$STATE_FILE"

render_template "$INGRESS_TEMPLATE" "$INGRESS_WORKFLOW_TEMP" "$credential_id" "$TELEGRAM_CREDENTIAL_NAME" "$tasks_table_id" "$opencode_routing_json_escaped"
render_template "$DISPATCH_TEMPLATE" "$DISPATCH_WORKFLOW_TEMP" "$credential_id" "$TELEGRAM_CREDENTIAL_NAME" "$tasks_table_id" "$opencode_routing_json_escaped"
render_template "$SESSION_MGR_TEMPLATE" "$SESSION_MGR_WORKFLOW_TEMP" "$credential_id" "$TELEGRAM_CREDENTIAL_NAME" "$tasks_table_id" "$opencode_routing_json_escaped"
render_template "$TASK_LAUNCHER_TEMPLATE" "$TASK_LAUNCHER_WORKFLOW_TEMP" "$credential_id" "$TELEGRAM_CREDENTIAL_NAME" "$tasks_table_id" "$opencode_routing_json_escaped"
render_template "$PENDING_INTERACTION_TEMPLATE" "$PENDING_INTERACTION_WORKFLOW_TEMP" "$credential_id" "$TELEGRAM_CREDENTIAL_NAME" "$tasks_table_id" "$opencode_routing_json_escaped"
render_template "$TASK_FINALIZER_TEMPLATE" "$TASK_FINALIZER_WORKFLOW_TEMP" "$credential_id" "$TELEGRAM_CREDENTIAL_NAME" "$tasks_table_id" "$opencode_routing_json_escaped"

log_ok 'Временные workflow-файлы подготовлены.'

step_start 'Импортирую workflow в n8n'

# Удаляем существующие workflow с теми же именами перед импортом, чтобы избежать дубликатов
for wf_name in "$INGRESS_WORKFLOW_NAME" "$DISPATCH_WORKFLOW_NAME" \
               "$SESSION_MGR_WORKFLOW_NAME" "$TASK_LAUNCHER_WORKFLOW_NAME" \
               "$PENDING_INTERACTION_WORKFLOW_NAME" "$TASK_FINALIZER_WORKFLOW_NAME"; do
  existing_ids="$(curl -fsS \
    -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
    "${N8N_URL}/api/v1/workflows" | jq -r --arg name "$wf_name" '.data // . // [] | map(select(.name == $name)) | .[].id')"
  for old_id in $existing_ids; do
    if [ -n "$old_id" ] && [ "$old_id" != "null" ]; then
      log_info "Удаляю старый workflow '${wf_name}' (id=${old_id})"
      curl -fsS -X DELETE -H "X-N8N-API-KEY: ${N8N_API_KEY}" "${N8N_URL}/api/v1/workflows/${old_id}" >/dev/null || true
    fi
  done
done

import_workflow_from_host_file "$INGRESS_WORKFLOW_TEMP" 'telegram-task-ingress.json'
import_workflow_from_host_file "$DISPATCH_WORKFLOW_TEMP" 'telegram-task-dispatcher.json'
import_workflow_from_host_file "$SESSION_MGR_WORKFLOW_TEMP" 'session-manager.json'
import_workflow_from_host_file "$TASK_LAUNCHER_WORKFLOW_TEMP" 'task-launcher.json'
import_workflow_from_host_file "$PENDING_INTERACTION_WORKFLOW_TEMP" 'pending-interaction.json'
import_workflow_from_host_file "$TASK_FINALIZER_WORKFLOW_TEMP" 'task-finalizer.json'

ingress_workflow_id="$(workflow_id_by_name "$INGRESS_WORKFLOW_NAME")"
dispatch_workflow_id="$(workflow_id_by_name "$DISPATCH_WORKFLOW_NAME")"

if [ -z "$ingress_workflow_id" ]; then
  die "Не удалось найти workflow по имени: ${INGRESS_WORKFLOW_NAME}"
fi
if [ -z "$dispatch_workflow_id" ]; then
  die "Не удалось найти workflow по имени: ${DISPATCH_WORKFLOW_NAME}"
fi

activate_workflow_by_id() {
  local wf_id="$1"
  local wf_label="$2"
  if ! curl -fsS -X PATCH \
    -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
    -H 'Content-Type: application/json' \
    -d '{"active": true}' \
    "${N8N_URL}/api/v1/workflows/${wf_id}" >/dev/null; then
    log_warn "Не удалось активировать workflow ${wf_label} (id=${wf_id})"
  fi
}

activate_and_verify() {
  local wf_id="$1"
  local wf_label="$2"
  activate_workflow_by_id "$wf_id" "$wf_label"
  if ! curl -fsS -H "X-N8N-API-KEY: ${N8N_API_KEY}" "${N8N_URL}/api/v1/workflows/${wf_id}" | jq -e '(.active // .data.active) == true' >/dev/null 2>&1; then
    die "Не удалось активировать workflow ${wf_label}."
  fi
}

# Активируем sub-workflow ПЕРВЫМИ — n8n 2.x требует чтобы все зависимые workflow были активны
log_info 'Активирую sub-workflow (требование n8n 2.x для executeWorkflow)'
for wf_name in "$SESSION_MGR_WORKFLOW_NAME" "$TASK_LAUNCHER_WORKFLOW_NAME" \
               "$PENDING_INTERACTION_WORKFLOW_NAME" "$TASK_FINALIZER_WORKFLOW_NAME"; do
  sub_wf_id="$(workflow_id_by_name "$wf_name")"
  if [ -z "$sub_wf_id" ]; then
    die "Не удалось найти sub-workflow по имени: ${wf_name}"
  fi
  activate_and_verify "$sub_wf_id" "$wf_name"
done
log_ok 'Sub-workflow активированы.'

# Теперь активируем основные workflow
activate_and_verify "$ingress_workflow_id" "$INGRESS_WORKFLOW_NAME"
activate_and_verify "$dispatch_workflow_id" "$DISPATCH_WORKFLOW_NAME"

log_ok 'Workflow импортированы и активированы.'

step_start 'Перезапускаю n8n и n8n-worker'
log_info 'Перезапуск сервисов может занять до нескольких десятков секунд.'
if ! "${BASE_COMPOSE[@]}" restart n8n n8n-worker >/dev/null; then
  die 'Не удалось перезапустить n8n и n8n-worker.'
fi

log_ok 'Telegram credential и workflow импортированы.'
