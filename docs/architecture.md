# Hype Architecture

Многоагентная AI-система автоматической разработки на базе Claude Code.

## Обзор

```
hype.sh (bash loop с lock file)
    │
    ├─► detect-phase.sh → определяет текущую фазу (JSON output)
    │
    ├─► НАПРЯМУЮ вызывает по фазе:
    │   ├─► PREPARING: Manager (Opus, interactive)
    │   ├─► PLANNING: Architect (Opus)
    │   ├─► ANALYZE: run-analysts.sh → Analysts (Sonnet × 5)
    │   ├─► THINKING: Plan-Reviewer (Opus)
    │   ├─► CODING: run-coders.sh + run-seniors.sh + run-merge-queue.sh
    │   ├─► TESTING: run-testers.sh (background) → Testers × 6
    │   ├─► REFLEXING: QA (Opus)
    │   ├─► CONSULTATION: Manager-Review (Sonnet) → hype stops
    │   ├─► VALIDATING: QA (Opus)
    │   ├─► REPORTING: Completion (Opus)
    │   └─► BLOCKED_CYCLES: Ops (Sonnet)
    │
    ├─► Troubleshooter (Opus) — при blocked:troubleshoot (reject:4+)
    │
    └─► Manager (Sonnet) — при прочих blocked/retry-limit
```

**Ключевой принцип:** Bash вызывает bash (механика). LLM используется только для решений.

## Фазы проекта

```
PREPARING → PLANNING → ANALYZE → THINKING → CODING → TESTING → VALIDATING → REPORTING → DONE
                                              ↑                  ↓
                                              └── REFLEXING ←─┘ (smoke/regression tasks)
                                         CONSULTATION ← (user-escalation label → hype stops)
```

| Фаза | Условие перехода | Агент | Действие |
|------|-----------------|-------|----------|
| PREPARING | Нет SPEC.md | Manager | Собирает требования от user (+ deep analysis для больших проектов) |
| PLANNING | Есть SPEC.md | Architect | Создаёт задачи в beads |
| ANALYZE | milestone:planning-done | Analysts ×5 | Параллельный аудит плана |
| THINKING | milestone:analysts-done | Plan-Reviewer | Ревьюит добавления Analysts |
| CODING | milestone:plan-reviewed | Coders + Auditor | Реализуют задачи + аудит |
| TESTING | все задачи closed | Testers ×6 | Параллельная проверка работоспособности |
| REFLEXING | smoke/regression tasks найдены | QA | Триаж всех smoke test находок |
| CONSULTATION | user-escalation label | Manager-Review | Генерирует отчёт, hype stops |
| VALIDATING | milestone:testing-done | QA | Проверяет целостность |
| REPORTING | milestone:validating-done | Completion (Opus) | Version bump + CHANGELOG + SPEC_REPORT + commit + push |
| DONE | milestone:project-done | — | Проект завершён |

## Агенты

### Manager (Sonnet)
- **Роль:** Problem Advisor (советник для проблем)
- **Вызывается:** ТОЛЬКО при наличии blocked tasks или retry limit
- **Задача:** Анализировать проблемы, давать рекомендации
- **Не делает:** НЕ координирует фазы, НЕ запускает скрипты

### Manager (Opus)
- **Роль:** Сбор требований
- **Задача:** Через диалог с user создать SPEC.md
- **Особенности:** Интерактивный режим, без timeout

### Architect (4 специализированных агента)

**Декомпозирован в v1.9.19** — один большой architect.md разбит на 4 фокусных агента:

| Агент | Model | Задача |
|-------|-------|--------|
| architect | opus | Создание плана из SPEC.md, разбивка на задачи, deps |
| plan-reviewer | opus | Ревью добавлений от Analysts + audit findings (audit_review mode) |
| qa | opus | Final review, обработка regression bugs |
| ops | sonnet | Разрешение git conflicts, dependency cycles |

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

### Coder (по задаче)
- **Роль:** Реализация одной задачи
- **Модель:** Из label задачи (model:haiku/sonnet/opus)
- **Workflow:**
  1. Claim задачу через `bd update --claim`
  2. Работает в ветке `task/beads-{id}`
  3. Rebase на main
  4. Push и пометить `needs-review`

