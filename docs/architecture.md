# Hype Architecture

Многоагентная AI-система автоматической разработки на базе Claude Code.

## Обзор

```
hype.sh (bash loop с lock file)
    │
    ├─► detect-phase.sh → определяет текущую фазу (JSON output)
    │
    ├─► НАПРЯМУЮ вызывает по фазе:
    │   ├─► INIT: Tech Writer (Opus, interactive)
    │   ├─► PLANNING: Architect-Planner (Opus)
    │   ├─► HELPERS: run-analysts.sh → Analysts (Sonnet × 5)
    │   ├─► PLAN_REVIEW: Architect-Reviewer (Opus)
    │   ├─► IMPLEMENTATION: run-executors.sh + run-reviewers.sh + run-merge-queue.sh
    │   ├─► SMOKE_TEST: run-testers.sh (background) → Testers × 6
    │   ├─► SMOKE_REVIEW: Architect-QA (Opus)
    │   ├─► USER_REVIEW: Tech-Writer-Review (Sonnet) → daemon stops
    │   ├─► FINAL_REVIEW: Architect-QA (Opus)
    │   ├─► VERSIONING: Versioner (Haiku)
    │   └─► BLOCKED_CYCLES: Architect-Ops (Sonnet)
    │
    ├─► Troubleshooter (Opus) — при blocked:troubleshoot (reject:4+)
    │
    └─► Manager (Sonnet) — при прочих blocked/retry-limit
```

**Ключевой принцип:** Bash вызывает bash (механика). LLM используется только для решений.

## Фазы проекта

```
INIT → PLANNING → HELPERS → PLAN_REVIEW → IMPLEMENTATION → SMOKE_TEST → FINAL_REVIEW → VERSIONING → DONE
                                              ↑                  ↓
                                              └── SMOKE_REVIEW ←─┘ (smoke/regression tasks)
                                         USER_REVIEW ← (user-escalation label → daemon stops)
```

| Фаза | Условие перехода | Агент | Действие |
|------|-----------------|-------|----------|
| INIT | Нет SPEC.md | Tech Writer | Собирает требования от user (+ deep analysis для больших проектов) |
| PLANNING | Есть SPEC.md | Architect-Planner | Создаёт задачи в beads |
| HELPERS | milestone:planning-done | Analysts ×5 | Параллельный аудит плана |
| PLAN_REVIEW | milestone:analysts-done | Architect-Reviewer | Ревьюит добавления Analysts |
| IMPLEMENTATION | milestone:plan-reviewed | Executors + Auditor | Реализуют задачи + аудит |
| SMOKE_TEST | все задачи closed | Testers ×6 | Параллельная проверка работоспособности |
| SMOKE_REVIEW | smoke/regression tasks найдены | Architect-QA | Триаж всех smoke test находок |
| USER_REVIEW | user-escalation label | Tech-Writer-Review | Генерирует отчёт, daemon stops |
| FINAL_REVIEW | milestone:smoke-test-done | Architect-QA | Проверяет целостность |
| VERSIONING | FINAL_REVIEW: PASSED | Versioner | Обновляет VERSION + CHANGELOG |
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

### Architect (4 специализированных агента)

**Декомпозирован в v1.9.19** — один большой architect.md разбит на 4 фокусных агента:

| Агент | Model | Задача |
|-------|-------|--------|
| architect-planner | opus | Создание плана из SPEC.md, разбивка на задачи, deps |
| architect-reviewer | opus | Ревью добавлений от Analysts |
| architect-qa | opus | Final review, обработка regression bugs |
| architect-ops | sonnet | Разрешение git conflicts, dependency cycles |

**Принцип:** Opus для решений, Sonnet для механических операций.

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

