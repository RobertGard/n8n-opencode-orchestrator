#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
WORKERS_DIR="${ROOT_DIR}/workers"
OVERRIDES_DIR="${ROOT_DIR}/compose.overrides"
ROUTING_JSON="${ROOT_DIR}/n8n/bootstrap/opencode-routing.json"
ENDPOINTS_JSON="${ROOT_DIR}/n8n/bootstrap/opencode-endpoints.json"

declare -a WORKER_NAMES WORKER_ALIASES WORKER_PORTS WORKER_PASSWORDS WORKER_SERVICES WORKER_CONFIG_DIRS WORKER_OVERRIDE_FILES

mkdir -p "$WORKERS_DIR" "$OVERRIDES_DIR" "${ROOT_DIR}/n8n/bootstrap/workflows/templates"

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

load_env_file() {
  local line
  local key
  local value
  local bs_placeholder=$'\001'
  local dq_placeholder=$'\002'
  local dl_placeholder=$'\003'
  local bt_placeholder=$'\004'
  local esc_bs='\\'
  local esc_dq='\"'
  local esc_dl='\$'
  local esc_bt='\`'
  local bt_char=$'\140'

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac

    if [[ "$line" != *=* ]]; then
      die ".env содержит невалидную строку: ${line}"
    fi

    key="${line%%=*}"
    value="${line#*=}"

    if [[ ! "$key" =~ ^[A-Z0-9_]+$ ]]; then
      die ".env содержит невалидное имя переменной: ${key}"
    fi

    if [[ "$value" =~ ^\'.*\'$ ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" =~ ^\".*\"$ ]]; then
      value="${value:1:${#value}-2}"
      value="${value//$esc_dq/$dq_placeholder}"
      value="${value//$esc_dl/$dl_placeholder}"
      value="${value//$esc_bt/$bt_placeholder}"
      value="${value//$esc_bs/$bs_placeholder}"
      value="${value//$dq_placeholder/\"}"
      value="${value//$dl_placeholder/$}"
      value="${value//$bt_placeholder/$bt_char}"
      value="${value//$bs_placeholder/\\}"
    fi

    printf -v "$key" '%s' "$value"
    export "$key"
  done <"$ENV_FILE"
}

env_quote() {
  local value="$1"

  if [[ "$value" != *"'"* ]]; then
    printf "'%s'" "$value"
    return
  fi

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\$}"
  value="${value//\`/\\\`}"
  printf '"%s"' "$value"
}

write_env_line() {
  printf '%s=%s\n' "$1" "$(env_quote "$2")"
}

upsert_env_value() {
  local key="$1"
  local value="$2"
  local tmp_file
  local found="false"

  tmp_file="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == "${key}="* ]]; then
      write_env_line "$key" "$value" >>"$tmp_file"
      found="true"
    else
      printf '%s\n' "$line" >>"$tmp_file"
    fi
  done <"$ENV_FILE"

  if [ "$found" = "false" ]; then
    write_env_line "$key" "$value" >>"$tmp_file"
  fi

  mv "$tmp_file" "$ENV_FILE"
  printf -v "$key" '%s' "$value"
  export "$key"
}

ensure_env_required() {
  local key="$1"
  local prompt="$2"
  local default="${3:-}"
  local current="${!key:-}"

  if [ -n "$current" ]; then
    return
  fi

  current="$(ask_required "$prompt" "$default")"
  upsert_env_value "$key" "$current"
  log_ok "${key} добавлен в .env"
}

ensure_env_secret() {
  local key="$1"
  local prompt="$2"
  local length="${3:-24}"
  local current="${!key:-}"

  if [ -n "$current" ]; then
    return
  fi

  current="$(ask_secret "$prompt" "$length")"
  upsert_env_value "$key" "$current"
  log_ok "${key} добавлен в .env"
}

ensure_env_default() {
  local key="$1"
  local default="$2"

  if [ -n "${!key:-}" ]; then
    return
  fi

  upsert_env_value "$key" "$default"
  log_ok "${key} восстановлен со значением по умолчанию"
}

ensure_env_boolean_default() {
  local key="$1"
  local default="$2"
  local current="${!key:-}"

  case "$current" in
    true|false) return ;;
    '') ;;
    *) log_warn "${key} имеет невалидное значение '${current}', восстанавливаю '${default}'" ;;
  esac

  upsert_env_value "$key" "$default"
  log_ok "${key} восстановлен со значением ${default}"
}

path_owner_user() {
  stat -c '%U' "$1" 2>/dev/null || stat -f '%Su' "$1" 2>/dev/null
}

path_owner_group() {
  stat -c '%G' "$1" 2>/dev/null || stat -f '%Sg' "$1" 2>/dev/null
}

preferred_fs_owner() {
  local owner
  local group

  owner="$(path_owner_user "$ROOT_DIR" || true)"
  group="$(path_owner_group "$ROOT_DIR" || true)"
  if [ -n "$owner" ] && [ -n "$group" ] && [ "$owner" != "UNKNOWN" ] && [ "$group" != "UNKNOWN" ]; then
    printf '%s:%s' "$owner" "$group"
    return
  fi

  owner="${SUDO_USER:-$(id -un)}"
  group="$(id -gn "$owner" 2>/dev/null || id -gn)"
  printf '%s:%s' "$owner" "$group"
}

ensure_worker_dir_writable() {
  local worker_dir="$1"
  local repo_file="${worker_dir}/config.json"
  local owner_group

  if [ -w "$worker_dir" ] && { [ ! -e "$repo_file" ] || [ -w "$repo_file" ]; }; then
    return
  fi

  owner_group="$(preferred_fs_owner)"
  log_warn "Недостаточно прав для ${worker_dir}. Пытаюсь исправить owner/permissions на ${owner_group}."

  if [ "$(id -u)" -eq 0 ]; then
    chown -R "$owner_group" "$worker_dir" || die "Не удалось изменить owner для ${worker_dir}"
    chmod u+rwx "$worker_dir" || die "Не удалось выдать права на запись для ${worker_dir}"
    if [ -e "$repo_file" ]; then
      chmod u+rw "$repo_file" || die "Не удалось выдать права на запись для ${repo_file}"
    fi
  elif command -v sudo >/dev/null 2>&1; then
    sudo chown -R "$owner_group" "$worker_dir" || die "Не удалось изменить owner для ${worker_dir} через sudo"
    sudo chmod u+rwx "$worker_dir" || die "Не удалось выдать права на запись для ${worker_dir} через sudo"
    if [ -e "$repo_file" ]; then
      sudo chmod u+rw "$repo_file" || die "Не удалось выдать права на запись для ${repo_file} через sudo"
    fi
  else
    die "Нет прав на запись в ${worker_dir}, и sudo недоступен. Исправьте owner/permissions вручную."
  fi

  if [ ! -w "$worker_dir" ] || { [ -e "$repo_file" ] && [ ! -w "$repo_file" ]; }; then
    die "Не удалось восстановить права на запись для ${worker_dir}"
  fi
}

