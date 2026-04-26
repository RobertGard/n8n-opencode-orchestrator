#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
WORKERS_DIR="${ROOT_DIR}/workers"
OVERRIDES_DIR="${ROOT_DIR}/compose.overrides"
ROUTING_JSON="${ROOT_DIR}/n8n/local-files/opencode-routing.json"

mkdir -p "$WORKERS_DIR" "$OVERRIDES_DIR" "${ROOT_DIR}/n8n/local-files"

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
ACTION_TOTAL_STEPS=0

step_start() {
  STEP_COUNTER=$((STEP_COUNTER + 1))
  if [ "$ACTION_TOTAL_STEPS" -gt 0 ]; then
    printf '\n[INFO] [%s/%s] %s\n' "$STEP_COUNTER" "$ACTION_TOTAL_STEPS" "$1"
  else
    printf '\n[INFO] %s\n' "$1"
  fi
}

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

random_secret() {
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | dd bs=1 count="$1" 2>/dev/null
}

ask() {
  local prompt="$1"
  local default="${2:-}"
  local value
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi
  IFS= read -r value
  value="$(trim "$value")"
  if [ -z "$value" ]; then
    value="$default"
  fi
  printf '%s' "$value"
}

ask_required() {
  local prompt="$1"
  local default="${2:-}"
  local value
  while true; do
    value="$(ask "$prompt" "$default")"
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return
    fi
    printf 'Значение обязательно.\n' >&2
  done
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local value
  local shown_default="д"
  [ "$default" = "n" ] && shown_default="н"

  while true; do
    printf '%s [д/н, по умолчанию %s]: ' "$prompt" "$shown_default" >&2
    IFS= read -r value
    value="$(trim "$value")"
    [ -z "$value" ] && value="$default"
    case "$value" in
      y|Y|yes|YES|д|Д) return 0 ;;
      n|N|no|NO|н|Н) return 1 ;;
    esac
    printf 'Введи д или н.\n' >&2
  done
}

ask_secret() {
  local prompt="$1"
  local generated
  generated="$(random_secret "${2:-24}")"
  ask "$prompt" "$generated"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

worker_default_alias() {
  case "$1" in
    1) printf 'primary' ;;
    2) printf 'sandbox' ;;
    *) printf 'worker-%s' "$1" ;;
  esac
}

worker_default_port() {
  printf '%s' $((4095 + $1))
}

repo_json_block() {
  local slug="$1"
  local url="$2"
  local ref="$3"
  local path="$4"
  local install_deps="$5"
  local package_manager="$6"
  local turbo_enabled="$7"
  local turbo_tasks_csv="$8"
  local install_gsd_local="$9"
  local auto_start_docker="${10}"
  local post_bootstrap="${11:-}"

  printf '    {\n'
  printf '      "slug": "%s",\n' "$(json_escape "$slug")"
  printf '      "url": "%s",\n' "$(json_escape "$url")"
  printf '      "ref": "%s",\n' "$(json_escape "$ref")"
  printf '      "path": "%s",\n' "$(json_escape "$path")"
  printf '      "install_dependencies": %s,\n' "$install_deps"
  printf '      "package_manager": "%s",\n' "$(json_escape "$package_manager")"
  printf '      "turbo_smoke": %s,\n' "$turbo_enabled"

  if [ "$turbo_enabled" = "true" ]; then
    printf '      "turbo_tasks": ['
    local first=1
    local task
    IFS=',' read -r -a TASKS <<< "$turbo_tasks_csv"
    for task in "${TASKS[@]}"; do
      task="$(trim "$task")"
      [ -z "$task" ] && continue
      if [ $first -eq 0 ]; then
        printf ', '
      fi
      printf '"%s"' "$(json_escape "$task")"
      first=0
    done
    printf '],\n'
  else
    printf '      "turbo_tasks": ["build", "test"],\n'
  fi

  printf '      "install_gsd_local": %s,\n' "$install_gsd_local"
  printf '      "auto_start_docker": %s' "$auto_start_docker"
  if [ -n "$post_bootstrap" ]; then
    printf ',\n      "post_bootstrap": "%s"' "$(json_escape "$post_bootstrap")"
  fi
  printf '\n    }'
}

