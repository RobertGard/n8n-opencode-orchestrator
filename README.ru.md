# Home Dev Assistant

Self-hosted AI-ассистент для разработки на базе OpenCode + n8n: ставите задачу в Telegram или голосом (Home Assistant), n8n диспетчеризует её на OpenCode worker-ы, результат приходит обратно в чат или озвучивается через TTS.

> **English version:** [README.md](./README.md)

**Ключевые возможности:**

- **Мульти-Worker** — любое количество worker-ов, каждый под свой проект и со своим набором MCP-инструментов
- **Сессии с контекстом** — worker помнит историю диалога, можно уточнять и дополнять задачи в рамках одной сессии
- **Интерактивный OpenCode** — worker может задать уточняющий вопрос прямо в чат, вы отвечаете, он продолжает
- **Авто-режим** — после завершения задачи бот сам анализирует результат и предлагает следующую: GSD-цикл, проверку качества, тесты, документацию
- **Цепочки задач** — задача может ждать завершения родительской и выполниться только при совпадении с указанным текстом в результате (тесты прошли → деплой)
- **Верификация приёмки** — передайте `--verify="критерии"` с задачей; после выполнения в очередь ставится задача проверки (в новой сессии, независимо от исходной). Агент проверяет здоровье кода, логи, консоль браузера (Playwright), ответы API и каждый критерий. Результат оценивает DeepSeek Judge — при FAILED авто-создаётся задача-фикс с исходной сессией и критериями
- **Повторяющиеся задачи** — флаг `--interval="4h"` запускает задачу по расписанию (30m, 4h, 1d). Остановка через `/abort`. Экономия места в БД — переиспользуется та же строка
- **Команды на естественном языке** — пишите запросы обычным текстом; AI-транслятор преобразует их в структурированные команды с правильными флагами
- **OpenCode-команды из Telegram** — `/gsd-ship`, `/deploy`, `/brainstorm` и др. автоматически заворачиваются в `/task --prompt="/команда"` и отправляются воркеру
- **Полностью self-hosted** — никаких облачных сервисов, все данные под вашим контролем
- **Стек из коробки** — PostgreSQL, Redis, n8n, Home Assistant, Caddy (HTTPS) — один `bash setup-stack.sh` и всё готово
- **Голосовое управление** — Home Assistant + Companion App на телефоне. Wake-word "Окей, Ассистент" → голосовая задача → TTS-ответ на телефон. Работает вместе с Telegram
- **CI/CD интеграция** — запуск пайплайнов, проверка статуса, диагностика падений (`/ci`, `/release`)
- **Инструменты для БД** — исследование схем, анализ запросов, ревью миграций, генерация seed-данных (`/db`)
- **Наблюдаемость** — анализ логов, детектирование ошибок, инцидент-репорты, мониторинг здоровья
- **Деплой** — Docker Compose, проверка здоровья, откат (`/deploy`)
- **9 специализированных субагентов + 2 основных (build, plan)** — planner, reviewer, verifier, security-auditor, ci-cd-agent, db-analyst, observability-agent, release-manager, ralph-loop-agent (GSD Execute+Verify)
- **16 встроенных скиллов** — от ревью кода и профилирования до CI/CD и Docker-деплоя
- **Интеграция skills.sh** — агенты авто-обнаруживают и устанавливают скиллы из skills.sh через pre-flight проверку
- **Стандарты качества кода** — обязательный verification gate, запрет хардкода, профессиональные стандарты
- **Лимиты ресурсов worker-ов** — настраиваемые ограничения CPU/памяти (`4GB/2CPU` по умолчанию)

## Требования

- Docker Engine + Docker Compose
- Telegram bot token (для режима Telegram)
- Публичный домен, порты 80/443 (для HTTPS)

## Быстрый старт

```bash
bash ./scripts/setup-stack.sh
```

Скрипт задаёт вопросы, создаёт `.env` и `config.json`, запускает контейнеры, настраивает Telegram.

### Переустановка

```bash
docker compose down -v --rmi all --remove-orphans
docker builder prune -af
bash ./scripts/setup-stack.sh
```

## Команды Telegram-бота

Бот принимает команды через `/`. Флаги в формате `--flag="value"`.

Системные команды (обрабатываются ботом напрямую):

### `/task` — создание и управление задачами

| Команда | Описание |
|---|---|
| `/task --prompt="описание"` | Создать новую задачу |
| `/task --answer="ответ"` | Ответить на вопрос OpenCode (авто-выбор ожидающей задачи) |
| `/task --task_key="xxx" --answer="ответ"` | Ответить на конкретную задачу |
| `/task --parent_task_key="xxx" --parent_match_text="текст"` | Связанная задача с проверкой текста в результате родителя |
| `/task --auto_mode="true"` | Включить авто-режим |
| `/task --auto_mode="false"` | Отключить авто-режим |

