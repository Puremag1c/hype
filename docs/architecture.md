# Hype Architecture

Многоагентная AI-система автоматической разработки на базе Claude Code.

## Обзор

```
hype.sh (bash loop с lock file)
    │
    ├─► detect-phase.sh → определяет текущую фазу
    │
    ├─► НАПРЯМУЮ вызывает по фазе:
    │   ├─► INIT: Tech Writer (Opus, interactive)
    │   ├─► PLANNING: Architect (Opus) — create_plan
    │   ├─► HELPERS: run-analysts.sh → Analysts (Sonnet × 5)
    │   ├─► PLAN_REVIEW: Architect (Opus) — plan_review
    │   ├─► IMPLEMENTATION: run-executors.sh + run-senior-executor.sh
    │   └─► FINAL_REVIEW: Architect (Opus) — final_review
    │
    └─► Manager (Sonnet) — ТОЛЬКО при проблемах:
        ├─► Blocked tasks
        ├─► Retry limit exceeded
        └─► Эскалации
```

**Ключевой принцип:** Bash вызывает bash (механика). LLM используется только для решений.

## Фазы проекта

```
INIT → PLANNING → HELPERS → PLAN_REVIEW → IMPLEMENTATION → SMOKE_TEST → FINAL_REVIEW → DONE
                                              ↑                 ↓
                                              └── SMOKE_REVIEW ←┘ (если есть regression)
```

| Фаза | Условие перехода | Агент | Действие |
|------|-----------------|-------|----------|
| INIT | Нет SPEC.md | Tech Writer | Собирает требования от user (+ deep analysis для больших проектов) |
| PLANNING | Есть SPEC.md | Architect | Создаёт задачи в beads |
| HELPERS | milestone:planning-done | Analysts ×5 | Параллельный аудит плана |
| PLAN_REVIEW | milestone:analysts-done | Architect | Ревьюит добавления Analysts |
| IMPLEMENTATION | milestone:plan-reviewed | Executors | Реализуют задачи |
| SMOKE_TEST | milestone:impl-done | Testers ×N | Параллельная проверка работоспособности (по типу проекта) |
| SMOKE_REVIEW | P0 bugs найдены | Architect | Обработка regression bugs (эскалация, контекст, приоритет) |
| FINAL_REVIEW | milestone:smoke-test-done | Architect | Проверяет целостность |
| DONE | milestone:project-done | — | Проект завершён |

## Агенты

### Manager (Sonnet)
- **Роль:** Problem Advisor (советник для проблем)
- **Вызывается:** ТОЛЬКО при наличии blocked tasks или retry limit
- **Задача:** Анализировать проблемы, давать рекомендации
- **Не делает:** НЕ координирует фазы, НЕ запускает скрипты

### Tech Writer (Opus)
- **Роль:** Сбор требований
- **Задача:** Через диалог с user создать SPEC.md
- **Особенности:** Интерактивный режим, без timeout

### Architect (Opus)
- **Роль:** Главный технический эксперт
- **Задачи:**
  - Создание плана из SPEC.md
  - Разбивка на мелкие задачи (1-5 мин)
  - Расстановка dependencies
  - Назначение модели каждой задаче
  - Ревью добавлений от Analysts
  - Разрешение конфликтов и эскалаций

### Analysts (Sonnet × 5)
- **Роль:** Параллельный аудит плана
- **Виды:**
  - UX — пользовательские сценарии, UI состояния
  - Security — OWASP, auth, secrets
  - OPS — тесты, CI/CD, мониторинг
  - Reliability — edge cases, failure modes
  - Architecture — структура кода, зависимости
- **Правило:** Только добавляют задачи, не удаляют

### Executor (по задаче)
- **Роль:** Реализация одной задачи
- **Модель:** Из label задачи (model:haiku/sonnet/opus)
- **Workflow:**
  1. Claim задачу через `bd update --claim`
  2. Работает в ветке `task/beads-{id}`
  3. Rebase на main
  4. Push и пометить `needs-review`

