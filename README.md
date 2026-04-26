# OpenCode + n8n

## Что это

Self-hosted стек, в котором:

- `n8n` оркестрирует выполнение задач
- `OpenCode worker`-ы исполняют инженерную работу
- Telegram используется как основной интерфейс команд и ответов
- очередь задач и уточнения `needs_input` живут внутри `n8n`

## Что нужно для запуска

Обязательно:

- Docker Engine
- Docker Compose
- Telegram bot token, если нужен Telegram-режим

Для полной автоматизации Telegram внутри `n8n` дополнительно нужен:

- `N8N_API_KEY`

Важно:

- `N8N_API_KEY` нельзя взять до первого запуска `n8n`
- сначала подними `n8n`
- потом открой `Settings -> n8n API`
- создай API key
- после этого заверши Telegram bootstrap

Для внешнего доступа к `n8n` по HTTPS дополнительно нужны:

- публичный домен
- открытые порты `80` и `443`
- рабочий DNS на сервер

## Быстрый старт

```bash
bash ./scripts/setup-stack.sh
```

Скрипт:

- создаст `.env`
- настроит worker-ов
- создаст `workers/*/repos.json`
- при необходимости включит внешний HTTPS для `n8n`
- поднимет контейнеры, если ты это подтвердил
- если `N8N_API_KEY` уже есть, создаст Telegram credential и Telegram workflow
- если `N8N_API_KEY` еще нет, предложит ввести его после первого запуска `n8n`
- запустит базовую проверку

## Что спросит установщик

В стандартном режиме:

- нужен ли внешний HTTPS-доступ к `n8n`
- публичный домен и email для `Let's Encrypt`, если внешний доступ включен
- секреты `postgres` и `n8n`
- API ключи, если хочешь указать их сразу
- `TELEGRAM_BOT_TOKEN`, если нужен Telegram
- `TELEGRAM_CHAT_ID`, чтобы бот работал только в одном чате
- `N8N_API_KEY`, если он уже есть; иначе его можно добавить после первого запуска `n8n`
- сколько worker-ов нужно
- конфигурацию каждого worker-а
- запускать ли контейнеры сразу

В расширенном режиме дополнительно:

- имя compose-проекта
- порты
- alias worker-ов
- timeout-ы OpenCode
- дополнительные repo bootstrap настройки

## Что будет работать после установки

Если включен Telegram:

1. пользователь пишет боту
2. `Telegram Trigger` получает сообщение
3. `Telegram Task Ingress` кладет задачу в `n8n Data Table` `agent_tasks`
4. ingress сразу запускает `Telegram Task Dispatcher`
5. dispatcher берет следующую задачу и отправляет ее в нужный OpenCode worker
6. если OpenCode просит уточнение, `n8n` использует `Telegram sendAndWait`
7. после завершения результат отправляется в Telegram
8. dispatcher сразу запускает следующий проход очереди

## Ограничение Telegram по одному чату

Используется `TELEGRAM_CHAT_ID`.

Это означает:

- команды принимаются только из одного чата
- сообщения из других чатов не проходят дальше по workflow
- задачи из чужих чатов не попадают в очередь
- ответы и уточнения отправляются только в этот чат

## Внешний доступ к n8n

Если внешний доступ включен, setup настраивает:

- `Caddy` как reverse proxy
- `WEBHOOK_URL=https://<домен>/`
- `N8N_EDITOR_BASE_URL=https://<домен>/`
- `N8N_HOST=<домен>`
- `N8N_PROTOCOL=https`
- `N8N_PROXY_HOPS=1`

Сертификаты выпускает `Caddy` через `Let's Encrypt`.

Чтобы это реально заработало:

1. домен должен указывать на сервер
2. порты `80` и `443` должны быть открыты
3. другой сервис не должен занимать `80` и `443`

## Состав стека

Обязательные сервисы:

- `n8n`
- `n8n-worker`
- `postgres`
- `redis`
- `opencode-worker-1`

Опциональные сервисы:

- `caddy`
- дополнительные `OpenCode worker`-ы через `compose.overrides/*.yml`

## OpenCode worker

Worker умеет:

- клонировать и обновлять репозитории
- ставить зависимости
- запускать lint, typecheck, tests, build
- поднимать Docker-инфраструктуру проекта
- выполнять задачи через OpenCode API

Установленные инструменты:

- `opencode`
- `git`, `gh`, `jq`, `ripgrep`, `fd`, `bat`, `tree`
- `docker`, `docker compose`
- `node`, `pnpm`, `bun`, `turbo`, `tsx`, `typescript`
- `eslint`, `prettier`, `biome`, `vitest`, `jest`, `ts-jest`, `ts-node`, `vite`, `nx`, `nodemon`, `prisma`, `typescript-language-server`, `vscode-langservers-extracted`
- `python3`, `pip`, `uv`
- `shellcheck`, `yamllint`, `sqlite3`

Agent-расширения:

- `get-shit-done`
- `superpowers`
- `Context7`
- `Serena`

## Репозитории worker-а

У каждого worker-а есть свой файл:

- `workers/worker-1/repos.json` создается установщиком
- `workers/<worker-name>/repos.json` создается установщиком для дополнительных worker-ов

Шаблоны лежат здесь:

- `workers/worker-1/repos.json.example`
- `workers/worker-2/repos.json.example`

Пример:

```json
{
  "repos": [
    {
      "slug": "example-project",
      "url": "https://github.com/example/example-project.git",
      "ref": "main",
      "path": "example-project",
      "install_dependencies": true,
      "package_manager": "auto",
      "turbo_smoke": false,
      "turbo_tasks": ["build", "test"],
      "install_gsd_local": true,
      "auto_start_docker": true
    }
  ]
}
```

Главные поля:

- `slug`
- `url`
- `ref`
- `path`
- `install_dependencies`
- `package_manager`
- `turbo_smoke`
- `turbo_tasks`
- `install_gsd_local`
- `auto_start_docker`

## Очередь задач

Используется встроенная `n8n Data Table`:

- `agent_tasks`

Ключевые поля:

- `task_key`
- `worker_alias`
- `status`
- `session_id`
- `pending_question`
- `pending_options_json`
- `result_text`

Поддерживаемые состояния:

- `queued`
- `running`
- `needs_input`
- `done`
- `failed`

## OpenCode API

Каждый worker поднимает OpenCode server API.

Базовый адрес worker-а хранится в:

- `n8n/local-files/opencode-routing.json`

Основные реально используемые endpoint-ы:

- `GET /global/health`
- `POST /session`
- `POST /session/:id/message`
- `POST /session/:id/command`
- `POST /session/:id/shell`

В `opencode-routing.json` лежит полный документированный набор endpoint-ов OpenCode server.

## Ручной запуск

Без внешнего proxy:

```bash
docker compose up -d --build
```

С внешним proxy:

```bash
docker compose --profile proxy up -d --build
```

С дополнительными worker-ами:

```bash
docker compose -f docker-compose.yml -f compose.overrides/opencode-worker-2.yml up -d --build
```

Если создаешь worker helper-скриптом:

```bash
./opencode/bin/add-opencode-worker.sh worker-2 4097 workers/worker-2
```

## Проверка после установки

Используются скрипты:

```bash
bash ./scripts/bootstrap-telegram-integration.sh
bash ./scripts/verify-stack.sh
```

Проверяется:

1. поднялись ли сервисы compose
2. отвечает ли `n8n`
3. отвечают ли OpenCode worker-ы из routing-файла
4. валиден ли `opencode-routing.json`
5. если включен Telegram, корректно ли созданы Telegram credential и Telegram workflow

## Если Telegram не донастроился на первом запуске

Если `N8N_API_KEY` не был задан заранее, это нормально.

Порядок действий:

1. Подними стек
2. Открой `n8n`
3. Перейди в `Settings -> n8n API`
4. Создай API key
5. Добавь его в `.env` как `N8N_API_KEY`
6. Запусти:

```bash
bash ./scripts/bootstrap-telegram-integration.sh
```

## Основные файлы

Конфигурация:

- `docker-compose.yml`
- `.env.example`
- `infra/Caddyfile`

Setup и bootstrap:

- `scripts/setup-stack.sh`
- `scripts/bootstrap-telegram-integration.sh`
- `scripts/verify-stack.sh`

OpenCode:

- `opencode/Dockerfile`
- `opencode/bin/bootstrap-opencode.sh`
- `opencode/bin/bootstrap-repos.sh`
- `opencode/bin/add-opencode-worker.sh`

n8n:

- `n8n/local-files/opencode-routing.json`
- `n8n/local-files/workflows/templates/telegram-task-ingress.template.json`
- `n8n/local-files/workflows/templates/telegram-task-dispatcher.template.json`

## Коротко

- `n8n` оркестрирует
- OpenCode worker-ы исполняют
- Telegram встроен в `n8n`
- очередь задач живет во встроенных `n8n Data Tables`
- внешний HTTPS для `n8n` делает `Caddy`
- установка и bootstrap идут через `scripts/setup-stack.sh`