### `/abort` — отмена задач

| Команда | Описание |
|---|---|
| `/abort --task_key="xxx"` | Отменить конкретную задачу (работающую или queued-повторяющуюся) |
| `/abort` | Авто-выбор единственной работающей задачи |

### Дополнительные флаги

| Флаг | Описание |
|---|---|
| `--worker="alias"` | Назначить задачу конкретному worker-у |
| `--new_session` / `--fresh_session` | Принудительно создать новую сессию OpenCode |
| `--verify="критерии"` | Критерии приёмки — после выполнения задачи в очередь ставится задача проверки (новая сессия). Агент проверяет здоровье кода, логи, браузер (Playwright), ответы API. DeepSeek Judge оценивает результат; при FAILED авто-создаётся задача-фикс с исходной сессией и критериями |
| `--interval="4h"` | Повторяющаяся задача — перезапуск каждые N часов/дней. Формат: число + m/h/d (30m, 4h, 1d). Отмена через `/abort --task_key="xxx"` |

### OpenCode-команды (для воркера)

Все остальные `/`-команды (такие как `/gsd-ship`, `/deploy`, `/brainstorm`) автоматически заворачиваются в `/task --prompt="/команда"` и отправляются воркеру. Воркер выполняет их как OpenCode-слеш-команды. Включают:

| Команда | Где выполняется | Описание |
|---------|-----------------|----------|
| `/ci` | Воркер (OpenCode) | CI/CD управление |
| `/db` | Воркер (OpenCode) | Инструменты БД |
| `/release` | Воркер (OpenCode) | Управление релизами |
| `/ship` | Воркер (OpenCode) | Quality gates → commit → push → PR |
| `/deploy` | Воркер (OpenCode) | Docker-деплой |
| `/brainstorm` | Воркер (OpenCode) | Декомпозиция проблем |
| `/skills` | Воркер (OpenCode) | Поиск скиллов на skills.sh |
| `/gsd-*` | Воркер (OpenCode) | GSD-команды |

### Ответы на вопросы OpenCode

OpenCode задаёт вопрос → бот присылает пронумерованные варианты.

- **Один вопрос** — номер варианта или текст метки
- **Несколько вопросов** — через `||`: `1 || Prisma`
- **Мультивыбор** — через `&&`: `1 && 3`
- **Отклонить** — `/reject` или `/task --answer="/reject"`

### Авто-режим

`/task --auto_mode="true"` — после каждой завершённой задачи бот предлагает следующую: GSD-цикл, проверку качества, тесты, документацию. Авто-задачи (префикс `auto-`) наследуют worker от исходной задачи.

### Трансляция естественного языка

Не обязательно писать структурированные команды. Просто пишите обычным текстом:

| Ввод | Преобразуется в |
|---|---|
| `разверни проект` | `/task --prompt="разверни проект"` |
| `выполни правки на втором воркере` | `/task --prompt="выполни правки" --worker="worker-2"` |
| `ответь 2 в задаче task-abc` | `/task --task_key="task-abc" --answer="2"` |
| `если в задаче task-abc результат содержит "готово" то сделай очистку` | `/task --parent_task_key="task-abc" --parent_match_text="готово" --prompt="сделай очистку"` |
| `включи автомод` | `/task --auto_mode="true"` |
| `отмени задачу task-xyz` | `/abort --task_key="task-xyz"` |
| `сделай рефакторинг. проверь что линтер проходит и тесты зелёные` | `/task --prompt="сделай рефакторинг" --verify="линтер проходит и тесты зелёные"` |
| `каждые 4 часа запускай рефакторинг` | `/task --prompt="запускай рефакторинг" --interval="4h"` |
| `/gsd-ship` | `/task --prompt="/gsd-ship"` (команда воркера, завёрнута) |
| `/task --prompt="уже команда"` | `/task --prompt="уже команда"` (системная команда, без изменений) |

Транслятор — AI Agent (DeepSeek), запускается перед парсером команд. Системные команды (`/task`, `/abort`) проходят без изменений. Все остальные слеш-команды заворачиваются для воркера.

### Повторяющиеся задачи

Флаг `--interval="4h"` создаёт задачу, которая перезапускается по расписанию:

1. Задача завершается → статус сбрасывается на `queued` с `queued_at = now + interval`
2. Диспетчер учитывает будущее `queued_at` — задача не выполнится раньше интервала
3. Одна и та же строка в БД, без клонов, без раздувания
4. Отмена через `/abort --task_key="xxx"` — статус `aborted`, цикл остановлен
5. Формат: `30m` (минуты), `4h` (часы), `1d` (дни)