### Senior (v2.2, parallel)
- **Роль:** Code review (без merge)
- **Модель:** sonnet по умолчанию, opus при reject:2+ или reject:4
- **Управление:** `run-seniors.sh`, до `MAX_PARALLEL_SENIORS` параллельно
- **Workflow:**
  1. Atomic claim: `try_claim_for_review()` (mkdir lock + label)
  2. Preflight: проверка ветки, коммитов, secret scanning (v2.2.1)
  3. Build context: diff, commits, coder log, secrets warning
  4. Claude review с `senior.md` промптом
  5. Результат: approve (label) / reject (status=open) / no-merge (close)
- **Audit review (v2.5.9):** AUDIT_REVIEW preflight → вызывает plan-reviewer с `MODE=audit_review` (sonnet). Plan-reviewer читает findings из notes, решает: `bd close` если ок, `bd create` fix-задачи если проблемы. При timeout — задача возвращается в `needs-review`
- **Preflight checks (v2.2.1):**
  - Проверка что ветка существует (`NO_BRANCH` → reject)
  - Проверка что есть коммиты (`NO_COMMITS` → reject)
  - Secret scanning: grep по diff на API keys, passwords, secrets, .env → `SECRETS_WARNING` + label `secrets-warning` → senior решает (soft, не hard reject)
  - Circuit breaker: если reformulated задача ломается по той же причине (`last-reject:{TYPE}` label) → `user-escalation`
- **Timeout handling (v2.2.2):** Если Claude таймаутится (exit 124) — задача возвращается в `needs-review` БЕЗ инкремента `reject:N`. Timeout = инфраструктурная проблема, не отказ
- **Backpressure:** Lock-based (`senior-N.lock`), stale cleanup >20 min
- **Escalation:** reject:1→retry, reject:2-3→model, reject:4→troubleshooter

### Merge Queue (v2.2 → v2.3.11, hybrid)
- **Роль:** Squash merge approved задач в main
- **Управление:** `run-merge-queue.sh`, одна задача за вызов (sequential, safe)
- **Hybrid workflow (v2.3.11):**
  1. **Fast path** (`try_fast_merge`): rebase → squash → commit → push. Бесплатно, ~5 сек
  2. **Agent fallback** (`run_merger_agent`): если fast path fails — запускает Claude merger agent (opus) с контекстом конфликта. Агент понимает diff, разрешает конфликты, мержит
  3. **Coder fallback**: если и агент не справился — задача возвращается coder с подробными notes
  4. **Empty merge detection**: между fast path и agent — проверка diff. Если branch changes уже в main → close без agent call
- **Hook isolation (v2.3.4):** Все git операции через `git_nh()` (`core.hooksPath=/dev/null`). Target project hooks вызывают `bd` напрямую — под нагрузкой создают lock contention
- **Pre-flight check (v2.3.4):** Проверка `git status --porcelain` перед merge. Dirty tree → reset --hard
- **Merger agent (`merger.md`, v2.3.11):** Получает branch diff, conflict info, error context. Использует `git -c core.hooksPath=/dev/null`. Закрывает задачу через `bd close` при успехе
- **Audit tasks:** Close without merge

### Auditor (Sonnet → Opus)
- **Роль:** Аудит задач с label `audit`
- **Когда:** Задачи с "AUDIT SCOPE" в description или label `audit`
- **Выход:** Findings в notes задачи, не код
- **Review (v2.5.9):** После завершения Senior маршрутизирует на plan-reviewer (`MODE=audit_review`), который читает findings и создаёт fix-задачи при необходимости. До v2.5.9 findings авто-одобрялись и никем не читались
- **Эскалация:** sonnet → opus при timeout/failure

### Versioner (Haiku)
- **Роль:** Обновление VERSION и CHANGELOG после VALIDATING
- **Когда:** После успешного VALIDATING: PASSED
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
  - ESCALATE TO USER — label `user-escalation`, hype stops

### Manager Review (Sonnet)
- **Роль:** Генерация non-technical отчёта для пользователя
- **Когда:** Фаза CONSULTATION (задачи с `user-escalation` label)
- **Выход:** `.hype/evidence/user-review-report.md`