### Reviewer (v2.2, parallel)
- **Роль:** Code review (без merge)
- **Модель:** sonnet по умолчанию, opus при reject:2+ или reject:4
- **Управление:** `run-reviewers.sh`, до `MAX_PARALLEL_REVIEWERS` параллельно
- **Workflow:**
  1. Atomic claim: `try_claim_for_review()` (mkdir lock + label)
  2. Preflight: проверка ветки, коммитов, secret scanning (v2.2.1)
  3. Build context: diff, commits, executor log, secrets warning
  4. Claude review с `reviewer.md` промптом
  5. Результат: approve (label) / reject (status=open) / no-merge (close)
- **Preflight checks (v2.2.1):**
  - Проверка что ветка существует (`NO_BRANCH` → reject)
  - Проверка что есть коммиты (`NO_COMMITS` → reject)
  - Secret scanning: grep по diff на API keys, passwords, secrets, .env → `SECRETS_WARNING` + label `secrets-warning` → reviewer решает (soft, не hard reject)
  - Circuit breaker: если reformulated задача ломается по той же причине (`last-reject:{TYPE}` label) → `user-escalation`
- **Timeout handling (v2.2.2):** Если Claude таймаутится (exit 124) — задача возвращается в `needs-review` БЕЗ инкремента `reject:N`. Timeout = инфраструктурная проблема, не отказ
- **Backpressure:** Lock-based (`reviewer-N.lock`), stale cleanup >20 min
- **Escalation:** reject:1→retry, reject:2-3→model, reject:4→troubleshooter

### Merge Queue (v2.2 → v2.3.11, hybrid)
- **Роль:** Squash merge approved задач в main
- **Управление:** `run-merge-queue.sh`, одна задача за вызов (sequential, safe)
- **Hybrid workflow (v2.3.11):**
  1. **Fast path** (`try_fast_merge`): rebase → squash → commit → push. Бесплатно, ~5 сек
  2. **Agent fallback** (`run_merger_agent`): если fast path fails — запускает Claude merger agent (opus) с контекстом конфликта. Агент понимает diff, разрешает конфликты, мержит
  3. **Executor fallback**: если и агент не справился — задача возвращается executor с подробными notes
  4. **Empty merge detection**: между fast path и agent — проверка diff. Если branch changes уже в main → close без agent call
- **Hook isolation (v2.3.4):** Все git операции через `git_nh()` (`core.hooksPath=/dev/null`). Target project hooks вызывают `bd` напрямую — под нагрузкой убивают daemon
- **Pre-flight check (v2.3.4):** Проверка `git status --porcelain` перед merge. Dirty tree → reset --hard
- **Merger agent (`merger.md`, v2.3.11):** Получает branch diff, conflict info, error context. Использует `git -c core.hooksPath=/dev/null`. Закрывает задачу через `bd close` при успехе
- **Audit tasks:** Close without merge

### Auditor (Sonnet → Opus)
- **Роль:** Аудит задач с label `audit`
- **Когда:** Задачи с "AUDIT SCOPE" в description или label `audit`
- **Выход:** Findings в notes задачи, не код
- **Эскалация:** sonnet → opus при timeout/failure

### Versioner (Haiku)
- **Роль:** Обновление VERSION и CHANGELOG после FINAL_REVIEW
- **Когда:** После успешного FINAL_REVIEW: PASSED
- **Задачи:**
  - Определяет тип изменений (major/minor/patch)
  - Обнаруживает источник версии в целевом проекте (v2.2.1): `package.json`, `pyproject.toml`, `Cargo.toml`, `mix.exs`, etc. — обновляет версию где она определена, не только `VERSION` файл
  - Добавляет запись в CHANGELOG.md

### Architect Troubleshooter (Opus)
- **Роль:** Разрешение persistent failures (reject:4+)
- **Когда:** Задача получает label `blocked:troubleshoot`
- **Решения:**
  - REFORMULATE — переписать задачу с другим подходом (label `reformulated`, макс 2 раза)
  - SCOPE REDUCTION — разбить на более простые задачи
  - REMOVE FROM SCOPE — закрыть как нерешаемую
  - ESCALATE TO USER — label `user-escalation`, daemon stops