write_repos_file() {
  local file="$1"
  local repo_slug="$2"
  local repo_url="$3"
  local repo_ref="$4"
  local repo_path="$5"
  local package_manager="$6"
  local turbo_enabled="$7"
  local turbo_tasks="$8"
  local install_deps="$9"
  local install_gsd_local="${10}"
  local auto_start_docker="${11}"
  local post_bootstrap="${12:-}"

  {
    printf '{\n'
    printf '  "repos": [\n'
    repo_json_block \
      "$repo_slug" \
      "$repo_url" \
      "$repo_ref" \
      "$repo_path" \
      "$install_deps" \
      "$package_manager" \
      "$turbo_enabled" \
      "$turbo_tasks" \
      "$install_gsd_local" \
      "$auto_start_docker" \
      "$post_bootstrap"
    printf '\n'
    printf '  ]\n'
    printf '}\n'
  } >"$file"
}

write_disabled_placeholder_repo() {
  local file="$1"
  cat >"$file" <<'EOF'
{
  "repos": [
    {
      "slug": "example-project",
      "url": "https://github.com/example/example.git",
      "ref": "main",
      "path": "example-project",
      "install_dependencies": false,
      "package_manager": "auto",
      "install_gsd_local": true,
      "auto_start_docker": false,
      "enabled": false
    }
  ]
}
EOF
}

generate_override_for_extra_worker() {
  local worker_index="$1"
  local worker_name="$2"
  local host_port="$3"
  local worker_password="$4"
  local worker_dir_rel="$5"
  local service_name="opencode-worker-${worker_index}"
  local out_file="${OVERRIDES_DIR}/opencode-${worker_name}.yml"

  cat >"$out_file" <<EOF
services:
  ${service_name}:
    build:
      context: ./opencode
    restart: unless-stopped
    init: true
    ports:
      - "127.0.0.1:${host_port}:4096"
    environment:
      TZ: \${TZ:-UTC}
      OPENAI_API_KEY: \${OPENAI_API_KEY:-}
      ANTHROPIC_API_KEY: \${ANTHROPIC_API_KEY:-}
      OPENROUTER_API_KEY: \${OPENROUTER_API_KEY:-}
      CONTEXT7_API_KEY: \${CONTEXT7_API_KEY:-}
      GITHUB_TOKEN: \${GITHUB_TOKEN:-}
      NPM_TOKEN: \${NPM_TOKEN:-}
      PNPM_HOME: \${PNPM_HOME:-}
      OPENCODE_AGENT: \${OPENCODE_AGENT:-build}
      OPENCODE_SERVER_HOST: 0.0.0.0
      OPENCODE_SERVER_PORT: 4096
      OPENCODE_SERVER_PASSWORD: ${worker_password}
      OPENCODE_INSTANCE_NAME: ${worker_name}
      OPENCODE_WORKSPACE_ROOT: /workspace
      OPENCODE_CONFIG_ROOT: /workspace-config
      OPENCODE_REPO_CATALOG_FILE: /workspace-config/repos.json
      OPENCODE_AUTO_BOOTSTRAP_REPOS: "1"
      OPENCODE_AUTO_INSTALL_TOOLING: "1"
      OPENCODE_PROVIDER_TIMEOUT_MS: \${OPENCODE_PROVIDER_TIMEOUT_MS:-1800000}
      OPENCODE_PROVIDER_CHUNK_TIMEOUT_MS: \${OPENCODE_PROVIDER_CHUNK_TIMEOUT_MS:-900000}
      OPENCODE_MCP_TIMEOUT_MS: \${OPENCODE_MCP_TIMEOUT_MS:-120000}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./opencode/shared:/opt/opencode-shared
      - ./${worker_dir_rel}:/workspace-config
      - opencode_worker_${worker_index}_config:/home/agent/.config/opencode
      - opencode_worker_${worker_index}_local:/home/agent/.local/share/opencode
      - opencode_worker_${worker_index}_workspace:/workspace
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS -u opencode:${worker_password} http://127.0.0.1:4096/global/health >/dev/null"]
      interval: 20s
      timeout: 5s
      retries: 10
      start_period: 60s
    stop_grace_period: 10m
    networks:
      - control

volumes:
  opencode_worker_${worker_index}_config:
  opencode_worker_${worker_index}_local:
  opencode_worker_${worker_index}_workspace:
EOF
}