### Пайплайн верификации приёмки

Когда вы указываете `--verify="критерии"` с задачей:

1. OpenCode завершает основную задачу
2. Воркфлоу верификации создаёт **задачу проверки** в очереди (новая сессия, независимо от исходной)
3. Агент выполняет проверку — здоровье кода, логи, консоль браузера (Playwright), ответы API и каждый критерий
4. Задача проверки завершается → верификатор запускается снова
5. **DeepSeek AI judge** оценивает результат и возвращает вердикт PASSED/FAILED
6. При FAILED → авто-создаётся **задача-фикс** с **исходной сессией** и теми же критериями `--verify`
7. Цикл fix → verify → fix → ... повторяется до успешной проверки
8. При PASSED → уведомление, задач больше не создаётся

## Архитектура

```
Telegram / Голос (HA) → n8n ingress → Data Table → n8n dispatcher → OpenCode worker → результат в Telegram + HTTP Request → HA TTS
```

**Сервисы:** `postgres`, `redis`, `n8n`, `n8n-worker`, `opencode-worker-1`, `homeassistant`, `caddy` (опционально)

**n8n Workflows (9):** ingress, dispatcher, session-manager, task-launcher, pending-interaction, task-finalizer, auto-task-generator, acceptance-verifier, cancel-task

## Специалисты-агенты

9 специализированных субагентов + 2 основных (build, plan) с ролевыми разрешениями:

| Агент | Роль | Разрешения |
|-------|------|------------|
| `build` | Универсальный разработчик | Полный доступ: чтение/запись/bash |
| `planner` | Дизайн и архитектура | Только чтение, webfetch разрешён |
| `reviewer` | Код-ревью | Только чтение, без правок |
| `verifier` | Верификация приёмки | Только чтение, bash разрешён |
| `security-auditor` | OWASP + CVE сканирование | Только чтение, ограниченный bash |
| `ci-cd-agent` | Управление пайплайнами | Только чтение, `gh` CLI разрешён |
| `db-analyst` | Анализ баз данных | Только чтение, интроспекция БД |
| `observability-agent` | Анализ логов и мониторинг | Только чтение, просмотр логов |
| `release-manager` | Версионирование и деплой | Только файлы версий |
| `ralph-loop-agent` | GSD Execute+Verify | Полный доступ, оркестрация subagent'ов |

## Конфигурация worker-ов

Worker-ы настраиваются через `workers/config.json.default` — единый источник истины. Директории отдельных worker-ов генерируются setup-скриптом при развёртывании.

```json
{
  "repos": [{
    "slug": "my-project",
    "url": "https://github.com/user/my-project.git",
    "ref": "main",
    "path": "my-project"
  }],
  "tooling": { ... }
}
```

**Поля репозитория:** `slug`, `url`, `ref`, `path`, `package_manager` (по умолчанию `auto`), `turbo_smoke` (`false`), `turbo_tasks` (`["build","test"]`), `auto_start_docker` (`true`).

**tooling** — глобальные пакеты и MCP-серверы. Структура: `npm` (npm install -g), `uv` (uv tool install), `post_install` (команды после установки).

**Лимиты ресурсов worker-ов:** настраиваются через `.env`:
```bash
OPENCODE_WORKER_CPU_LIMIT=2      # ядер CPU на worker
OPENCODE_WORKER_MEMORY_LIMIT=4g  # RAM на worker
```

## Переменные окружения (.env)

Создаётся из `.env.example`. Основные секции:

| Группа | Переменные |
|---|---|
| n8n | `N8N_HOST`, `N8N_VERSION`, `N8N_PROTOCOL`, `N8N_PORT`, `N8N_ENCRYPTION_KEY`, `N8N_BASIC_AUTH_*`, `N8N_API_KEY` |
| База данных | `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` |
| Worker N | `OPENCODE_WORKER_N_NAME`, `_ALIAS`, `_PORT`, `_PASSWORD`, `_BASE_URL`, `_HEALTH_URL` |
| Лимиты worker | `OPENCODE_WORKER_CPU_LIMIT`, `OPENCODE_WORKER_MEMORY_LIMIT` |
| API ключи | `OPENAI_API_KEY`, `DEEPSEEK_API_KEY`, `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`, `GITHUB_TOKEN` |
| Telegram | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_IDSS` |
| Home Assistant | `HA_API_TOKEN`, `HA_NOTIFY_SERVICE`, `HA_PIPELINE_LANGUAGE`, `HA_HOST` |
| OpenCode | `OPENCODE_AGENT`, `OPENCODE_MODEL`, `OPENCODE_PROVIDER_TIMEOUT_MS` |
| Опционально | `DATABASE_URL`, `GITHUB_REPOSITORY`, `BRAVE_API_KEY` |

## Операции

```bash
# Проверка здоровья стека
bash ./scripts/verify-stack.sh