### Testers (TESTING фаза)
- **Роль:** Проверка работоспособности после CODING
- **Виды (6 штук):**
  - `tester-functional` (sonnet) — Must Have из SPEC.md (все проекты)
  - `tester-backend` (sonnet) — Запуск существующих тестов + генерация новых (все проекты)
  - `tester-visual` (opus) — UI через Playwright MCP (web)
  - `tester-api` (haiku) — Endpoints, статус коды (api, web)
  - `tester-cli` (haiku) — Команды, --help (cli)
  - `tester-regression` (sonnet) — Тестовый suite (library)
- **Sequential:** functional + visual запускаются последовательно (Playwright MCP conflicts)
- **Async (v2.2.6):** `run-testers.sh` запускается в background с PID tracking. HYPE продолжает тикать (check_beads, heal каждый цикл). Три состояния: running (PID alive → wait), never launched (no PID file → start), finished/crashed (PID dead → check results or re-launch orphans)
- **Hard gate:** P0 bugs блокируют milestone:testing-done → возврат в CODING

### Doctor (Opus)
- **Роль:** Диагностика проблем HYPE, формирование doctor-log
- **Вызывается:** `hype doctor` (интерактивно) или `hype doctor --report` (автоматически)
- **Pre-flight:** `check_beads()` проверяет backend через `bd list --limit 1` (v2.5). Без ответа — Doctor работает с ограниченными данными
- **Workflow:**
  1. `gather_context()` — 11 категорий: HYPE version, beads status, in-progress tasks, blocked tasks, current phase, running processes, git status, HYPE markers, coder worktrees, review pipeline (v2.2), recent logs
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
| `run-coders.sh` | Параллельный запуск Coders с backpressure |
| `run-seniors.sh` | Параллельный запуск Seniors с backpressure (v2.2) |
| `run-merge-queue.sh` | Sequential merge approved задач (v2.2) |
| `run-testers.sh` | Параллельный запуск Testers (TESTING) |
| `common.sh` | Общие функции (bd_safe, timeout, milestones, backoff, audit detection) |
| `log.sh` | Хелпер для логирования |
| `notify.sh` | Уведомления (macOS, Linux, WSL) |
| `analyze-project.sh` | Анализ структуры проекта |
| `deep-analyze.sh` | Глубокий анализ через Claude (PREPARING) |
| `close-completed-parents.sh` | Автозакрытие parent tasks |

## Конфигурация

### `.hype/config.sh`

```bash
MAX_PARALLEL_CODERS=3    # Лимит параллельных Coders
RETRY_LIMIT=3               # Retry до эскалации к Architect
TASK_TIMEOUT="10m"          # Таймаут на задачу
WORKTREE_STALE_TIMEOUT=900  # Секунды до удаления stale worktree
TASK_STALE_TIMEOUT=600      # Секунды до сброса stale task
ALLOWED_MODELS="opus,sonnet,haiku"  # Разрешённые модели
```

### `.hype/testing.yaml` (TESTING)

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

### Архитектура Beads (v0.55+ Dolt)

**Beads v0.55+ использует встроенный Dolt (embedded). Daemon удалён в v0.50, sync — no-op в v0.51.**

```
┌─────────────────────────────────────────────────────────┐
│                      bd CLI                             │
│  (bd list, bd update, bd create, bd query, etc.)        │
└─────────────────┬───────────────────────────────────────┘
                  │ Direct (embedded)
                  ▼
┌─────────────────────────────────────────────────────────┐
│              .beads/*.db (Dolt embedded)                 │
│  - Auto-commit after write operations                   │
│  - SQL access via bd sql / bd query                     │
│  - Native git-like versioning (bd diff, bd history)     │
│  - bd set-state for atomic label transitions            │
└─────────────────────────────────────────────────────────┘
```

### Правила работы с Beads

**1. Прямой доступ через bd CLI**
```bash
bd list --json --limit 0         # Все open/in_progress задачи
bd query "status=open AND label=coder" --json --limit 0  # Server-side фильтр
bd count --status=open           # Нативный подсчёт
bd set-state $id model=opus      # Атомарная смена label
```

**2. Worktrees используют auto-discovery**
```
main-repo/.beads/*.db     ← единственная база
worktree/                 ← bd auto-discovers из parent
```