reset_worker_state() {
  WORKER_NAMES=()
  WORKER_ALIASES=()
  WORKER_PORTS=()
  WORKER_PASSWORDS=()
  WORKER_SERVICES=()
  WORKER_CONFIG_DIRS=()
  WORKER_OVERRIDE_FILES=()
}

ensure_unique_worker_value() {
  local candidate="$1"
  local existing
  shift

  for existing in "$@"; do
    if [ "$candidate" = "$existing" ]; then
      return 1
    fi
  done
  return 0
}

ensure_unique_worker_name() {
  local worker_index="$1"
  local value="$2"

  while ! ensure_unique_worker_value "$value" "${WORKER_NAMES[@]}"; do
    printf 'Имя worker должно быть уникальным.\n' >&2
    value="$(ask_worker_name "Имя worker ${worker_index}" "$value")"
  done
  printf '%s' "$value"
}

ensure_unique_worker_alias() {
  local worker_index="$1"
  local value="$2"

  while ! ensure_unique_worker_value "$value" "${WORKER_ALIASES[@]}"; do
    printf 'Alias worker должен быть уникальным.\n' >&2
    value="$(ask_worker_alias "Короткий alias worker ${worker_index} для n8n" "$value")"
  done
  printf '%s' "$value"
}

ensure_unique_worker_port() {
  local worker_index="$1"
  local value="$2"

  while ! ensure_unique_worker_value "$value" "${WORKER_PORTS[@]}"; do
    printf 'Порт worker должен быть уникальным.\n' >&2
    value="$(ask_port "Порт worker ${worker_index} на хосте" "$value")"
  done
  printf '%s' "$value"
}