printf '\n=============================================\n'
printf '  Настройка OpenCode + n8n\n'
printf '=============================================\n\n'
printf 'Сценарий:\n'
printf '1. Скрипт спросит только нужное\n'
printf '2. Затем спросит, сколько нужно worker-ов\n'
printf '3. После этого настроит каждый worker отдельно\n'
printf '4. В конце при желании поднимет все контейнеры\n\n'

if [ -f "$ENV_FILE" ]; then
  if ! ask_yes_no "Файл .env уже существует. Перезаписать его?" n; then
    log_info 'Оставляю текущую конфигурацию без изменений.'
    exit 0
  fi
fi

ADVANCED_MODE="false"
if ask_yes_no "Включить расширенный режим настройки?" n; then
  ADVANCED_MODE="true"
fi

COMPOSE_PROJECT_NAME="opencode-lab"
TZ_VALUE="UTC"
N8N_HOST="flow.localhost"
N8N_PROTOCOL="http"
N8N_PORT="5678"
N8N_PROXY_HOPS="1"
N8N_EDITOR_BASE_URL=""
ENABLE_CADDY_PROXY="false"
PUBLIC_N8N_DOMAIN=""
ACME_EMAIL=""
N8N_CONCURRENCY_PRODUCTION_LIMIT="4"
N8N_WORKER_CONCURRENCY="2"
N8N_EXECUTIONS_TIMEOUT="604800"
N8N_EXECUTIONS_TIMEOUT_MAX="604800"

if [ "$ADVANCED_MODE" = "true" ]; then
  COMPOSE_PROJECT_NAME="$(ask_required "Имя docker compose проекта" "$COMPOSE_PROJECT_NAME")"
  TZ_VALUE="$(ask_required "Таймзона" "$TZ_VALUE")"
  N8N_HOST="$(ask_required "Хост n8n" "$N8N_HOST")"
  N8N_PROTOCOL="$(ask_required "Протокол n8n (http/https)" "$N8N_PROTOCOL")"
  N8N_PORT="$(ask_required "Порт n8n на хосте" "$N8N_PORT")"
fi

WEBHOOK_URL="${N8N_PROTOCOL}://${N8N_HOST}:${N8N_PORT}/"
GENERIC_TIMEZONE="$TZ_VALUE"

printf '\n--- Внешний доступ к n8n ---\n'
if ask_yes_no "Планируешь открывать n8n наружу по домену и HTTPS?" y; then
  ENABLE_CADDY_PROXY="true"
  PUBLIC_N8N_DOMAIN="$(ask_required "Публичный домен для n8n" "n8n.example.com")"
  ACME_EMAIL="$(ask_required "Email для Let's Encrypt" "admin@example.com")"
  N8N_HOST="$PUBLIC_N8N_DOMAIN"
  N8N_PROTOCOL="https"
  WEBHOOK_URL="https://${PUBLIC_N8N_DOMAIN}/"
  N8N_EDITOR_BASE_URL="https://${PUBLIC_N8N_DOMAIN}/"
  printf 'Будет включен Caddy reverse proxy с автоматическими TLS сертификатами.\n'
else
  N8N_EDITOR_BASE_URL="${WEBHOOK_URL}"
  printf 'Внешний reverse proxy не включен. n8n останется доступен локально.\n'
  printf 'Важно: для Telegram webhooks в production нужен публичный HTTPS URL.\n'
fi

printf '\n--- Обязательные секреты ---\n'
POSTGRES_PASSWORD="$(ask_secret "Пароль Postgres" 24)"
N8N_ENCRYPTION_KEY="$(ask_secret "Ключ шифрования n8n" 64)"
N8N_BASIC_AUTH_PASSWORD="$(ask_secret "Пароль входа в n8n" 24)"