### Tech Writer Review (Sonnet)
- **Роль:** Генерация non-technical отчёта для пользователя
- **Когда:** Фаза USER_REVIEW (задачи с `user-escalation` label)
- **Выход:** `.hype/evidence/user-review-report.md`

### Testers (SMOKE_TEST фаза)
- **Роль:** Проверка работоспособности после IMPLEMENTATION
- **Виды (6 штук):**
  - `tester-functional` (sonnet) — Must Have из SPEC.md (все проекты)
  - `tester-backend` (sonnet) — Запуск существующих тестов + генерация новых (все проекты)
  - `tester-visual` (opus) — UI через Playwright MCP (web)
  - `tester-api` (haiku) — Endpoints, статус коды (api, web)
  - `tester-cli` (haiku) — Команды, --help (cli)
  - `tester-regression` (sonnet) — Тестовый suite (library)
- **Sequential:** functional + visual запускаются последовательно (Playwright MCP conflicts)
- **Async (v2.2.6):** `run-testers.sh` запускается в background с PID tracking. HYPE продолжает тикать (check_beads, heal каждый цикл). Три состояния: running (PID alive → wait), never launched (no PID file → start), finished/crashed (PID dead → check results or re-launch orphans)
- **Hard gate:** P0 bugs блокируют milestone:smoke-test-done → возврат в IMPLEMENTATION

### Doctor (Opus)
- **Роль:** Диагностика проблем HYPE, формирование doctor-log
- **Вызывается:** `hype doctor` (интерактивно) или `hype doctor --report` (автоматически)
- **Pre-flight:** `check_beads()` проверяет daemon через `bd daemon status` (v2.3.1). Без daemon — Doctor работает с ограниченными данными
- **Workflow:**
  1. `gather_context()` — 11 категорий: HYPE version, beads status, in-progress tasks, blocked tasks, current phase, running processes, git status, HYPE markers, executor worktrees, review pipeline (v2.2), recent logs
  2. `load_knowledge()` — загружает `architecture.md` + `troubleshooting.md` как knowledge base
  3. `build_prompt()` — agent prompt + context + knowledge → Claude
  4. Claude диагностирует и создаёт doctor-log в `.hype/logs/doctor-TIMESTAMP.md`
- **Два режима:**
  - **Интерактивный:** Claude ведёт диалог, после сессии предлагает отправить doctor-log (`read -p`)
  - **`--report`:** Автоматический с 5-мин timeout, doctor-log отправляется как GitHub issue без подтверждения
- **Report sending (v2.3.0+):**
  1. `sanitize_doctor_report()` — HOME→`~`, PROJECT_DIR→`$PROJECT`, API keys/sk-*/Bearer→`[REDACTED]`
  2. `gh label create "doctor-report"` — idempotent создание label (v2.3.3)
  3. `gh issue create` — в `Puremag1c/hype` с label `doctor-report`, title из "## Reported Symptom"
- **Graceful degradation:** gh отсутствует / не авторизован / сеть недоступна → skip с логом, не crash

## Скрипты

| Скрипт | Назначение |
|--------|------------|
| `hype.sh` | Главный цикл с lock file |
| `detect-phase.sh` | Определение текущей фазы (1 bd call, всё через jq, JSON output) |
| `run-analysts.sh` | Параллельный запуск 5 Analysts |
| `run-executors.sh` | Параллельный запуск Executors с backpressure |
| `run-reviewers.sh` | Параллельный запуск Reviewers с backpressure (v2.2) |
| `run-merge-queue.sh` | Sequential merge approved задач (v2.2) |
| `run-testers.sh` | Параллельный запуск Testers (SMOKE_TEST) |
| `common.sh` | Общие функции (bd_safe, timeout, milestones, backoff, audit detection) |
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
- `in_progress` + `needs-review` — ждёт Reviewer (v2.2)
- `in_progress` + `reviewing` — Reviewer работает (v2.2)
- `in_progress` + `approved` — ждёт Merge Queue (v2.2)
- `closed` — завершено

