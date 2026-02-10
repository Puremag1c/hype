# Hype — Project Context

## Что это

**Hype** — многоагентная система автоматической разработки на базе Claude Code.

Запустите `hype init` в любом проекте, опишите что хотите словами — система сама создаст план, распределит задачи между агентами и выдаст готовый результат.

**Версия:** 2.1.12

## Целевая аудитория

**Обычные люди без технического бэкграунда.** Пользователь может не знать что такое git, Python или терминал.

**Принцип:** Всё что можно автоматизировать — автоматизировано:
- Установка зависимостей (beads, gh, gitleaks) — автоматически
- Инициализация git и beads — автоматически
- Создание GitHub репозитория — предложение + автоматически
- Авторизация в GitHub — пошаговые подсказки
- Запуск системы — одна команда

**Пользователю нужно только:**
1. Скопировать команду установки в терминал
2. Отвечать на вопросы системы словами
3. Получить результат

## Структура проекта

```
hype/
├── bin/hype                 # CLI (init, start, status, update, delete, doctor)
├── core/
│   ├── agents/              # Промпты агентов (26 шт)
│   │   ├── manager.md           # Координатор фаз (Sonnet)
│   │   ├── tech-writer.md       # Сбор требований (Opus)
│   │   ├── architect-planner.md # Создание плана из SPEC (Opus)
│   │   ├── architect-reviewer.md# Ревью добавлений аналитиков (Opus)
│   │   ├── architect-qa.md      # Final review + regression (Opus)
│   │   ├── architect-ops.md     # Conflicts, cycles (Sonnet)
│   │   ├── executor.md          # Реализация задач (по label)
│   │   ├── reviewer.md            # Code review only (v2.2)
│   │   ├── senior-executor.md   # Code review + merge (legacy)
│   │   ├── auditor.md           # Аудит задач с label:audit (Sonnet→Opus)
│   │   ├── analyzer.md          # Deep analysis кода (Opus)
│   │   ├── versioner.md         # VERSION + CHANGELOG (Haiku)
│   │   ├── architect-troubleshooter.md # Persistent failure resolution (Opus)
│   │   ├── tech-writer-review.md  # Non-technical user report (Sonnet)
│   │   ├── analyst-*.md         # 5 аналитиков (Sonnet)
│   │   └── tester-*.md          # 6 тестеров (по типу проекта)
│   ├── scripts/             # Bash скрипты (14 шт)
│   │   ├── hype.sh              # Главный цикл с lock file
│   │   ├── detect-phase.sh      # Определение фазы (JSON output)
│   │   ├── common.sh            # Shared functions
│   │   ├── run-analysts.sh      # Параллельный запуск аналитиков
│   │   ├── run-executors.sh     # Параллельный запуск исполнителей
│   │   ├── run-reviewers.sh       # Parallel code review (v2.2)
│   │   ├── run-merge-queue.sh    # Sequential merge queue (v2.2)
│   │   ├── run-senior-executor.sh # Review + merge (legacy)
│   │   ├── run-testers.sh       # Параллельный запуск тестеров
│   │   └── ...
│   └── commands/            # Slash-команды (/start, /status)
├── docs/                    # Документация
│   ├── architecture.md          # Как работает HYPE (для Doctor)
│   └── troubleshooting.md       # Известные проблемы (для Doctor)
├── templates/               # Шаблоны (config, SPEC, CLAUDE)
├── install.sh               # Глобальная установка
└── CHANGELOG.md             # История версий
```

## Фазы работы

```
INIT → PLANNING → HELPERS → PLAN_REVIEW → IMPLEMENTATION → SMOKE_TEST → FINAL_REVIEW → DONE
                                              ↑                 ↓
                                              └── SMOKE_REVIEW ←┘ (smoke/regression tasks)
                                         USER_REVIEW ← (user-escalation → daemon stops)
```

| Фаза | Агент | Что происходит |
|------|-------|----------------|
| INIT | Tech Writer | Собирает требования, создаёт SPEC.md (+ deep analysis для больших проектов) |
| PLANNING | Architect-Planner | Создаёт задачи в beads, расставляет deps |
| HELPERS | Analysts ×5 | Параллельный аудит плана |
| PLAN_REVIEW | Architect-Reviewer | Ревью добавлений от Analysts |
| IMPLEMENTATION | Executors + Reviewers + Merge Queue | Параллельная реализация + review + merge (v2.2) |
| SMOKE_TEST | Testers ×6 | Параллельная проверка (по типу проекта) |
| SMOKE_REVIEW | Architect-QA | Триаж smoke test находок (smoke + regression) |
| USER_REVIEW | Tech-Writer-Review | Отчёт для пользователя, daemon stops |
| FINAL_REVIEW | Architect-QA | Проверка целостности |
| VERSIONING | Versioner | Обновление VERSION + CHANGELOG |
| DONE | — | Проект завершён |

### SMOKE_TEST Testers

| Tester | Model | Project Types | Focus |
|--------|-------|---------------|-------|
| tester-functional | sonnet | ALL | Must Have из SPEC.md |
| tester-visual | opus | web | UI через Playwright MCP |
| tester-api | haiku | api, web | Endpoints, статус коды |
| tester-cli | haiku | cli | Команды, --help |
| tester-regression | sonnet | library | Тестовый suite |
| tester-backend | sonnet | ALL | Запуск существующих тестов + генерация новых |