### Senior Executor (tiered)
- **Роль:** Quality gate перед main
- **Модель:** opus задачи → opus review, остальные → sonnet
- **Задачи:**
  - Code review
  - Проверка на secrets
  - Merge через PR (или local merge)
  - Релиз

### Testers (SMOKE_TEST фаза)
- **Роль:** Проверка работоспособности после IMPLEMENTATION
- **Виды:**
  - `tester-functional` (sonnet) — Must Have из SPEC.md (все проекты)
  - `tester-visual` (opus) — UI через Playwright MCP (web)
  - `tester-api` (haiku) — Endpoints, статус коды (api, web)
  - `tester-cli` (haiku) — Команды, --help (cli)
  - `tester-regression` (sonnet) — Тестовый suite (library)
- **Hard gate:** P0 bugs блокируют milestone:smoke-test-done → возврат в IMPLEMENTATION

## Скрипты

| Скрипт | Назначение |
|--------|------------|
| `hype.sh` | Главный цикл с lock file |
| `detect-phase.sh` | Определение текущей фазы |
| `run-analysts.sh` | Параллельный запуск 5 Analysts |
| `run-executors.sh` | Параллельный запуск Executors с backpressure |
| `run-senior-executor.sh` | Code review и merge |
| `run-testers.sh` | Параллельный запуск Testers (SMOKE_TEST) |
| `common.sh` | Общие функции (timeout, reset_stale_tasks, milestones) |
| `log.sh` | Хелпер для логирования |
| `notify.sh` | Уведомления (macOS, Linux, WSL) |
| `analyze-project.sh` | Анализ структуры проекта |
| `deep-analyze.sh` | Глубокий анализ через Claude (INIT) |
| `close-completed-parents.sh` | Автозакрытие parent tasks |

## Конфигурация

### `.hype/config.sh`

```bash
MAX_PARALLEL_EXECUTORS=3    # Лимит параллельных Executors
RETRY_LIMIT=3               # Retry до эскалации к Architect
TASK_TIMEOUT="10m"          # Таймаут на задачу
WORKTREE_STALE_TIMEOUT=900  # Секунды до удаления stale worktree
TASK_STALE_TIMEOUT=600      # Секунды до сброса stale task
ALLOWED_MODELS="opus,sonnet,haiku"  # Разрешённые модели
```

### `.hype/testing.yaml` (SMOKE_TEST)

```yaml
type: web                    # web | api | cli | library
build_command: npm run build # Команда сборки (опционально)
start_command: npm start     # Запуск dev-сервера
test_url: http://localhost:3000
health_check: /health        # Endpoint для проверки готовности
startup_timeout: 30          # Секунды на запуск сервера
```

Если файл отсутствует для web/api проекта — создаётся P0 задача для Opus.

## Beads интеграция

### Архитектура Beads (КРИТИЧНО)

**Beads использует daemon + SQLite. Понимание этой архитектуры критично для HYPE.**

```
┌─────────────────────────────────────────────────────────┐
│                      bd CLI                             │
│  (bd list, bd update, bd create, etc.)                  │
└─────────────────┬───────────────────────────────────────┘
                  │ RPC (Unix socket)
                  ▼
┌─────────────────────────────────────────────────────────┐
│                    bd daemon                            │
│  - Сериализует все операции                             │
│  - Держит SQLite connection                             │
│  - Import/Export между SQLite ↔ JSONL                   │
│  - Sync с git remote (beads-sync branch)                │
└─────────────────┬───────────────────────────────────────┘
                  │ SQLite
                  ▼
┌─────────────────────────────────────────────────────────┐
│              .beads/beads.db (SQLite)                   │
│  - WAL mode для concurrency                             │
│  - busy_timeout = 30 сек                                │
│  - BEGIN IMMEDIATE для write locks                      │
└─────────────────────────────────────────────────────────┘
```

### Правила работы с Beads