# Запуск с HTTPS
docker compose --profile proxy up -d --build

# Дополнительные worker-ы
docker compose -f docker-compose.yml -f compose.overrides/opencode-worker-2.yml up -d --build

# Очистка executions (автоматически через cron)
bash ./scripts/cleanup-executions.sh
```

## Telegram: первый запуск

1. `bash ./scripts/setup-stack.sh` → укажите `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_IDS`
2. Откройте n8n → Settings → n8n API → создайте API ключ
3. Добавьте в `.env`: `N8N_API_KEY=<key>`
4. `bash ./scripts/bootstrap-telegram-integration.sh`

После `docker compose down -v` скрипт обнаружит недействительный ключ и запросит новый.

## Голосовое управление (Home Assistant)

Включено в стек автоматически. Wyoming Whisper + Piper для локального STT/TTS (~300MB RAM, GPU не нужен). **Полная автоматизация — ни одного клика в UI:**

1. `bash ./scripts/setup-stack.sh` запускает HA + Wyoming контейнеры на порту 8123
2. Откройте HA в браузере, создайте пользователя, Профиль → Безопасность → Долгосрочные токены доступа → создайте токен
3. Установите HA Companion App на телефон, подключитесь к URL HA
4. `bash ./scripts/bootstrap-telegram-integration.sh` — **автоматически сделает всё остальное**:
   - Запросит HA-токен (если не задан в `.env`)
   - Запросит имя сервиса уведомлений для телефона (`notify.mobile_app_*`)
   - Добавит Wyoming whisper (STT) и piper (TTS) через REST API
   - Создаст голосовой pipeline с русским языком через WebSocket API
   - Настроит accept-уведомления через HTTP Request (без HA credential)
   - Конфигурация HA (URL и токен) централизована в Set-нодах каждого воркфлоу
5. Скажите "Окей, Ассистент" чтобы ставить задачи голосом. Результаты озвучиваются через TTS

**Настраиваемые переменные в `.env`:**
- `HA_API_TOKEN` — токен для API (запрашивается при первом запуске)
- `HA_NOTIFY_SERVICE` — полное имя сервиса уведомлений (напр. `notify.mobile_app_infinix_x6731b`)
- `HA_PIPELINE_LANGUAGE` — язык голосового ассистента (по умолчанию `ru`)
- `HA_HOST` — хост HA из перспективы n8n (по умолчанию `$PUBLIC_HA_DOMAIN`, затем `host.docker.internal`)

## Файлы проекта

```
├── docker-compose.yml
├── .env.example
├── scripts/
│   ├── setup-stack.sh
│   ├── bootstrap-telegram-integration.sh
│   ├── setup-wyoming.py
│   ├── verify-stack.sh
│   └── cleanup-executions.sh
├── opencode/
│   ├── Dockerfile
│   └── bin/ (entrypoint, bootstrap-*.sh, install-github-tool.sh)
├── n8n/bootstrap/
│   ├── opencode-endpoints.json
│   └── workflows/templates/
├── ha_config/
│   ├── configuration.yaml
│   ├── automations.yaml
│   └── scripts.yaml
└── workers/
    └── config.json.default
```

## Помощь

- **Проблемы установки:** `bash ./scripts/verify-stack.sh` — проверяет compose, n8n, worker-ы
- **Telegram не работает:** убедитесь что `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_IDS` и `N8N_API_KEY` заданы в `.env`, затем `bash ./scripts/bootstrap-telegram-integration.sh`
- **Worker не отвечает:** `docker compose ps` — все сервисы должны быть healthy; проверьте логи: `docker compose logs opencode-worker-1 --tail 200`
- **Баг-репорты и предложения:** [GitHub Issues](https://github.com/RobertGard/home-dev-assistant/issues)

## Участие в разработке

Pull request-ы приветствуются. Ключевые принципы:

- Никаких захардкоженных значений в bash — все значения по умолчанию из `config.json.default`
- `.env` — идентификация worker-ов (Docker env vars), `config.json` — конфигурация репозиториев/инструментов (монтируется в контейнер)
- `docker compose down -v` не должен требовать ручного восстановления конфигурации
- Все скрипты должны проходить `bash -n` (проверка синтаксиса)
- `workers/config.json.default` — единый источник истины для tooling, без отдельных файлов worker-ов в git