printf '\n--- API ключи ---\n'
OPENAI_API_KEY=""
ANTHROPIC_API_KEY=""
OPENROUTER_API_KEY=""
CONTEXT7_API_KEY=""
N8N_API_KEY=""
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
GITHUB_TOKEN=""
NPM_TOKEN=""
PNPM_HOME=""
if ask_yes_no "Хочешь сразу указать API ключи?" y; then
  OPENAI_API_KEY="$(ask "OPENAI_API_KEY (можно пусто)" "")"
  ANTHROPIC_API_KEY="$(ask "ANTHROPIC_API_KEY (можно пусто)" "")"
  OPENROUTER_API_KEY="$(ask "OPENROUTER_API_KEY (можно пусто)" "")"
  CONTEXT7_API_KEY="$(ask "CONTEXT7_API_KEY (можно пусто)" "")"
  GITHUB_TOKEN="$(ask "GITHUB_TOKEN для приватных репозиториев (можно пусто)" "")"
  NPM_TOKEN="$(ask "NPM_TOKEN (можно пусто)" "")"
fi

printf '\n--- Telegram ---\n'
if ask_yes_no "Включить Telegram интеграцию?" y; then
  TELEGRAM_BOT_TOKEN="$(ask_required "TELEGRAM_BOT_TOKEN" "")"
  TELEGRAM_CHAT_ID="$(ask_required "Telegram chat id. Только этот чат сможет писать боту и получать ответы" "")"
  N8N_API_KEY="$(ask "N8N_API_KEY, если он у тебя уже есть. Иначе оставь пустым и добавишь после первого запуска n8n" "")"
fi

OPENCODE_AGENT="build"
OPENCODE_PROVIDER_TIMEOUT_MS="1800000"
OPENCODE_PROVIDER_CHUNK_TIMEOUT_MS="900000"
OPENCODE_MCP_TIMEOUT_MS="120000"
if [ "$ADVANCED_MODE" = "true" ]; then
  OPENCODE_AGENT="$(ask_required "Дефолтный агент OpenCode" "$OPENCODE_AGENT")"
  OPENCODE_PROVIDER_TIMEOUT_MS="$(ask_required "Timeout LLM-запросов OpenCode (мс)" "$OPENCODE_PROVIDER_TIMEOUT_MS")"
  OPENCODE_PROVIDER_CHUNK_TIMEOUT_MS="$(ask_required "Timeout chunk/stream OpenCode (мс)" "$OPENCODE_PROVIDER_CHUNK_TIMEOUT_MS")"
  OPENCODE_MCP_TIMEOUT_MS="$(ask_required "Timeout MCP OpenCode (мс)" "$OPENCODE_MCP_TIMEOUT_MS")"
fi

WORKER_COUNT="$(ask_required "Сколько всего worker-ов нужно настроить?" "1")"

declare -a WORKER_NAMES WORKER_ALIASES WORKER_PORTS WORKER_PASSWORDS WORKER_SERVICES WORKER_CONFIG_DIRS WORKER_OVERRIDE_FILES

rm -f "${OVERRIDES_DIR}"/opencode-*.yml
log_info 'Старые override-файлы extra worker-ов очищены.'

