#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
ENV_LIB_FILE="${ROOT_DIR}/scripts/lib/load-env.sh"

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
TOTAL_STEPS=2

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

if [ -f "${ROOT_DIR}/n8n/bootstrap/opencode-routing.json" ]; then
  TOTAL_STEPS=$((TOTAL_STEPS + 1))
fi

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  TOTAL_STEPS=$((TOTAL_STEPS + 1))
fi

step_start() {
  STEP_COUNTER=$((STEP_COUNTER + 1))
  printf '\n[INFO] [%s/%s] %s\n' "$STEP_COUNTER" "$TOTAL_STEPS" "$1"
}

BASE_COMPOSE=(docker compose -f "${ROOT_DIR}/docker-compose.yml")
if [ -d "${ROOT_DIR}/compose.overrides" ]; then
  shopt -s nullglob
  for file in "${ROOT_DIR}/compose.overrides"/*.yml; do
    BASE_COMPOSE+=(-f "$file")
  done
  shopt -u nullglob
fi

check_url() {
  local label="$1"
  local url="$2"
  local user="${3:-}"
  local pass="${4:-}"
  if [ -n "$user" ]; then
    curl -fsS -u "${user}:${pass}" "$url" >/dev/null
  else
    curl -fsS "$url" >/dev/null
  fi
  log_ok "$label"
}

retry_with_remediation() {
  local label="$1"
  local service="$2"
  local url="$3"
  local user="${4:-}"
  local pass="${5:-}"

  if check_url "$label" "$url" "$user" "$pass" 2>/dev/null; then
    return 0
  fi

  log_warn "${label} не ответил, пробую восстановление через docker compose up -d ${service}"
  if ! "${BASE_COMPOSE[@]}" up -d "$service" >/dev/null; then
    die "Не удалось выполнить docker compose up -d ${service} во время восстановления ${label}."
  fi
  sleep 5
  check_url "$label" "$url" "$user" "$pass"
}

check_worker_urls() {
  local routing_file="${ROOT_DIR}/n8n/bootstrap/opencode-routing.json"
  if [ ! -f "$routing_file" ]; then
    return
  fi

  while IFS= read -r line; do
    alias="$(printf '%s' "$line" | jq -r '.alias')"
    service="$(printf '%s' "$line" | jq -r '.service')"
    health_url="$(printf '%s' "$line" | jq -r '.healthUrl')"
    username="$(printf '%s' "$line" | jq -r '.username')"
    password_env="$(printf '%s' "$line" | jq -r '.passwordEnv // empty')"
    password="${!password_env:-}"
    retry_with_remediation "worker ${alias}" "$service" "$health_url" "$username" "$password"
  done < <(jq -c '.workers | to_entries[] | .value' "$routing_file")
}

step_start 'Проверяю docker compose services'
if ! "${BASE_COMPOSE[@]}" ps; then
  die 'Не удалось получить список docker compose services.'
fi
log_ok 'docker compose services доступны.'

step_start 'Проверяю n8n'
retry_with_remediation "n8n" "n8n" "http://127.0.0.1:${N8N_PORT:-5678}" "${N8N_BASIC_AUTH_USER:-admin}" "${N8N_BASIC_AUTH_PASSWORD}"

if [ -f "${ROOT_DIR}/n8n/bootstrap/opencode-routing.json" ]; then
  step_start 'Проверяю routing-файл и worker-ы'
  if ! jq . "${ROOT_DIR}/n8n/bootstrap/opencode-routing.json" >/dev/null; then
    die 'Routing JSON невалиден.'
  fi
  log_ok 'routing json'
  check_worker_urls
else
  log_info 'Routing-файл не найден, проверяю только OpenCode worker-1.'
  check_url "opencode-worker-1" "http://127.0.0.1:${OPENCODE_WORKER_1_PORT:-4096}/global/health" "opencode" "${OPENCODE_WORKER_1_PASSWORD}"
fi

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  step_start 'Проверяю Telegram интеграцию'
  if [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    log_warn 'TELEGRAM_CHAT_ID не задан, Telegram поток считается некорректно настроенным'
  fi

  N8N_URL="http://127.0.0.1:${N8N_PORT:-5678}"
  if [ -z "${N8N_API_KEY:-}" ]; then
    log_warn 'N8N_API_KEY не задан — пропускаю проверку Telegram креденшелов и workflow'
  else
    # Проверяем существование Telegram credential
    cred_count="$(curl -fsS -H "X-N8N-API-KEY: ${N8N_API_KEY}" "${N8N_URL}/api/v1/credentials" 2>/dev/null | jq -r '[.data // . // [] | map(select(.type == "telegramApi"))] | length' 2>/dev/null)" || cred_count="0"
    if [ "${cred_count:-0}" -gt 0 ]; then
      log_ok 'Telegram credential существует'
    else
      log_warn 'Telegram credential не найден — запусти bootstrap-telegram-integration.sh'
    fi

    # Проверяем существование workflow
    wf_count="$(curl -fsS -H "X-N8N-API-KEY: ${N8N_API_KEY}" "${N8N_URL}/api/v1/workflows" 2>/dev/null | jq -r '[.data // . // [] | length]' 2>/dev/null)" || wf_count="0"
    log_ok "Найдено workflow в n8n: ${wf_count:-0}"
  fi
fi

printf '\n'
log_ok 'Базовая проверка пройдена.'