**1. ВСЕГДА через daemon**
```bash
# ✓ Правильно — идёт через daemon
bd list --json
bd update $id --status=in_progress

# ✗ НЕПРАВИЛЬНО — direct access создаёт lock contention
BEADS_NO_DAEMON=1 bd update $id
```

**2. Worktrees используют redirect**
```
main-repo/.beads/beads.db     ← единственная база
worktree/.beads/redirect      ← указывает на main-repo/.beads/
```
Все worktrees идут в одну базу через redirect. Daemon сериализует доступ.

**3. Не смешивать daemon и direct access**
- Если daemon работает → все запросы через него
- `BEADS_NO_DAEMON=1` отключает daemon → direct SQLite access
- Микс daemon + direct = SQLite lock война

**4. Типичные ошибки**

| Симптом | Причина | Решение |
|---------|---------|---------|
| `database is locked` | Параллельные direct access | Убрать BEADS_NO_DAEMON |
| 2+ минуты на bd запрос | Lock contention | Остановить daemon, почистить базу |
| `failed to handle rename` | Tombstone в JSONL | Удалить tombstone, пересоздать базу |
| Зависшие `git fetch beads-sync` | Сетевые проблемы | `pkill -f "git fetch.*beads-sync"` |

**5. Восстановление после проблем**
```bash
# 1. Остановить всё
pkill -9 -f "bd daemon"
pkill -f "git fetch.*beads-sync"

# 2. Почистить базу
rm -f .beads/beads.db .beads/beads.db-* .beads/daemon.*

# 3. Мигрировать
bd migrate --update-repo-id

# 4. Запустить daemon
bd daemon start
```

### Статусы задач

- `open` — задача создана, ждёт исполнителя
- `in_progress` — Executor работает
- `in_progress` + `needs-review` — ждёт Senior Executor
- `closed` — завершено

### Labels

- `model:haiku/sonnet/opus` — какая модель выполняет
- `added-by:analyst-*` — кто добавил задачу
- `milestone:*` — маркер завершения фазы
- `retry:N` — счётчик повторных попыток
- `blocked:*` — причина блокировки

### Dependencies

```bash
bd dep add <task-id> <depends-on-id>
bd dep cycles  # Проверка циклов
```

## Отказоустойчивость

### Lock file
- Один HYPE за раз
- Atomic через `set -C` (noclobber)
- Автоочистка stale lock

### Retry logic
- 3 попытки на задачу
- Счётчик в label `retry:N`
- После лимита — эскалация к Architect

### Graceful shutdown
- `trap SIGINT SIGTERM`
- Reset stale tasks (>5min in_progress)
- Cleanup lock file

### Config validation
- Проверка при каждой итерации
- Integers, booleans, timeouts
- Fail fast при ошибках

## Git workflow

```
main
  │
  ├── task/beads-abc  ← Executor 1
  ├── task/beads-def  ← Executor 2
  └── task/beads-ghi  ← Executor 3
```

1. Executor создаёт ветку от main
2. Работает, коммитит
3. Rebase на main (при конфликте — эскалация)
4. Push с `--force-with-lease`
5. Senior Executor мержит через PR

## Backpressure

- Лимит = `MAX_PARALLEL_EXECUTORS`
- Считаем через beads (не gh pr list)
- Работает без GitHub

## Логирование

Формат: `YYYY-MM-DD HH:MM:SS [AGENT] EVENT: message`

```bash
./scripts/log.sh MANAGER INFO "Starting phase detection"
./scripts/log.sh EXECUTOR TASK_START "hype-abc"
./scripts/log.sh ORCHESTRATOR FATAL "Beads daemon not running"
```

## Установка

```bash
# Глобальная установка (один раз)
curl -fsSL https://raw.githubusercontent.com/Puremag1c/hype/main/install.sh | bash

# В любом проекте
cd your-project
hype init
```

## Зависимости

- **beads** — управление задачами
- **claude** — Claude Code CLI
- **gh** — GitHub CLI (опционально)
- **jq** — JSON processing
- **gitleaks** — secret detection (опционально)