for ((i = 1; i <= WORKER_COUNT; i++)); do
  printf '\n--- Настройка worker %s из %s ---\n' "$i" "$WORKER_COUNT"
  default_name="worker-${i}"
  default_alias="$(worker_default_alias "$i")"
  default_port="$(worker_default_port "$i")"
  worker_name="$default_name"
  worker_alias="$default_alias"
  worker_port="$default_port"
  worker_password="$(ask_secret "Пароль для ${default_name}" 24)"

  if [ "$ADVANCED_MODE" = "true" ]; then
    worker_name="$(ask_required "Имя worker ${i}" "$default_name")"
    worker_alias="$(ask_required "Короткий alias worker ${i} для n8n" "$default_alias")"
    worker_port="$(ask_required "Порт worker ${i} на хосте" "$default_port")"
  fi

  worker_dir_rel="workers/${worker_name}"
  worker_dir_abs="${ROOT_DIR}/${worker_dir_rel}"
  mkdir -p "$worker_dir_abs"
  log_info "worker ${i}/${WORKER_COUNT}: каталог ${worker_dir_rel} подготовлен"

  repo_slug="project-${i}"
  repo_url="https://github.com/owner/project-${i}.git"
  repo_ref="main"
  repo_path="project-${i}"
  package_manager="auto"
  turbo_enabled="false"
  turbo_tasks="build,test"
  install_deps="true"
  install_gsd_local="true"
  auto_start_docker="true"
  post_bootstrap=""

  if ask_yes_no "Настроить реальный репозиторий для worker ${i} прямо сейчас?" y; then
    repo_slug="$(ask_required "Slug репозитория для worker ${i}" "$repo_slug")"
    repo_url="$(ask_required "Git URL репозитория для worker ${i}" "$repo_url")"
    repo_ref="$(ask_required "Ветка / ref для worker ${i}" "$repo_ref")"
    repo_path="$(ask_required "Папка внутри workspace worker ${i}" "$repo_path")"

    if [ "$ADVANCED_MODE" = "true" ]; then
      package_manager="$(ask_required "Пакетный менеджер (auto/pnpm/npm/npm-ci/bun)" "$package_manager")"
      if ask_yes_no "Запускать Turborepo-задачи для worker ${i}?" "$( [ "$turbo_enabled" = "true" ] && printf y || printf n )"; then
        turbo_enabled="true"
        turbo_tasks="$(ask_required "Список turbo-задач через запятую" "$turbo_tasks")"
      else
        turbo_enabled="false"
      fi
      if ask_yes_no "Автоматически поднимать полную Docker-инфраструктуру репозитория?" "$( [ "$auto_start_docker" = "true" ] && printf y || printf n )"; then
        auto_start_docker="true"
      else
        auto_start_docker="false"
      fi
      if ask_yes_no "Добавить post-bootstrap команду?" n; then
        post_bootstrap="$(ask_required "Команда post-bootstrap" "pnpm lint")"
      fi
    fi

    write_repos_file \
      "${worker_dir_abs}/repos.json" \
      "$repo_slug" \
      "$repo_url" \
      "$repo_ref" \
      "$repo_path" \
      "$package_manager" \
      "$turbo_enabled" \
      "$turbo_tasks" \
      "$install_deps" \
      "$install_gsd_local" \
      "$auto_start_docker" \
      "$post_bootstrap"
    log_ok "worker ${i}/${WORKER_COUNT}: repos.json создан"
  else
    write_disabled_placeholder_repo "${worker_dir_abs}/repos.json"
    log_warn "worker ${i}/${WORKER_COUNT}: записан отключенный placeholder repos.json"
  fi

  WORKER_NAMES+=("$worker_name")
  WORKER_ALIASES+=("$worker_alias")
  WORKER_PORTS+=("$worker_port")
  WORKER_PASSWORDS+=("$worker_password")
  WORKER_SERVICES+=("opencode-worker-${i}")
  WORKER_CONFIG_DIRS+=("$worker_dir_rel")

  if [ "$i" -ge 2 ]; then
    generate_override_for_extra_worker "$i" "$worker_name" "$worker_port" "$worker_password" "$worker_dir_rel"
    WORKER_OVERRIDE_FILES+=("compose.overrides/opencode-${worker_name}.yml")
  fi
done

worker1_name="${WORKER_NAMES[0]}"
worker1_alias="${WORKER_ALIASES[0]}"
worker1_port="${WORKER_PORTS[0]}"
worker1_password="${WORKER_PASSWORDS[0]}"

START_CONTAINERS="false"
if ask_yes_no "Сразу запустить контейнеры?" y; then
  START_CONTAINERS="true"
fi

ACTION_TOTAL_STEPS=3
if [ "$START_CONTAINERS" = "true" ]; then
  ACTION_TOTAL_STEPS=$((ACTION_TOTAL_STEPS + 2))
  if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
    ACTION_TOTAL_STEPS=$((ACTION_TOTAL_STEPS + 1))
  fi
fi

step_start 'Записываю .env'

cat >"$ENV_FILE" <<EOF
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}
TZ=${TZ_VALUE}

N8N_HOST=${N8N_HOST}
N8N_PROTOCOL=${N8N_PROTOCOL}
WEBHOOK_URL=${WEBHOOK_URL}
N8N_EDITOR_BASE_URL=${N8N_EDITOR_BASE_URL}
N8N_PROXY_HOPS=${N8N_PROXY_HOPS}
GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
N8N_PORT=${N8N_PORT}
N8N_CONCURRENCY_PRODUCTION_LIMIT=${N8N_CONCURRENCY_PRODUCTION_LIMIT}
N8N_WORKER_CONCURRENCY=${N8N_WORKER_CONCURRENCY}
N8N_EXECUTIONS_TIMEOUT=${N8N_EXECUTIONS_TIMEOUT}
N8N_EXECUTIONS_TIMEOUT_MAX=${N8N_EXECUTIONS_TIMEOUT_MAX}