### Labels

- `model:haiku/sonnet/opus` — какая модель выполняет
- `added-by:analyst-*` — кто добавил задачу
- `milestone:*` — маркер завершения фазы
- `retry:N` — счётчик timeout/failure при execution
- `reject:N` — счётчик отказов code review (escalation ladder: 1→retry, 2-3→escalate model, 4→troubleshooter). Только для quality rejections от Reviewer
- `merge-conflict:N` — (убран в v2.3.11). Заменён hybrid merge queue: fast script path + merger agent fallback. Нет больше 6-retry loop
- `regress:N` — счётчик regression cycles (script-driven)
- `smoke` — баг из SMOKE_TEST, ждёт тriage от Architect
- `regression` — баг который вернулся после fix
- `reformulated` — задача переформулирована Troubleshooter (макс 2 раза)
- `user-escalation` — требует решения пользователя (trigger USER_REVIEW)
- `reviewing` — Reviewer работает над этой задачей (v2.2)
- `approved` — задача одобрена, ждёт merge queue (v2.2)
- `reviewed` — задача замержена и закрыта (v2.2)
- `blocked:troubleshoot` — исчерпан escalation ladder, ждёт Troubleshooter
- `blocked:*` — прочие причины блокировки
- `trigger` — системная задача-координатор (run-analyst-*, run-tester-*, milestone:*). Исключена из executor/reviewer/merge/heal/reset. Автоматически закрывается после запуска агента
- `secrets-warning` — preflight нашёл credential-like patterns в diff. Reviewer решает: реальный секрет = REJECT, тестовые данные = proceed
- `last-reject:{TYPE}` — причина последнего reject для circuit breaker (cross-cycle detection, v2.2.1)

### Trigger Tasks

**Trigger tasks** — системные задачи для координации параллельных агентов. Создаются скриптами (`run-analysts.sh`, `run-testers.sh`), не пользователями.

- **Label:** `trigger`
- **Примеры:** `run-analyst-ux`, `run-tester-functional`, `milestone:analysts-done`
- **Lifecycle:** create → claim → agent runs → auto-close
- **Исключены из (v2.2.1):**
  - `get_ready_tasks()` — executors не берут trigger'ы
  - `get_review_tasks()` — reviewers не ревьюят trigger'ы
  - `get_approved_tasks()` — merge queue не мержит trigger'ы
  - `heal_stuck_tasks()` — healing не трогает trigger'ы
  - `reset_stale_tasks()` — stale reset не сбрасывает trigger'ы
  - P0 bug count в `detect-phase.sh` — trigger'ы не считаются багами
  - OPEN/IN_PROGRESS counts в `detect-phase.sh` (v2.2.5) — trigger'ы не блокируют фазовую машину

**Почему это важно:** До v2.2.1 trigger'ы могли попасть в review pipeline → получить `NO_BRANCH` error → считаться P0 багами → блокировать SMOKE_TEST бесконечно.

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

### bd_safe сериализация
- Все bd вызовы через `bd_safe()` обёртку
- Global lock через `mkdir /tmp/hype-bd.lock.d` (atomic)
- Предотвращает daemon explosion от параллельных bd вызовов

### Startup health check (v2.2.2)
- Проверяет наличие и executable права для всех критичных скриптов:
  - `detect-phase.sh`, `run-executors.sh`, `run-analysts.sh`, `run-reviewers.sh`, `run-merge-queue.sh`
- При отсутствии любого — fatal error, daemon не стартует
- Предотвращает silent failure: без проверки executors работали бы, но review pipeline молча бы не запустился