append_override_files_to_compose_cmd() {
  local file
  shopt -s nullglob
  for file in "${OVERRIDES_DIR}"/*.yml; do
    compose_cmd+=(-f "$file")
  done
  shopt -u nullglob
}

prompt_for_n8n_api_key_if_needed() {
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
    return
  fi

  local n8n_api_url="http://127.0.0.1:${N8N_PORT:-5678}"

  if [ -z "${N8N_API_KEY:-}" ]; then
    log_warn 'Telegram включен, но N8N_API_KEY пока не задан.'
    printf 'Сейчас контейнеры уже подняты. Открой n8n и создай API key:\n'
    printf '1. Открой интерфейс n8n\n'
    printf '2. Перейди в Settings -> n8n API\n'
    printf '3. Создай API key\n'
    printf '4. Вставь его ниже, чтобы завершить Telegram bootstrap\n\n'
    N8N_API_KEY="$(ask "N8N_API_KEY из интерфейса n8n (можно оставить пустым и сделать позже вручную)" "")"
    if [ -n "$N8N_API_KEY" ]; then
      upsert_env_value N8N_API_KEY "$N8N_API_KEY"
      log_ok 'N8N_API_KEY добавлен в .env'
    else
      log_warn 'N8N_API_KEY пока не добавлен. Telegram bootstrap может быть пропущен.'
    fi
    return
  fi

  # N8N_API_KEY задан — проверяем, не протух ли он после docker compose down -v
  local http_code
  http_code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 -H "X-N8N-API-KEY: ${N8N_API_KEY}" "${n8n_api_url}/api/v1/credentials" 2>/dev/null)" || http_code="000"

  case "$http_code" in
    200)
      log_ok 'N8N_API_KEY актуален.'
      ;;
    401)
      log_warn 'N8N_API_KEY в .env недействителен — n8n был пересоздан с нуля.'
      printf 'Открой n8n и создай новый API key:\n'
      printf '1. Открой интерфейс n8n\n'
      printf '2. Перейди в Settings -> n8n API\n'
      printf '3. Создай API key и вставь его ниже\n\n'
      while true; do
        N8N_API_KEY="$(ask "Новый N8N_API_KEY (можно оставить пустым и выйти)" "")"
        if [ -z "$N8N_API_KEY" ]; then
          log_warn 'N8N_API_KEY не обновлён. Telegram bootstrap будет пропущен.'
          break
        fi
        local recheck_code
        recheck_code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 -H "X-N8N-API-KEY: ${N8N_API_KEY}" "${n8n_api_url}/api/v1/credentials" 2>/dev/null)" || recheck_code="000"
        if [ "$recheck_code" = "200" ]; then
          upsert_env_value N8N_API_KEY "$N8N_API_KEY"
          log_ok 'N8N_API_KEY обновлён и подтверждён.'
          break
        fi
        log_warn "Ключ не подошёл (HTTP ${recheck_code}). Попробуй снова или оставь пустым для выхода."
      done
      ;;
    *)
      log_info "N8N_API_KEY пока не проверен (n8n API ответил HTTP ${http_code}) — ключ не сброшен."
      ;;
  esac
}

install_cleanup_cron() {
  local cron_marker="# n8n-opencode-cleanup"
  local cleanup_script="${ROOT_DIR}/scripts/cleanup-executions.sh"
  local log_dir="${ROOT_DIR}/logs"
  local max_retries=3
  local attempt=0
  local installed=0
  local crontab_err=""
  local crontab_l_err=""

  mkdir -p "$log_dir"

  if ! command -v crontab >/dev/null 2>&1; then
    log_warn 'crontab не найден. Установи cron: sudo apt install cron && sudo systemctl enable --now cron'
    log_warn 'Автоочистка executions пропущена. Запусти "crontab -e" вручную позже.'
    return 0
  fi

  if [ ! -f "$cleanup_script" ]; then
    log_warn "Скрипт очистки не найден: ${cleanup_script}"
    log_warn 'Автоочистка executions пропущена.'
    return 0
  fi

  local cron_entry="0 * * * * bash \"${cleanup_script}\" >> \"${log_dir}/cleanup.log\" 2>&1 ${cron_marker}"

  local crontab_content
  crontab_content="$(crontab -l 2>/dev/null || true)"
  crontab_content="$(printf '%s\n' "$crontab_content" | grep -vF "$cron_marker" || true)"
  crontab_content="${crontab_content}
${cron_entry}"

  while [ "$attempt" -lt "$max_retries" ]; do
    attempt=$((attempt + 1))

    if crontab_err="$(printf '%s\n' "$crontab_content" | grep -v '^$' | crontab - 2>&1)"; then
      if crontab_l_err="$(crontab -l 2>&1)" && printf '%s\n' "$crontab_l_err" | grep -qF "$cron_marker"; then
        installed=1
        break
      fi
    fi

    [ "$attempt" -lt "$max_retries" ] && sleep 1
  done

  if [ "$installed" -eq 1 ]; then
    log_ok 'Cron-задача очистки executions установлена (каждый час)'
  else
    log_warn 'Не удалось установить cron-задачу очистки исполнения.'
    if [ -n "$crontab_err" ]; then
      log_warn "crontab: ${crontab_err}"
    fi
    if [ -n "$crontab_l_err" ]; then
      log_warn "crontab -l: ${crontab_l_err}"
    fi
    log_warn "Добавь вручную: ${cron_entry}"
  fi
}

run_startup_pipeline() {
  local run_cmd=("${compose_cmd[@]}")

  step_start 'Запускаю docker compose'
  log_info 'Сборка и запуск контейнеров могут занять несколько минут.'
  if [ "${ENABLE_CADDY_PROXY:-false}" = "true" ]; then
    run_cmd+=(--profile proxy up -d --build)
  else
    run_cmd+=(up -d --build)
  fi
  if ! "${run_cmd[@]}"; then
    die 'Не удалось собрать или запустить контейнеры через docker compose.'
  fi
  # HA и Caddy чувствительны к изменениям конфигов — принудительно пересоздаём
  # Чистим кэш .storage чтобы HA перечитал YAML заново
  if [ -d "${ROOT_DIR}/ha_config/.storage" ]; then
    sudo rm -rf "${ROOT_DIR}/ha_config/.storage" 2>/dev/null || true
    # .storage содержит аутентификацию HA — после его очистки старые токены недействительны
    upsert_env_value HA_API_TOKEN ''
    upsert_env_value HA_NOTIFY_SERVICE ''
    log_warn 'HA storage очищен — HA_API_TOKEN и HA_NOTIFY_SERVICE сброшены, bootstrap перезапросит.'
  fi
  "${compose_cmd[@]}" up -d --force-recreate homeassistant 2>/dev/null || true
  if [ "${ENABLE_CADDY_PROXY:-false}" = "true" ]; then
    "${compose_cmd[@]}" --profile proxy up -d --force-recreate caddy 2>/dev/null || true
  fi
  log_ok 'Контейнеры подняты.'

  prompt_for_n8n_api_key_if_needed

  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    step_start 'Настраиваю Telegram интеграцию'
    if bash "${ROOT_DIR}/scripts/bootstrap-stack.sh"; then
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

  step_start 'Устанавливаю автоочистку старых executions'
  install_cleanup_cron

  printf '\nКонтейнеры запущены.\n'

  if [ -n "${DOCKER_HOST_IP:-}" ] || hostname -I 2>/dev/null | grep -q '[0-9]'; then
    local ha_host="${DOCKER_HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
    printf '\n══════════════════════════════════════════\n'
    printf '  🏠 Home Assistant\n'
    if [ "${ENABLE_CADDY_PROXY:-false}" = "true" ] && [ -n "${PUBLIC_HA_DOMAIN:-}" ]; then
      printf '  Открой в браузере: https://%s\n' "$PUBLIC_HA_DOMAIN"
    else
      printf '  Открой в браузере: http://%s:8123\n' "$ha_host"
    fi
    printf '  1. Пройди первоначальную настройку (создай пользователя)\n'
    printf '  2. После входа: Профиль → Безопасность → Долгосрочные токены доступа → Создать токен\n'
    printf '  3. Добавь в .env: HA_API_TOKEN=<токен>\n'
    printf '  4. Установи HA Companion App на телефон\n'
    printf '     → При первом запуске введи http://%s:8123\n' "$ha_host"
    printf '     → Войди под тем же пользователем что создал в браузере\n'
    printf '     → Разреши все permissions (микрофон, уведомления, фон)\n'
    printf '  5. Голосовой ассистент настраивается автоматически:\n'
    printf '     → Wyoming whisper + piper + pipeline создаются через bootstrap-скрипт\n'
    printf '     → Проверь: скажи "Okay Nabu" в приложении\n'
    printf '  6. Найди имя сервиса уведомлений для телефона:\n'
    printf '     → В HA: Developer Tools → Services → поиск "notify.mobile_app"\n'
    printf '     → Скопируй полное имя (например notify.mobile_app_infinix_x6731b)\n'
    printf '     → Добавь в .env: HA_NOTIFY_SERVICE=<имя_сервиса>\n'
    printf '     → Или запусти bash ./scripts/bootstrap-stack.sh — он запросит\n'
    printf '══════════════════════════════════════════\n\n'
  fi
}

prepare_resume_run() {
  load_env_file

  ACTION_TOTAL_STEPS=5
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    ACTION_TOTAL_STEPS=$((ACTION_TOTAL_STEPS + 1))
  fi
}

print_manual_start_command() {
  printf '\nДля ручного запуска используй:\n'
  printf '%q ' "${compose_cmd[@]}"
  if [ "${ENABLE_CADDY_PROXY:-false}" = "true" ]; then
    printf '%q ' --profile proxy up -d --build
  else
    printf '%q ' up -d --build
  fi
  printf '\n'
}

ask_matching() {
  local prompt="$1"
  local default="$2"
  local regex="$3"
  local error_message="$4"
  local value

  while true; do
    value="$(ask_required "$prompt" "$default")"
    if [[ "$value" =~ $regex ]]; then
      printf '%s' "$value"
      return
    fi
    printf '%s\n' "$error_message" >&2
  done
}

ask_worker_count() {
  local value
  while true; do
    value="$(ask_matching "$1" "$2" '^[1-9][0-9]*$' 'Укажи целое число больше нуля.')"
    if [ "$value" -le 32 ]; then
      printf '%s' "$value"
      return
    fi
    printf 'Скрипт поддерживает от 1 до 32 worker-ов.\n' >&2
  done
}

ask_worker_name() {
  ask_matching "$1" "$2" '^[A-Za-z0-9][A-Za-z0-9_-]*$' 'Используй только буквы, цифры, дефис и underscore.'
}

ask_worker_alias() {
  ask_matching "$1" "$2" '^[A-Za-z0-9][A-Za-z0-9_-]*$' 'Alias может содержать только буквы, цифры, дефис и underscore.'
}

ask_protocol() {
  ask_matching "$1" "$2" '^(http|https)$' 'Допустимые значения: http или https.'
}

ask_port() {
  local value
  while true; do
    value="$(ask_required "$1" "$2")"
    if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] && [ "$value" -le 65535 ]; then
      printf '%s' "$value"
      return
    fi
    printf 'Укажи целый TCP порт в диапазоне 1-65535.\n' >&2
  done
}

ask_model_id() {
  printf 'Примеры моделей для workflow:\n' >&2
  printf '  - opencode/minimax-m2.5-free (бесплатная модель OpenCode Zen)\n' >&2
  printf '  - openai/gpt-5.5\n' >&2
  printf '  - opencode/gemini-3.1-pro\n' >&2
  printf '  - deepseek/deepseek-v4-pro\n' >&2
  ask_matching "$1" "$2" '^[^[:space:]]+/[^[:space:]]+$' 'Укажи полную модель в формате provider/model, например opencode/minimax-m2.5-free, openai/gpt-5.5, opencode/gemini-3.1-pro или deepseek/deepseek-v4-pro.'
}

write_routing_file() {
  local i workers_json endpoints_json
  workers_json="{}"
  for ((i = 0; i < ${#WORKER_NAMES[@]}; i++)); do
    local alias="${WORKER_ALIASES[$i]}"
    local service="${WORKER_SERVICES[$i]}"
    local pwd_env="OPENCODE_WORKER_${service##opencode-worker-}_PASSWORD"
    workers_json="$(printf '%s' "$workers_json" | jq --arg alias "$alias" --arg service "$service" --arg pwd_env "$pwd_env" --arg variant "${OPENCODE_VARIANT:-max}" \
      '.[$alias] = {service: $service, alias: $alias, baseUrl: "http://\($service):4096", healthUrl: "http://\($service):4096/global/health", username: "opencode", variant: $variant, passwordEnv: $pwd_env}')"
  done

  if [ -f "$ENDPOINTS_JSON" ]; then
    endpoints_json="$(jq '.' "$ENDPOINTS_JSON")"
  else
    endpoints_json="{}"
    printf 'warn: endpoints file not found: %s\n' "$ENDPOINTS_JSON" >&2
  fi

  jq -n \
    --arg agent "${OPENCODE_AGENT:-build}" \
    --arg model "${OPENCODE_MODEL:-}" \
    --arg variant "${OPENCODE_VARIANT:-max}" \
    --arg default_worker "${WORKER_ALIASES[0]}" \
    --argjson workers "$workers_json" \
    --argjson endpoints "$endpoints_json" \
    '{
      defaultAgent: $agent,
      defaultModel: $model,
      defaultWorker: $default_worker,
      defaultVariant: $variant,
      workers: $workers,
      endpoints: $endpoints
    }' >"$ROUTING_JSON"
}

configure_worker_repo() {
  local worker_dir="$1"
  local worker_name="$2"

  local template_cfg template_src
  template_cfg="${worker_dir}/config.json.template"
  template_src="$(resolve_template_config "$template_cfg")"

  local repo_slug repo_url repo_ref repo_path
  repo_slug="$(read_template_repo_value "$template_src" '.repos[0].slug' '')"
  repo_url="$(read_template_repo_value "$template_src" '.repos[0].url' '')"
  repo_ref="$(read_template_repo_value "$template_src" '.repos[0].ref' 'main')"
  repo_path="$(read_template_repo_value "$template_src" '.repos[0].path' '')"

  local slug_default url_default
  slug_default="$repo_slug"
  url_default="$repo_url"
  is_placeholder_repo_value "$repo_slug" && slug_default="${worker_name}"
  is_placeholder_repo_value "$repo_url" && url_default=""

  repo_slug="$(ask_required "Slug репозитория для ${worker_name}" "$slug_default")"
  repo_url="$(ask_required "Git URL репозитория для ${worker_name} (https://...)" "$url_default")"
  repo_ref="$(ask "Ветка / ref" "${repo_ref:-main}")"

  local path_default
  path_default="$repo_path"
  is_placeholder_repo_value "$repo_path" && path_default="$repo_slug"
  repo_path="$(ask "Папка внутри workspace" "$path_default")"

  local package_manager turbo_enabled turbo_tasks auto_start_docker post_bootstrap
  package_manager="$(read_template_repo_value "$template_src" '.repos[0].package_manager' 'auto')"
  turbo_enabled="$(read_template_repo_value "$template_src" '.repos[0].turbo_smoke' 'false')"
  turbo_tasks="$(read_template_repo_value "$template_src" '.repos[0].turbo_tasks | join(",")' 'build,test')"
  auto_start_docker="$(read_template_repo_value "$template_src" '.repos[0].auto_start_docker' 'true')"
  post_bootstrap=""

  if [ "${ADVANCED_MODE:-false}" = "true" ]; then
    package_manager="$(ask_required "Пакетный менеджер (auto/pnpm/npm/npm-ci/bun)" "$package_manager")"
    if ask_yes_no "Запускать Turborepo-задачи?" "$( [ "$turbo_enabled" = "true" ] && printf y || printf n )"; then
      turbo_enabled="true"
      turbo_tasks="$(ask_required "Список turbo-задач через запятую" "$turbo_tasks")"
    else
      turbo_enabled="false"
    fi
    if ask_yes_no "Автоматически поднимать Docker-инфраструктуру репозитория?" "$( [ "$auto_start_docker" = "true" ] && printf y || printf n )"; then
      auto_start_docker="true"
    else
      auto_start_docker="false"
    fi
    if ask_yes_no "Добавить post-bootstrap команду?" n; then
      post_bootstrap="$(ask_required "Команда post-bootstrap" "")"
    fi
  fi

  write_repos_file \
    "${worker_dir}/config.json" \
    "$repo_slug" "$repo_url" "$repo_ref" "$repo_path" \
    "$package_manager" "$turbo_enabled" "$turbo_tasks" \
    "$auto_start_docker" "$post_bootstrap"

  log_ok "config.json настроен: ${worker_dir}/config.json"
}

recover_existing_configuration() {
  local worker_count=0
  local index
  local key
  local worker_name
  local worker_alias
  local worker_port
  local worker_password
  local worker_dir_rel
  local worker_dir_abs
  local service_name

  step_start 'Проверяю и дозаполняю текущую конфигурацию'
  ensure_env_default COMPOSE_PROJECT_NAME opencode-lab
  ensure_env_default TZ UTC
  ensure_env_boolean_default ENABLE_CADDY_PROXY false
  ensure_env_default N8N_PORT 5678
  ensure_env_default N8N_VERSION 2.28.5
  if [ "${N8N_VERSION}" = "2.21.7" ]; then
    upsert_env_value N8N_VERSION 2.28.5
    log_ok 'N8N_VERSION обновлён с 2.21.7 до 2.28.5'
  fi
  ensure_env_default N8N_PROXY_HOPS 1
  ensure_env_default N8N_CONCURRENCY_PRODUCTION_LIMIT 4
  ensure_env_default N8N_WORKER_CONCURRENCY 2
  ensure_env_default N8N_EXECUTIONS_TIMEOUT 604800
  ensure_env_default N8N_EXECUTIONS_TIMEOUT_MAX 604800
  ensure_env_default N8N_EXECUTION_RETENTION_HOURS 1
  ensure_env_default POSTGRES_DB n8n
  ensure_env_default POSTGRES_USER n8n
  ensure_env_default N8N_BASIC_AUTH_ACTIVE true
  ensure_env_default N8N_BASIC_AUTH_USER admin
  ensure_env_default OPENCODE_AGENT build
  if [[ ! "${OPENCODE_MODEL:-}" =~ ^[^[:space:]]+/[^[:space:]]+$ ]]; then
    upsert_env_value OPENCODE_MODEL "$(ask_model_id 'Дефолтная модель OpenCode для workflow' '')"
    log_ok 'OPENCODE_MODEL добавлен в .env'
  fi
  ensure_env_default OPENCODE_PROVIDER_TIMEOUT_MS 1800000
  ensure_env_default OPENCODE_PROVIDER_CHUNK_TIMEOUT_MS 900000
  ensure_env_default OPENCODE_MCP_TIMEOUT_MS 120000

  if [[ ! "${N8N_PORT}" =~ ^[0-9]+$ ]] || [ "${N8N_PORT}" -lt 1 ] || [ "${N8N_PORT}" -gt 65535 ]; then
    upsert_env_value N8N_PORT "$(ask_port 'Порт n8n на хосте' '5678')"
    log_ok 'N8N_PORT исправлен в .env'
  fi

  if [[ ! "${N8N_PROTOCOL:-}" =~ ^(http|https)$ ]]; then
    upsert_env_value N8N_PROTOCOL "$(ask_protocol 'Протокол n8n (http/https)' 'http')"
    log_ok 'N8N_PROTOCOL исправлен в .env'
  fi

  if [ "${ENABLE_CADDY_PROXY:-false}" = "true" ]; then
    upsert_env_value N8N_PROTOCOL https
    ensure_env_required PUBLIC_N8N_DOMAIN 'Публичный домен для n8n' 'n8n.example.com'
    ensure_env_required ACME_EMAIL "Email для Let's Encrypt" 'admin@example.com'
    ensure_env_default N8N_HOST "$PUBLIC_N8N_DOMAIN"
    if [ -z "${PUBLIC_HA_DOMAIN:-}" ]; then
      PUBLIC_HA_DOMAIN="$(ask_required 'Домен для Home Assistant (например ha.example.com)' '')"
      upsert_env_value PUBLIC_HA_DOMAIN "$PUBLIC_HA_DOMAIN"
    fi
    WEBHOOK_URL="https://${PUBLIC_N8N_DOMAIN}/"
    N8N_EDITOR_BASE_URL="$WEBHOOK_URL"
  else
    ensure_env_default N8N_PROTOCOL http
    ensure_env_default N8N_HOST flow.localhost
    WEBHOOK_URL="${N8N_PROTOCOL}://${N8N_HOST}:${N8N_PORT}/"
    N8N_EDITOR_BASE_URL="$WEBHOOK_URL"
  fi

  ensure_env_secret POSTGRES_PASSWORD 'Пароль Postgres' 24
  ensure_env_secret N8N_ENCRYPTION_KEY 'Ключ шифрования n8n' 64
  ensure_env_secret N8N_BASIC_AUTH_PASSWORD 'Пароль входа в n8n' 24

  upsert_env_value WEBHOOK_URL "$WEBHOOK_URL"
  upsert_env_value N8N_EDITOR_BASE_URL "$N8N_EDITOR_BASE_URL"
  upsert_env_value GENERIC_TIMEZONE "$TZ"

  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -z "${TELEGRAM_CHAT_IDS:-}" ]; then
    ensure_env_required TELEGRAM_CHAT_IDS 'Telegram chat id. Только этот чат сможет писать боту и получать ответы' ''
  fi

  for ((index = 1; index <= 32; index++)); do
    key="OPENCODE_WORKER_${index}_NAME"
    if [ -n "${!key:-}" ]; then
      worker_count="$index"
    fi
    key="OPENCODE_WORKER_${index}_PASSWORD"
    if [ -n "${!key:-}" ]; then
      worker_count="$index"
    fi
    key="OPENCODE_WORKER_${index}_ALIAS"
    if [ -n "${!key:-}" ]; then
      worker_count="$index"
    fi
  done

  # Detect workers from filesystem (directories with config.json or config.json.template)
  local dir_name dir_num config_file template_file
  shopt -s nullglob
  for dir_name in "${WORKERS_DIR}"/*/; do
    dir_name="${dir_name%/}"
    dir_name="${dir_name##*/}"
    [[ "$dir_name" =~ ^worker- ]] || continue
    dir_num="${dir_name#worker-}"
    [[ "$dir_num" =~ ^[0-9]+$ ]] || continue
    config_file="${WORKERS_DIR}/${dir_name}/config.json"
    template_file="${WORKERS_DIR}/${dir_name}/config.json.template"
    if [ ! -f "$config_file" ] && [ ! -f "$template_file" ]; then
      continue
    fi
    if [ "$dir_num" -gt "$worker_count" ]; then
      worker_count="$dir_num"
      log_info "Обнаружен каталог ${dir_name} на диске, добавляю worker ${dir_num}"
    fi
  done
  shopt -u nullglob

  if [ "$worker_count" -eq 0 ]; then
    worker_count="$(ask_worker_count 'Сколько всего worker-ов нужно восстановить?' '1')"
  fi
  WORKER_COUNT="$worker_count"

  step_start 'Восстанавливаю worker-конфиг и routing'
  reset_worker_state
  rm -f "${OVERRIDES_DIR}"/opencode-*.yml

  for ((index = 1; index <= 32; index++)); do
    if [ "$index" -gt "$worker_count" ]; then
      break
    fi

    key="OPENCODE_WORKER_${index}_NAME"
    worker_name="${!key:-}"
    if [[ ! "$worker_name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
      worker_name="$(ask_worker_name "Имя worker ${index}" "worker-${index}")"
    fi
    worker_name="$(ensure_unique_worker_name "$index" "$worker_name")"
    upsert_env_value "$key" "$worker_name"
    log_ok "${key} добавлен или обновлен в .env"

    key="OPENCODE_WORKER_${index}_ALIAS"
    worker_alias="${!key:-}"
    if [[ ! "$worker_alias" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
      worker_alias="$(ask_worker_alias "Короткий alias worker ${index} для n8n" "$(worker_default_alias "$index")")"
    fi
    worker_alias="$(ensure_unique_worker_alias "$index" "$worker_alias")"
    upsert_env_value "$key" "$worker_alias"
    log_ok "${key} добавлен или обновлен в .env"

    key="OPENCODE_WORKER_${index}_PORT"
    worker_port="${!key:-}"
    if [[ ! "$worker_port" =~ ^[0-9]+$ ]] || [ "$worker_port" -lt 1 ] || [ "$worker_port" -gt 65535 ]; then
      worker_port="$(ask_port "Порт worker ${index} на хосте" "$(worker_default_port "$index")")"
    fi
    worker_port="$(ensure_unique_worker_port "$index" "$worker_port")"
    upsert_env_value "$key" "$worker_port"
    log_ok "${key} добавлен или обновлен в .env"

    key="OPENCODE_WORKER_${index}_PASSWORD"
    worker_password="${!key:-}"
    if [ -z "$worker_password" ]; then
      worker_password="$(ask_secret "Пароль для ${worker_name}" 24)"
      upsert_env_value "$key" "$worker_password"
      log_ok "${key} добавлен в .env"
    fi

    service_name="opencode-worker-${index}"
    upsert_env_value "OPENCODE_WORKER_${index}_BASE_URL" "http://${service_name}:4096"
    upsert_env_value "OPENCODE_WORKER_${index}_HEALTH_URL" "http://${service_name}:4096/global/health"

    worker_dir_rel="workers/${worker_name}"
    worker_dir_abs="${ROOT_DIR}/${worker_dir_rel}"
    mkdir -p "$worker_dir_abs"
    ensure_worker_dir_writable "$worker_dir_abs"
    if [ ! -f "${worker_dir_abs}/config.json" ] || config_is_disabled_placeholder "${worker_dir_abs}/config.json"; then
      configure_worker_repo "$worker_dir_abs" "$worker_name"
    fi

    WORKER_NAMES+=("$worker_name")
    WORKER_ALIASES+=("$worker_alias")
    WORKER_PORTS+=("$worker_port")
    WORKER_PASSWORDS+=("$worker_password")
    WORKER_SERVICES+=("$service_name")
    WORKER_CONFIG_DIRS+=("$worker_dir_rel")

    if [ "$index" -ge 2 ]; then
      generate_worker_override "$index" "$worker_name" "$worker_port" "$worker_password" "$worker_dir_rel"
      WORKER_OVERRIDE_FILES+=("compose.overrides/opencode-${worker_name}.yml")
    fi
  done

  write_routing_file
  log_ok "Routing-конфиг сохранен: ${ROUTING_JSON}"

  compose_cmd=(docker compose -f "$ROOT_DIR/docker-compose.yml")
  append_override_files_to_compose_cmd

  prompt_optional_api_keys
}

prompt_optional_api_keys() {
  local key label current new_val
  while IFS=':' read -r key label; do
    current="${!key:-}"
    if [ -n "$current" ]; then
      continue
    fi
    new_val="$(ask "${label} (можно пусто)" "")"
    new_val="$(trim "$new_val")"
    if [ -n "$new_val" ]; then
      upsert_env_value "$key" "$new_val"
      log_ok "${key} записан в .env"
    fi
  done <<'API_KEYS_EOF'
OPENAI_API_KEY:OpenAI API key
DEEPSEEK_API_KEY:DeepSeek API key
ANTHROPIC_API_KEY:Anthropic API key
OPENROUTER_API_KEY:OpenRouter API key
GITHUB_TOKEN:GitHub token для приватных репозиториев
NPM_TOKEN:NPM token
PNPM_HOME:PNPM home
API_KEYS_EOF
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
  printf 'worker-%s' "$1"
}

worker_default_port() {
  printf '%s' $((4095 + $1))
}

repo_json_block() {
  local slug="$1"
  local url="$2"
  local ref="$3"
  local path="$4"
  local package_manager="$5"
  local turbo_enabled="$6"
  local turbo_tasks_csv="$7"
  local auto_start_docker="$8"
  local post_bootstrap="${9:-}"
  local TASKS task first

  printf '    {\n'
  printf '      "slug": "%s",\n' "$(json_escape "$slug")"
  printf '      "url": "%s",\n' "$(json_escape "$url")"
  printf '      "ref": "%s",\n' "$(json_escape "$ref")"
  printf '      "path": "%s",\n' "$(json_escape "$path")"
  printf '      "package_manager": "%s",\n' "$(json_escape "$package_manager")"
  printf '      "turbo_smoke": %s,\n' "$turbo_enabled"

  if [ "$turbo_enabled" = "true" ]; then
    printf '      "turbo_tasks": ['
    first=1
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

  printf '      "auto_start_docker": %s' "$auto_start_docker"
  if [ -n "$post_bootstrap" ]; then
    printf ',\n      "post_bootstrap": "%s"' "$(json_escape "$post_bootstrap")"
  fi
  printf '\n    }'
}

read_template_repo_value() {
  local template_file="$1"
  local jq_filter="$2"
  local fallback="$3"
  if [ ! -f "$template_file" ]; then
    printf '%s' "$fallback"
    return
  fi
  local val
  val="$(grep -v '^\s*//' "$template_file" | jq -r "$jq_filter" 2>/dev/null)" || true
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    printf '%s' "$fallback"
  else
    printf '%s' "$val"
  fi
}

config_is_disabled_placeholder() {
  local config_file="$1"
  if [ ! -f "$config_file" ]; then
    return 0
  fi
  local enabled
  enabled="$(jq -r '.repos[0].enabled // true' "$config_file" 2>/dev/null)" || return 0
  [ "$enabled" != "false" ] && return 1
  return 0
}

jq_tooling_from_template() {
  local template_file="$1"
  if [ ! -f "$template_file" ]; then
    return 1
  fi
  grep -v '^\s*//' "$template_file" | jq '.tooling' 2>/dev/null
}

resolve_template_config() {
  local worker_template="$1"
  if [ -f "$worker_template" ]; then
    printf '%s' "$worker_template"
    return 0
  fi
  local default_cfg="${ROOT_DIR}/workers/config.json.default"
  if [ -f "$default_cfg" ]; then
    printf '%s' "$default_cfg"
    return 0
  fi
  return 1
}

is_placeholder_repo_value() {
  local value="$1"
  [ -z "$value" ] && return 0
  [ "$value" = "example-project" ] && return 0
  [[ "$value" == "https://github.com/example/example"* ]] && return 0
  return 1
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
  local auto_start_docker="${9}"
  local post_bootstrap="${10:-}"
  local parent_dir

  parent_dir="$(dirname "$file")"
  if [ ! -d "$parent_dir" ]; then
    die "Каталог для config.json не найден: ${parent_dir}"
  fi
  if [ -e "$file" ] && [ ! -w "$file" ]; then
    die "Нет прав на запись в ${file}. Проверьте owner/permissions каталога worker-а."
  fi
  if [ ! -e "$file" ] && [ ! -w "$parent_dir" ]; then
    die "Нет прав на запись в ${parent_dir}. Проверьте owner/permissions каталога worker-а."
  fi

  {
    printf '{\n'
    printf '  "repos": [\n'
    repo_json_block \
      "$repo_slug" \
      "$repo_url" \
      "$repo_ref" \
      "$repo_path" \
      "$package_manager" \
      "$turbo_enabled" \
      "$turbo_tasks" \
      "$auto_start_docker" \
      "$post_bootstrap"
    printf '\n'
    printf '  ],\n'
    local tooling_src
    tooling_src="$(resolve_template_config "${parent_dir}/config.json.template")"
    if [ -n "$tooling_src" ]; then
      printf '  "tooling": %s\n' "$(jq_tooling_from_template "${tooling_src}")"
    fi
    printf '}\n'
  } >"$file"
}

write_disabled_placeholder_repo() {
  local file="$1"
  local parent_dir
  local parent_dir_abs

  parent_dir="$(dirname "$file")"
  parent_dir_abs="$(cd "$parent_dir" 2>/dev/null && pwd)" || parent_dir_abs="$parent_dir"
  if [ ! -d "$parent_dir" ]; then
    die "Каталог для config.json не найден: ${parent_dir}"
  fi
  if [ -e "$file" ] && [ ! -w "$file" ]; then
    die "Нет прав на запись в ${file}. Проверьте owner/permissions каталога worker-а."
  fi
  if [ ! -e "$file" ] && [ ! -w "$parent_dir" ]; then
    die "Нет прав на запись в ${parent_dir}. Проверьте owner/permissions каталога worker-а."
  fi

  local tooling_src
  tooling_src="$(resolve_template_config "${parent_dir}/config.json.template")"

  {
    printf '{\n'
    printf '  "repos": [\n'
    printf '    {\n'
    printf '      "slug": "example-project",\n'
    printf '      "url": "https://github.com/example/example.git",\n'
    printf '      "ref": "main",\n'
    printf '      "path": "example-project",\n'
    printf '      "package_manager": "auto",\n'
    printf '      "auto_start_docker": false,\n'
    printf '      "enabled": false\n'
    printf '    }\n'
    printf '  ],\n'
    if [ -n "$tooling_src" ]; then
      printf '  "tooling": %s\n' "$(jq_tooling_from_template "${tooling_src}")"
    fi
    printf '}\n'
  } >"$file"
}

generate_worker_override() {
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
      DEEPSEEK_API_KEY: \${DEEPSEEK_API_KEY:-}
      ANTHROPIC_API_KEY: \${ANTHROPIC_API_KEY:-}
      OPENROUTER_API_KEY: \${OPENROUTER_API_KEY:-}
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
      OPENCODE_CONFIG_FILE: /workspace-config/config.json
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
      - edge
      - control
    mem_limit: \${OPENCODE_WORKER_MEMORY_LIMIT:-4g}
    cpus: \${OPENCODE_WORKER_CPU_LIMIT:-2}

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
  if ask_yes_no "Файл .env уже существует. Продолжить setup по текущей конфигурации?" y; then
    prepare_resume_run
    recover_existing_configuration
    run_startup_pipeline
    exit 0
  fi
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
N8N_VERSION="2.28.5"
N8N_CONCURRENCY_PRODUCTION_LIMIT="4"
N8N_WORKER_CONCURRENCY="2"
N8N_EXECUTIONS_TIMEOUT="604800"
N8N_EXECUTIONS_TIMEOUT_MAX="604800"

if [ "$ADVANCED_MODE" = "true" ]; then
  COMPOSE_PROJECT_NAME="$(ask_required "Имя docker compose проекта" "$COMPOSE_PROJECT_NAME")"
  TZ_VALUE="$(ask_required "Таймзона" "$TZ_VALUE")"
  N8N_HOST="$(ask_required "Хост n8n" "$N8N_HOST")"
  N8N_PROTOCOL="$(ask_protocol "Протокол n8n (http/https)" "$N8N_PROTOCOL")"
  N8N_PORT="$(ask_port "Порт n8n на хосте" "$N8N_PORT")"
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
DEEPSEEK_API_KEY=""
ANTHROPIC_API_KEY=""
OPENROUTER_API_KEY=""
N8N_API_KEY=""
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_IDS=""
GITHUB_TOKEN=""
NPM_TOKEN=""
PNPM_HOME=""
if ask_yes_no "Хочешь сразу указать API ключи?" y; then
  OPENAI_API_KEY="$(ask "OPENAI_API_KEY (можно пусто)" "")"
  DEEPSEEK_API_KEY="$(ask "DEEPSEEK_API_KEY (можно пусто)" "")"
  ANTHROPIC_API_KEY="$(ask "ANTHROPIC_API_KEY (можно пусто)" "")"
  OPENROUTER_API_KEY="$(ask "OPENROUTER_API_KEY (можно пусто)" "")"
  GITHUB_TOKEN="$(ask "GITHUB_TOKEN для приватных репозиториев (можно пусто)" "")"
  NPM_TOKEN="$(ask "NPM_TOKEN (можно пусто)" "")"
fi

printf '\n--- Telegram ---\n'
if ask_yes_no "Включить Telegram интеграцию?" y; then
  TELEGRAM_BOT_TOKEN="$(ask_required "TELEGRAM_BOT_TOKEN" "")"
  TELEGRAM_CHAT_IDS="$(ask_required "Telegram chat id. Только этот чат сможет писать боту и получать ответы" "")"
  N8N_API_KEY="$(ask "N8N_API_KEY, если он у тебя уже есть. Иначе оставь пустым и добавишь после первого запуска n8n" "")"
fi

OPENCODE_AGENT="build"
OPENCODE_MODEL=""
OPENCODE_PROVIDER_TIMEOUT_MS="1800000"
OPENCODE_PROVIDER_CHUNK_TIMEOUT_MS="900000"
OPENCODE_MCP_TIMEOUT_MS="120000"
OPENCODE_MODEL="$(ask_model_id "Дефолтная модель OpenCode для workflow" "$OPENCODE_MODEL")"
if [ "$ADVANCED_MODE" = "true" ]; then
  OPENCODE_AGENT="$(ask_required "Дефолтный агент OpenCode" "$OPENCODE_AGENT")"
  OPENCODE_PROVIDER_TIMEOUT_MS="$(ask_required "Timeout LLM-запросов OpenCode (мс)" "$OPENCODE_PROVIDER_TIMEOUT_MS")"
  OPENCODE_PROVIDER_CHUNK_TIMEOUT_MS="$(ask_required "Timeout chunk/stream OpenCode (мс)" "$OPENCODE_PROVIDER_CHUNK_TIMEOUT_MS")"
  OPENCODE_MCP_TIMEOUT_MS="$(ask_required "Timeout MCP OpenCode (мс)" "$OPENCODE_MCP_TIMEOUT_MS")"
fi

WORKER_COUNT="$(ask_worker_count "Сколько всего worker-ов нужно настроить?" "1")"

reset_worker_state

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
    worker_name="$(ask_worker_name "Имя worker ${i}" "$default_name")"
    worker_alias="$(ask_worker_alias "Короткий alias worker ${i} для n8n" "$default_alias")"
    worker_port="$(ask_port "Порт worker ${i} на хосте" "$default_port")"
  fi

  worker_name="$(ensure_unique_worker_name "$i" "$worker_name")"
  worker_alias="$(ensure_unique_worker_alias "$i" "$worker_alias")"
  worker_port="$(ensure_unique_worker_port "$i" "$worker_port")"

  worker_dir_rel="workers/${worker_name}"
  worker_dir_abs="${ROOT_DIR}/${worker_dir_rel}"
  mkdir -p "$worker_dir_abs"
  ensure_worker_dir_writable "$worker_dir_abs"
  log_info "worker ${i}/${WORKER_COUNT}: каталог ${worker_dir_rel} подготовлен"

  if ask_yes_no "Настроить реальный репозиторий для worker ${i} прямо сейчас?" y; then
    configure_worker_repo "$worker_dir_abs" "$worker_name"
  else
    write_disabled_placeholder_repo "${worker_dir_abs}/config.json"
    log_warn "worker ${i}/${WORKER_COUNT}: записан отключенный placeholder config.json"
  fi

  WORKER_NAMES+=("$worker_name")
  WORKER_ALIASES+=("$worker_alias")
  WORKER_PORTS+=("$worker_port")
  WORKER_PASSWORDS+=("$worker_password")
  WORKER_SERVICES+=("opencode-worker-${i}")
  WORKER_CONFIG_DIRS+=("$worker_dir_rel")

  if [ "$i" -ge 2 ]; then
    generate_worker_override "$i" "$worker_name" "$worker_port" "$worker_password" "$worker_dir_rel"
    WORKER_OVERRIDE_FILES+=("compose.overrides/opencode-${worker_name}.yml")
  fi
done

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

{
  env_entries=(
    "COMPOSE_PROJECT_NAME|$COMPOSE_PROJECT_NAME"
    "TZ|$TZ_VALUE"
    ""
    "N8N_HOST|$N8N_HOST"
    "N8N_VERSION|$N8N_VERSION"
    "N8N_PROTOCOL|$N8N_PROTOCOL"
    "WEBHOOK_URL|$WEBHOOK_URL"
    "N8N_EDITOR_BASE_URL|$N8N_EDITOR_BASE_URL"
    "N8N_PROXY_HOPS|$N8N_PROXY_HOPS"
    "GENERIC_TIMEZONE|$GENERIC_TIMEZONE"
    "N8N_PORT|$N8N_PORT"
    "N8N_CONCURRENCY_PRODUCTION_LIMIT|$N8N_CONCURRENCY_PRODUCTION_LIMIT"
    "N8N_WORKER_CONCURRENCY|$N8N_WORKER_CONCURRENCY"
    "N8N_EXECUTIONS_TIMEOUT|$N8N_EXECUTIONS_TIMEOUT"
    "N8N_EXECUTIONS_TIMEOUT_MAX|$N8N_EXECUTIONS_TIMEOUT_MAX"
    "N8N_EXECUTION_RETENTION_HOURS|1"
    ""
    "POSTGRES_DB|n8n"
    "POSTGRES_USER|n8n"
    "POSTGRES_PASSWORD|$POSTGRES_PASSWORD"
    ""
    "N8N_ENCRYPTION_KEY|$N8N_ENCRYPTION_KEY"
    "N8N_BASIC_AUTH_ACTIVE|true"
    "N8N_BASIC_AUTH_USER|admin"
    "N8N_BASIC_AUTH_PASSWORD|$N8N_BASIC_AUTH_PASSWORD"
    ""
    "OPENCODE_AGENT|$OPENCODE_AGENT"
    "OPENCODE_MODEL|$OPENCODE_MODEL"
    ""
    "OPENCODE_PROVIDER_TIMEOUT_MS|$OPENCODE_PROVIDER_TIMEOUT_MS"
    "OPENCODE_PROVIDER_CHUNK_TIMEOUT_MS|$OPENCODE_PROVIDER_CHUNK_TIMEOUT_MS"
    "OPENCODE_MCP_TIMEOUT_MS|$OPENCODE_MCP_TIMEOUT_MS"
    ""
    "OPENAI_API_KEY|$OPENAI_API_KEY"
    "DEEPSEEK_API_KEY|$DEEPSEEK_API_KEY"
    "ANTHROPIC_API_KEY|$ANTHROPIC_API_KEY"
    "OPENROUTER_API_KEY|$OPENROUTER_API_KEY"
    "N8N_API_KEY|$N8N_API_KEY"
    "TELEGRAM_BOT_TOKEN|$TELEGRAM_BOT_TOKEN"
    "TELEGRAM_CHAT_IDS|$TELEGRAM_CHAT_IDS"
    "ENABLE_CADDY_PROXY|$ENABLE_CADDY_PROXY"
    "PUBLIC_N8N_DOMAIN|$PUBLIC_N8N_DOMAIN"
    "ACME_EMAIL|$ACME_EMAIL"
    ""
    "GITHUB_TOKEN|$GITHUB_TOKEN"
    "NPM_TOKEN|$NPM_TOKEN"
    "PNPM_HOME|$PNPM_HOME"
  )
  entry="" key="" value=""
  for entry in "${env_entries[@]}"; do
    if [ -z "$entry" ]; then
      printf '\n'
    else
      key="${entry%%|*}"
      value="${entry#*|}"
      write_env_line "$key" "$value"
    fi
  done
} >"$ENV_FILE"

log_ok ".env сохранен: ${ENV_FILE}"

step_start 'Добавляю переменные worker-ов в .env'

for ((i = 0; i < WORKER_COUNT; i++)); do
  worker_num="$((i + 1))"
  {
    printf '\n'
    write_env_line "OPENCODE_WORKER_${worker_num}_NAME" "${WORKER_NAMES[$i]}"
    write_env_line "OPENCODE_WORKER_${worker_num}_PORT" "${WORKER_PORTS[$i]}"
    write_env_line "OPENCODE_WORKER_${worker_num}_PASSWORD" "${WORKER_PASSWORDS[$i]}"
    write_env_line "OPENCODE_WORKER_${worker_num}_ALIAS" "${WORKER_ALIASES[$i]}"
    write_env_line "OPENCODE_WORKER_${worker_num}_BASE_URL" "http://${WORKER_SERVICES[$i]}:4096"
    write_env_line "OPENCODE_WORKER_${worker_num}_HEALTH_URL" "http://${WORKER_SERVICES[$i]}:4096/global/health"
  } >>"$ENV_FILE"
done

log_ok "В .env добавлены параметры ${WORKER_COUNT} worker-ов"

step_start 'Генерирую routing-конфиг для n8n'

write_routing_file

log_ok "Routing-конфиг сохранен: ${ROUTING_JSON}"

printf '\nГотово. Созданы файлы:\n'
printf -- '- %s\n' "$ENV_FILE"
for ((i = 0; i < WORKER_COUNT; i++)); do
  printf -- '- %s/config.json\n' "${ROOT_DIR}/${WORKER_CONFIG_DIRS[$i]}"
done
printf -- '- %s\n' "$ROUTING_JSON"

if [ "${#WORKER_OVERRIDE_FILES[@]}" -gt 0 ]; then
  printf '\nСгенерированы дополнительные override-файлы:\n'
  for file in "${WORKER_OVERRIDE_FILES[@]}"; do
    printf -- '- %s\n' "$file"
  done
fi

printf '\nСводка по worker-ам:\n'
for ((i = 0; i < WORKER_COUNT; i++)); do
  printf -- '- worker %s: alias=%s, service=%s, host-port=%s\n' \
    "$((i + 1))" \
    "${WORKER_ALIASES[$i]}" \
    "${WORKER_SERVICES[$i]}" \
    "${WORKER_PORTS[$i]}"
done

compose_cmd=(docker compose -f "$ROOT_DIR/docker-compose.yml")
if [ "$WORKER_COUNT" -ge 2 ]; then
  for file in "${WORKER_OVERRIDE_FILES[@]}"; do
    compose_cmd+=(-f "$ROOT_DIR/$file")
  done
fi

if [ "$START_CONTAINERS" = "true" ]; then
  run_startup_pipeline
else
  log_info 'Автозапуск контейнеров пропущен.'
  print_manual_start_command
fi