POSTGRES_DB=n8n
POSTGRES_USER=n8n
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}

N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_BASIC_AUTH_ACTIVE=true
N8N_BASIC_AUTH_USER=admin
N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}

OPENCODE_AGENT=${OPENCODE_AGENT}

OPENCODE_PROVIDER_TIMEOUT_MS=${OPENCODE_PROVIDER_TIMEOUT_MS}
OPENCODE_PROVIDER_CHUNK_TIMEOUT_MS=${OPENCODE_PROVIDER_CHUNK_TIMEOUT_MS}
OPENCODE_MCP_TIMEOUT_MS=${OPENCODE_MCP_TIMEOUT_MS}

OPENAI_API_KEY=${OPENAI_API_KEY}
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
OPENROUTER_API_KEY=${OPENROUTER_API_KEY}
CONTEXT7_API_KEY=${CONTEXT7_API_KEY}
N8N_API_KEY=${N8N_API_KEY}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
ENABLE_CADDY_PROXY=${ENABLE_CADDY_PROXY}
PUBLIC_N8N_DOMAIN=${PUBLIC_N8N_DOMAIN}
ACME_EMAIL=${ACME_EMAIL}

GITHUB_TOKEN=${GITHUB_TOKEN}
NPM_TOKEN=${NPM_TOKEN}
PNPM_HOME=${PNPM_HOME}
EOF

log_ok ".env сохранен: ${ENV_FILE}"

step_start 'Добавляю переменные worker-ов в .env'

for ((i = 0; i < WORKER_COUNT; i++)); do
  worker_num="$((i + 1))"
  {
    printf '\nOPENCODE_WORKER_%s_NAME=%s\n' "$worker_num" "${WORKER_NAMES[$i]}"
    printf 'OPENCODE_WORKER_%s_PORT=%s\n' "$worker_num" "${WORKER_PORTS[$i]}"
    printf 'OPENCODE_WORKER_%s_PASSWORD=%s\n' "$worker_num" "${WORKER_PASSWORDS[$i]}"
    printf 'OPENCODE_WORKER_%s_ALIAS=%s\n' "$worker_num" "${WORKER_ALIASES[$i]}"
    printf 'OPENCODE_WORKER_%s_BASE_URL=http://%s:4096\n' "$worker_num" "${WORKER_SERVICES[$i]}"
    printf 'OPENCODE_WORKER_%s_HEALTH_URL=http://%s:4096/global/health\n' "$worker_num" "${WORKER_SERVICES[$i]}"
  } >>"$ENV_FILE"
done

log_ok "В .env добавлены параметры ${WORKER_COUNT} worker-ов"

step_start 'Генерирую routing-конфиг для n8n'