### Self-healing (heal_stuck_tasks)
- Запускается в каждой итерации main loop
- Находит `in_progress` задачи без `executor` и `needs-review` labels
- Если задача stuck >2 минут → автоматически добавляет `needs-review`
- Закрывает gap когда executor завершился но label не поставился (beads sync race)
- **v2.2:** Reviewing healing — задачи с `reviewing` >3 мин без reviewer lock → возврат в `needs-review`
- **v2.2.1:** Approved recovery — задачи с `approved` >5 мин → лог предупреждение; >10 мин → remove approved, increment reject:N, return to executor
- **Исключения:** trigger, reviewing (пока есть lock), approved (до 10 мин), user-escalation

### Startup cleanup (v2.2.5+)
- При старте HYPE удаляет stale PID файлы (`run-testers.pid`)
- Закрывает orphaned triggers от предыдущих сессий (все non-closed задачи с label `trigger`)
- Предотвращает: zombie trigger блокирует phase detection, stale PID file пропускает запуск тестеров

### Zombie daemon recovery (v2.1.7+, v2.3.1+)
- `check_beads()` использует `bd daemon status` (v2.3.1) — различает "daemon здоров" vs "bd работает через SQLite fallback"
- Recovery: 3x soft restart → `hard_kill_beads_daemon()`
- Hard kill: читает PID из `.beads/daemon.pid`, проверяет что это bd процесс, kill → kill -9 → rm stale files → fresh start
- Решает проблему когда daemon жив но socket потерян (feedback loop на большом JSONL)
- Профилактика: `flush-debounce: "15s"` в `.beads/config.yaml` (ставится при `hype init` / `hype start`)
- Все daemon start с `--log-level warn` для уменьшения лога

### Startup hardening (v2.3.1+)
- `ensure_single_daemon()` — при старте проверяет `pgrep -x bd`: >1 → killall + restart; 0 → start; 1 → ok
- `compact_beads_if_large()` — если `.beads/beads.db` > 10MB → `bd admin compact --purge-tombstones`
- `bd_safe` explosion threshold = 5 (было 30). ChatFilter имел 6 daemons — порог 30 бесполезен
- Milestones: `bd update --remove-label` вместо `bd delete` — без tombstones (v2.3.1)

### Adaptive backoff
- Если beads daemon отвечает >2s → удваивает iteration delay (max 60s)
- Предотвращает overload spiral: медленный daemon → больше запросов → ещё медленнее
- При recovery → сброс к базовому `ITERATION_DELAY`
- Функция `calculate_backoff_delay()` в common.sh

### Retry & escalation logic
- Execution failures: `retry:N` (timeout, crash)
- Review rejections: `reject:N` — только code quality отказы от Reviewer
- Merge conflicts (v2.3.11): fast script merge → agent fallback → executor. Нет counter loop — один умный attempt агентом вместо 6 слепых retry
- Escalation ladder (reject:N): 1→retry, 2-3→escalate model (haiku→sonnet→opus), 4→Troubleshooter
- Troubleshooter: reformulate / split / remove / escalate to user
- Max 2 reformulations (label `reformulated`), then only reduce/remove/user

### Needs-review retry
- При завершении executor — 3 попытки с 2s delay для `--add-label=needs-review`
- Если все 3 fail → логирует ERROR, self-healing подхватит через 2 минуты

### Graceful shutdown
- `trap SIGINT SIGTERM`
- Reset stale tasks (>5min in_progress)
- Cleanup lock file

### Config validation
- Проверка при каждой итерации (hot reload)
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
4. Push с `--force-with-lease`, добавляет `needs-review`
5. Reviewer проверяет diff (parallel, v2.2) → approve / reject
6. Merge Queue мержит approved задачи (sequential, v2.2)

## Backpressure

- Лимит = `MAX_PARALLEL_EXECUTORS`
- Считаем через lock files в `.hype-worktrees/executor-N.lock` (не beads labels — labels ненадёжны из-за sync lag)
- Lock создаётся при `find_free_slot()` (mkdir atomic), удаляется при `cleanup_worktree()`
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