**Worktree build artifacts (v2.5.11):**
`create_worktree()` calls `setup_worktree_links()` after `git worktree add`. Symlinks build artifact directories (`deps`, `_build`, `node_modules`, `.venv`, `venv`, `vendor`, `target`) from project root into worktree if they exist. This allows coders to compile/test without re-downloading dependencies. Cleanup via `git worktree remove --force` or `rm -rf` handles symlinks correctly — no special unlink needed.

**3. bd_safe сериализация (HYPE-specific)**
- Все bd вызовы через `bd_safe()` обёртку в common.sh
- Global lock через `mkdir /tmp/hype-bd.lock.d` (atomic)
- Auto-retry для write операций (update, close, create, set-state)
- Health probe: `bd list --limit 1` (вместо daemon status)

**4. Типичные ошибки**

| Симптом | Причина | Решение |
|---------|---------|---------|
| `database is locked` | Stale lock file | `rmdir /tmp/hype-bd.lock.d` |
| bd command timeout | Dolt embedded slow | `bd doctor`, restart HYPE |
| Stale data | Lock bypass | Use `bd_safe`, not bare `bd` |

**5. Восстановление после проблем**
```bash
# 1. Проверить состояние
bd doctor

# 2. Если lock застрял
rmdir /tmp/hype-bd.lock.d 2>/dev/null

# 3. Если база повреждена
bd admin cleanup --force
```

### Статусы задач

- `open` — задача создана, ждёт исполнителя
- `in_progress` — Coder работает
- `in_progress` + `needs-review` — ждёт Senior (v2.2)
- `in_progress` + `reviewing` — Senior работает (v2.2)
- `in_progress` + `approved` — ждёт Merge Queue (v2.2)
- `closed` — завершено

### Labels

- `model:haiku/sonnet/opus` — какая модель выполняет
- `added-by:analyst-*` — кто добавил задачу
- `milestone:*` — маркер завершения фазы
- `retry:N` — счётчик timeout/failure при execution
- `reject:N` — счётчик отказов code review (escalation ladder: 1→retry, 2-3→escalate model, 4→troubleshooter). Только для quality rejections от Senior
- `merge-conflict:N` — (убран в v2.3.11). Заменён hybrid merge queue: fast script path + merger agent fallback. Нет больше 6-retry loop
- `regress:N` — счётчик regression cycles (script-driven)
- `smoke` — баг из TESTING, ждёт тriage от Architect
- `regression` — баг который вернулся после fix
- `reformulated` — задача переформулирована Troubleshooter (макс 2 раза)
- `user-escalation` — требует решения пользователя (trigger CONSULTATION)
- `reviewing` — Senior работает над этой задачей (v2.2)
- `approved` — задача одобрена, ждёт merge queue (v2.2)
- `reviewed` — задача замержена и закрыта (v2.2)
- `blocked:troubleshoot` — исчерпан escalation ladder, ждёт Troubleshooter
- `blocked:*` — прочие причины блокировки
- `trigger` — системная задача-координатор (run-analyst-*, run-tester-*, milestone:*). Исключена из coder/senior/merge/heal/reset. Автоматически закрывается после запуска агента
- `secrets-warning` — preflight нашёл credential-like patterns в diff. Senior решает: реальный секрет = REJECT, тестовые данные = proceed
- `last-reject:{TYPE}` — причина последнего reject для circuit breaker (cross-cycle detection, v2.2.1)

### Trigger Tasks

**Trigger tasks** — системные задачи для координации параллельных агентов. Создаются скриптами (`run-analysts.sh`, `run-testers.sh`), не пользователями.

- **Label:** `trigger`
- **Примеры:** `run-analyst-ux`, `run-tester-functional`, `milestone:analysts-done`
- **Lifecycle:** create → claim → agent runs → auto-close
- **Исключены из (v2.2.1):**
  - `get_ready_tasks()` — coders не берут trigger'ы
  - `get_review_tasks()` — seniors не ревьюят trigger'ы
  - `get_approved_tasks()` — merge queue не мержит trigger'ы
  - `heal_stuck_tasks()` — healing не трогает trigger'ы
  - `reset_stale_tasks()` — stale reset не сбрасывает trigger'ы
  - P0 bug count в `detect-phase.sh` — trigger'ы не считаются багами
  - OPEN/IN_PROGRESS counts в `detect-phase.sh` (v2.2.5) — trigger'ы не блокируют фазовую машину