{
  printf '{\n'
  printf '  "defaultAgent": "%s",\n' "$(json_escape "$OPENCODE_AGENT")"
  printf '  "defaultWorker": "%s",\n' "$(json_escape "$worker1_alias")"
  printf '  "workers": {\n'
  for ((i = 0; i < WORKER_COUNT; i++)); do
    alias="${WORKER_ALIASES[$i]}"
    service="${WORKER_SERVICES[$i]}"
    printf '    "%s": {\n' "$(json_escape "$alias")"
    printf '      "service": "%s",\n' "$(json_escape "$service")"
    printf '      "alias": "%s",\n' "$(json_escape "$alias")"
    printf '      "baseUrl": "http://%s:4096",\n' "$(json_escape "$service")"
    printf '      "healthUrl": "http://%s:4096/global/health",\n' "$(json_escape "$service")"
    printf '      "username": "opencode",\n'
    printf '      "passwordEnv": "%s"\n' "$(json_escape "OPENCODE_WORKER_${service##opencode-worker-}_PASSWORD")"
    if [ "$i" -lt $((WORKER_COUNT - 1)) ]; then
      printf '    },\n'
    else
      printf '    }\n'
    fi
  done
  printf '  },\n'
  printf '  "endpoints": {\n'
  printf '    "health": "/global/health",\n'
  printf '    "globalEvent": "/global/event",\n'
  printf '    "projectList": "/project",\n'
  printf '    "projectCurrent": "/project/current",\n'
  printf '    "pathCurrent": "/path",\n'
  printf '    "vcsInfo": "/vcs",\n'
  printf '    "instanceDispose": "/instance/dispose",\n'
  printf '    "configGet": "/config",\n'
  printf '    "configPatch": "/config",\n'
  printf '    "configProviders": "/config/providers",\n'
  printf '    "providerList": "/provider",\n'
  printf '    "providerAuthMethods": "/provider/auth",\n'
  printf '    "providerOauthAuthorize": "/provider/{id}/oauth/authorize",\n'
  printf '    "providerOauthCallback": "/provider/{id}/oauth/callback",\n'
  printf '    "sessionList": "/session",\n'
  printf '    "openapi": "/doc",\n'
  printf '    "sessionCreate": "/session",\n'
  printf '    "sessionStatus": "/session/status",\n'
  printf '    "sessionGet": "/session/:id",\n'
  printf '    "sessionDelete": "/session/:id",\n'
  printf '    "sessionPatch": "/session/:id",\n'
  printf '    "sessionChildren": "/session/:id/children",\n'
  printf '    "sessionTodo": "/session/:id/todo",\n'
  printf '    "sessionInit": "/session/:id/init",\n'
  printf '    "sessionFork": "/session/:id/fork",\n'
  printf '    "sessionAbort": "/session/:id/abort",\n'
  printf '    "sessionShare": "/session/:id/share",\n'
  printf '    "sessionUnshare": "/session/:id/share",\n'
  printf '    "sessionDiff": "/session/:id/diff",\n'
  printf '    "sessionSummarize": "/session/:id/summarize",\n'
  printf '    "sessionRevert": "/session/:id/revert",\n'
  printf '    "sessionUnrevert": "/session/:id/unrevert",\n'
  printf '    "sessionPermissionReply": "/session/:id/permissions/:permissionID",\n'
  printf '    "messageList": "/session/:id/message",\n'
  printf '    "sessionMessage": "/session/:id/message",\n'
  printf '    "messageGet": "/session/:id/message/:messageID",\n'
  printf '    "promptAsync": "/session/:id/prompt_async",\n'
  printf '    "sessionCommand": "/session/:id/command",\n'
  printf '    "sessionShell": "/session/:id/shell",\n'
  printf '    "commandList": "/command",\n'
  printf '    "findText": "/find?pattern={pattern}",\n'
  printf '    "findFile": "/find/file?query={query}",\n'
  printf '    "findSymbol": "/find/symbol?query={query}",\n'
  printf '    "fileList": "/file?path={path}",\n'
  printf '    "fileContent": "/file/content?path={path}",\n'
  printf '    "fileStatus": "/file/status",\n'
  printf '    "experimentalToolIds": "/experimental/tool/ids",\n'
  printf '    "experimentalToolList": "/experimental/tool?provider={provider}&model={model}",\n'
  printf '    "lspStatus": "/lsp",\n'
  printf '    "formatterStatus": "/formatter",\n'
  printf '    "mcpStatus": "/mcp",\n'
  printf '    "mcpAdd": "/mcp",\n'
  printf '    "agentList": "/agent",\n'
  printf '    "logWrite": "/log",\n'
  printf '    "tuiAppendPrompt": "/tui/append-prompt",\n'
  printf '    "tuiOpenHelp": "/tui/open-help",\n'
  printf '    "tuiOpenSessions": "/tui/open-sessions",\n'
  printf '    "tuiOpenThemes": "/tui/open-themes",\n'
  printf '    "tuiOpenModels": "/tui/open-models",\n'
  printf '    "tuiSubmitPrompt": "/tui/submit-prompt",\n'
  printf '    "tuiClearPrompt": "/tui/clear-prompt",\n'
  printf '    "tuiExecuteCommand": "/tui/execute-command",\n'
  printf '    "tuiShowToast": "/tui/show-toast",\n'
  printf '    "tuiControlNext": "/tui/control/next",\n'
  printf '    "tuiControlResponse": "/tui/control/response",\n'
  printf '    "authSet": "/auth/:id",\n'
  printf '    "eventStream": "/event"\n'
  printf '  }\n'
  printf '}\n'
} >"$ROUTING_JSON"

log_ok "Routing-конфиг сохранен: ${ROUTING_JSON}"

printf '\nГотово. Созданы файлы:\n'
printf '- %s\n' "$ENV_FILE"
for ((i = 0; i < WORKER_COUNT; i++)); do
  printf '- %s/repos.json\n' "${ROOT_DIR}/${WORKER_CONFIG_DIRS[$i]}"
done
printf '- %s\n' "$ROUTING_JSON"

if [ "${#WORKER_OVERRIDE_FILES[@]}" -gt 0 ]; then
  printf '\nСгенерированы дополнительные override-файлы:\n'
  for file in "${WORKER_OVERRIDE_FILES[@]}"; do
    printf '- %s\n' "$file"
  done
fi

printf '\nСводка по worker-ам:\n'
for ((i = 0; i < WORKER_COUNT; i++)); do
  printf '- worker %s: alias=%s, service=%s, host-port=%s\n' \
    "$((i + 1))" \
    "${WORKER_ALIASES[$i]}" \
    "${WORKER_SERVICES[$i]}" \
    "${WORKER_PORTS[$i]}"
done

compose_cmd=(docker compose -f docker-compose.yml)
if [ "$WORKER_COUNT" -ge 2 ]; then
  for file in "${WORKER_OVERRIDE_FILES[@]}"; do
    compose_cmd+=(-f "$file")
  done
fi

if [ "$START_CONTAINERS" = "true" ]; then
  step_start 'Запускаю docker compose'
  log_info 'Сборка и запуск контейнеров могут занять несколько минут.'
  if [ "$ENABLE_CADDY_PROXY" = "true" ]; then
    compose_cmd+=(--profile proxy up -d --build)
  else
    compose_cmd+=(up -d --build)
  fi
  if ! "${compose_cmd[@]}"; then
    die 'Не удалось собрать или запустить контейнеры через docker compose.'
  fi
  log_ok 'Контейнеры подняты.'

  if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -z "$N8N_API_KEY" ]; then
    log_warn 'Telegram включен, но N8N_API_KEY пока не задан.'
    printf 'Сейчас контейнеры уже подняты. Открой n8n и создай API key:\n'
    printf '1. Открой интерфейс n8n\n'
    printf '2. Перейди в Settings -> n8n API\n'
    printf '3. Создай API key\n'
    printf '4. Вставь его ниже, чтобы завершить Telegram bootstrap\n\n'
    N8N_API_KEY="$(ask "N8N_API_KEY из интерфейса n8n (можно оставить пустым и сделать позже вручную)" "")"
    if [ -n "$N8N_API_KEY" ]; then
      perl -0pi -e 's/^N8N_API_KEY=.*$/N8N_API_KEY='"$N8N_API_KEY"'/m' "$ENV_FILE"
      log_ok 'N8N_API_KEY добавлен в .env'
    else
      log_warn 'N8N_API_KEY пока не добавлен. Telegram bootstrap может быть пропущен.'
    fi
  fi

  if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
    step_start 'Настраиваю Telegram интеграцию'
    if bash "${ROOT_DIR}/scripts/bootstrap-telegram-integration.sh"; then
      log_ok 'Telegram bootstrap завершен.'
    else
      log_warn 'Telegram bootstrap завершился с ошибкой. Можно повторить позже вручную.'
    fi
  fi

  step_start 'Проверяю стек'
  if ! bash "${ROOT_DIR}/scripts/verify-stack.sh"; then
    die 'Проверка стека завершилась ошибкой.'
  fi
  log_ok 'Проверка стека завершена успешно.'
  printf '\nКонтейнеры запущены.\n'
else
  log_info 'Автозапуск контейнеров пропущен.'
  printf '\nДля ручного запуска используй:\n'
  printf '%q ' "${compose_cmd[@]}"
  if [ "$ENABLE_CADDY_PROXY" = "true" ]; then
    printf '%q ' --profile proxy up -d --build
  else
    printf '%q ' up -d --build
  fi
  printf '\n'
fi