**Hard gate:** P0 bugs блокируют milestone:smoke-test-done → возврат в IMPLEMENTATION

**Smoke triage:** ВСЕ баги из SMOKE_TEST получают label `smoke`. Regression reopens получают `smoke` + `regression`. Architect-QA триажит каждый баг в SMOKE_REVIEW перед тем как executors смогут его взять.

**Regression counter:** `regress:N` — script-driven счётчик в `run-testers.sh`. Отслеживает сколько раз баг возвращался.

**Escalation ladder:** reject:1→retry, reject:2-3→escalate model (haiku→sonnet→opus), reject:4→Troubleshooter. Troubleshooter: reformulate / split / remove / escalate to user.

### Deep Analysis (INIT)

Для существующих проектов с >50 файлами кода и без хорошего README — автоматически запускается глубокий анализ через Claude (Opus). Tech Writer получает обогащённый контекст об архитектуре проекта.

## Ключевые принципы

### Архитектура
- **Bash вызывает bash** — механика в скриптах, LLM только для решений
- **Beads как источник правды** — всё состояние в задачах, не в файлах
- **Атомарные операции** — lock file через `set -C`, claim через `bd update --claim`
- **Fail fast** — daemon down = stop, не продолжаем без sync

### Агенты
- **Изоляция** — каждый агент работает со своими данными
- **Простые команды** — одна операция = одна команда bd
- **Идемпотентность** — повторный запуск даёт тот же результат
- **Таймауты** — 10 мин на задачу, escalation ladder до Troubleshooter

### Git workflow
- Executor: работает в ветке `task/beads-xxx`, WIP commit перед rebase
- Reviewer: проверяет diff (parallel, lock-based backpressure, v2.2)
- Merge Queue: squash merge approved задач (sequential, v2.2)
- Backpressure: лимит параллельных executors/reviewers через lock files в `.hype-worktrees/`

## Конфигурация проекта

После `hype init` создаётся `.hype/config.sh`:

```bash
MAX_PARALLEL_EXECUTORS=3    # Лимит параллельных задач
RETRY_LIMIT=3               # Retry до эскалации
TASK_TIMEOUT="10m"          # Таймаут на задачу
```

### Testing config (`.hype/testing.yaml`)

Для web/api проектов — конфигурация тестирования:

```yaml
type: web                    # web | api | cli | library
build_command: npm run build # Команда сборки (опционально)
start_command: npm start     # Запуск dev-сервера
test_url: http://localhost:3000
health_check: /health        # Endpoint для проверки готовности
startup_timeout: 30          # Секунды на запуск сервера
```

Если файл отсутствует — создаётся P0 задача для Opus.

## Зависимости

**Обязательные:**
- beads — управление задачами
- claude — Claude Code CLI

**Опциональные:**
- gh — GitHub CLI (для PR workflow)
- gitleaks — secret detection (авто-установка при наличии GitHub)

## v2.2.0: Parallel Review Pipeline (в разработке)

- **Parallel Reviewers** — `run-reviewers.sh` запускает до `MAX_PARALLEL_REVIEWERS` ревьюеров одновременно
- **Merge Queue** — `run-merge-queue.sh` последовательно мержит approved задачи (squash merge)
- **Reviewer agent** — `reviewer.md` — review-only промпт (без merge/push)
- **Label state machine** — `needs-review` → `reviewing` → `approved` → `reviewed` (closed)
- **Atomic claims** — `try_claim_for_review()` через mkdir lock + bd label
- **Self-healing** — reviewing stuck >3min → return to queue; approved stuck >5min → warning
- **detect-phase.sh** — отслеживает reviewing/approved counts в JSON output
- **Doctor** — собирает reviewer slots, review locks, reviewing/approved tasks

## v2.1.0: Review Escalation & Model Switching (завершено)

- **Unified reject:N counter** — один счётчик отказов для всех review/rework путей
- **Model escalation ladder** — автоматическая эскалация: reject:1→retry, reject:2-3→upgrade model, reject:4→Troubleshooter
- **Architect Troubleshooter** — новый агент для persistent failures (reformulate / split / remove / escalate to user)
- **USER_REVIEW phase** — daemon stops, tech-writer-review генерирует отчёт для пользователя
- **Regression counter regress:N** — script-driven, отслеживает regression cycles
- **Smoke triage gate** — все баги из SMOKE_TEST проходят через Architect review
- **Regression-aware final_review** — 3-step протокол (check open → check closed → create new)

## v2.0.0: Testing Infrastructure (завершено)

- **Doctor** — диагностика проблем, doctor-log для архитектора
- **6 параллельных тестеров** — functional, backend, visual, api, cli, regression
- **SMOKE_TEST/SMOKE_REVIEW** — hard gate на P0 bugs

## Планируется

- OS Notifications (macOS/Linux)
- Webhook уведомления (Telegram, Slack)
- Автодокументация (README, API docs)
- Web UI для мониторинга

---

## ВАЖНО: Работа с файлами агентов

Файлы в `core/agents/*.md` — это **КОД ПРОЕКТА**, не инструкции для текущей сессии.

При работе над hype эти файлы редактируются как обычный код. Они станут инструкциями когда система будет установлена в целевой проект.