**Почему это важно:** До v2.2.1 trigger'ы могли попасть в review pipeline → получить `NO_BRANCH` error → считаться P0 багами → блокировать TESTING бесконечно.

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
- Auto-retry для write ops (update, close, create, set-state)
- Health probe: `bd list --limit 1` перед retry

### Startup health check (v2.2.2)
- Проверяет наличие и executable права для всех критичных скриптов:
  - `detect-phase.sh`, `run-coders.sh`, `run-analysts.sh`, `run-seniors.sh`, `run-merge-queue.sh`
- При отсутствии любого — fatal error, HYPE не стартует
- Предотвращает silent failure: без проверки coders работали бы, но review pipeline молча бы не запустился

### Self-healing (heal_stuck_tasks)
- Запускается в каждой итерации main loop
- Находит `in_progress` задачи без `coder` и `needs-review` labels
- Если задача stuck >2 минут → автоматически добавляет `needs-review`
- Закрывает gap когда coder завершился но label не поставился (beads sync race)
- **v2.2:** Reviewing healing — задачи с `reviewing` >3 мин без senior lock → возврат в `needs-review`
- **v2.2.1:** Approved recovery — задачи с `approved` >5 мин → лог предупреждение; >10 мин → remove approved, increment reject:N, return to coder
- **Исключения:** trigger, reviewing (пока есть lock), approved (до 10 мин), user-escalation

### Startup cleanup (v2.2.5+)
- При старте HYPE удаляет stale PID файлы (`run-testers.pid`)
- Закрывает orphaned triggers от предыдущих сессий (все non-closed задачи с label `trigger`)
- Предотвращает: zombie trigger блокирует phase detection, stale PID file пропускает запуск тестеров

### Backend health check (v2.5+)
- `check_beads()` использует `bd list --limit 1` probe — 3 попытки с 2s pause
- Dolt embedded — нет отдельного процесса, нет PID tracking
- `compact_beads_if_large()` — если `.beads/*.db` > 10MB → `bd admin compact --purge-tombstones`

### Adaptive backoff
- Если bd backend отвечает >2s → удваивает iteration delay (max 60s)
- Предотвращает overload spiral: медленный backend → больше запросов → ещё медленнее
- При recovery → сброс к базовому `ITERATION_DELAY`
- Функция `calculate_backoff_delay()` в common.sh

### Retry & escalation logic
- Execution failures: `retry:N` (timeout, crash)
- Review rejections: `reject:N` — только code quality отказы от Senior
- Merge conflicts (v2.3.11): fast script merge → agent fallback → coder. Нет counter loop — один умный attempt агентом вместо 6 слепых retry
- Escalation ladder (reject:N): 1→retry, 2-3→escalate model (haiku→sonnet→opus), 4→Troubleshooter
- Troubleshooter: reformulate / split / remove / escalate to user
- Max 2 reformulations (label `reformulated`), then only reduce/remove/user

### Needs-review retry
- При завершении coder — 3 попытки с 2s delay для `--add-label=needs-review`
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
  ├── task/beads-abc  ← Coder 1
  ├── task/beads-def  ← Coder 2
  └── task/beads-ghi  ← Coder 3
```

1. Coder создаёт ветку от main
2. Работает, коммитит
3. Rebase на main (при конфликте — эскалация)
4. Push с `--force-with-lease`, добавляет `needs-review`
5. Senior проверяет diff (parallel, v2.2) → approve / reject
6. Merge Queue мержит approved задачи (sequential, v2.2)

## Backpressure

- Лимит = `MAX_PARALLEL_CODERS`
- Считаем через lock files в `.hype-worktrees/coder-N.lock` (не beads labels — labels ненадёжны из-за sync lag)
- Lock создаётся при `find_free_slot()` (mkdir atomic), удаляется при `cleanup_worktree()`
- Работает без GitHub

## Логирование

Формат: `YYYY-MM-DD HH:MM:SS [AGENT] EVENT: message`

```bash
./scripts/log.sh MANAGER INFO "Starting phase detection"
./scripts/log.sh EXECUTOR TASK_START "hype-abc"
./scripts/log.sh ORCHESTRATOR FATAL "Beads backend not responding"
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
