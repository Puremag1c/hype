# HYPE Troubleshooting

Справочник проблем для Doctor-агента. Формат оптимизирован для LLM-поиска.

---

## Beads проблемы

### PROBLEM: Beads daemon frozen

**Симптомы:**
- Команды `bd` зависают на 30+ секунд
- `bd sync --status` не отвечает (или отвечает через SQLite fallback — ложный "ок")
- В логах: timeout на bd операциях

**Причина:**
Daemon завис или SQLite lock не освободился.

**Диагностика:**
```bash
bd daemon status                # v2.3.1+: проверяет daemon напрямую. "running" = здоров
timeout 5s bd sync --status     # ВНИМАНИЕ: может работать через SQLite fallback с мёртвым daemon!
pgrep -f "bd daemon"
ls -la .beads/daemon.*
```

**Решение (runtime-fix):**
```bash
bd daemon restart .
```

**Решение (если restart не помогает):**
```bash
pkill -9 -f "bd daemon"
rm -f .beads/daemon.*
bd daemon start
```

**Auto-recovery (v2.3.1+):**
`check_beads()` в hype.sh использует `bd daemon status` (не `bd sync --status` который имеет SQLite fallback). 3 попытки soft restart → hard kill по PID из `.beads/daemon.pid` → очистка stale файлов → fresh start.

---

### PROBLEM: Beads daemon zombie (alive but socket gone)

**Симптомы:**
- `bd list` показывает "Daemon took too long to start (>5s). Running in direct mode."
- `bd daemon restart` не помогает (лог: "daemon already running (lock held), exiting")
- `ps aux | grep bd` показывает живой процесс
- `.beads/daemon.sock` отсутствует

**Причина:**
Daemon вошёл в feedback loop: import→export→file-change→import. При большом JSONL (много задач/tombstones) loop ускоряется, daemon перегружается, socket теряется. Процесс живой, lock держит, но команды не принимает.

**Диагностика:**
```bash
ls -la .beads/daemon.sock    # отсутствует
cat .beads/daemon.pid        # PID жив
kill -0 $(cat .beads/daemon.pid) && echo "zombie"
```

**Решение (ручное):**
```bash
kill $(cat .beads/daemon.pid)
rm -f .beads/daemon.lock .beads/daemon.pid
bd daemon start --log-level warn
```

**Auto-recovery (v2.3.1+):**
`check_beads()` использует `bd daemon status` (различает живой daemon от SQLite fallback) → `hard_kill_beads_daemon()` автоматически: читает PID, проверяет что это bd процесс, kill, cleanup, restart. Также `flush-debounce: "15s"` в config.yaml предотвращает feedback loop. При старте `ensure_single_daemon()` убивает лишние процессы.

---

### PROBLEM: Beads daemon explosion (270+ processes)

**Симптомы:**
- `pgrep -c bd` показывает 100+ процессов
- Система тормозит
- Логи: много "socket busy" или connection errors

**Причина:**
Параллельные bd вызовы перегружают socket daemon'а. Каждый считает что daemon мёртв и спавнит новый.

**Диагностика:**
```bash
pgrep -c bd
ps aux | grep "bd daemon" | wc -l
```

**Решение (runtime-fix):**
```bash
# Убить все bd процессы
pkill -9 bd
rm -f .beads/daemon.*
bd daemon start
```

**Решение (permanent):**
HYPE 2.0.14+ использует `bd_safe()` с сериализацией через mkdir-lock. Все bd вызовы выполняются последовательно. Порог explosion detection снижен с 30 до 5 (v2.3.1). При старте `ensure_single_daemon()` проверяет и убивает лишние bd процессы.

---

### PROBLEM: Phase UNKNOWN на macOS

**Симптомы:**
- detect-phase.sh возвращает `{"phase":"UNKNOWN",...}`
- Только на macOS
- После upgrade HYPE

**Причина:**
1. `flock` команда отсутствует на macOS
2. Perl fallback не работает (exit 255)
3. bd_safe не может выполнить команду

**Диагностика:**
```bash
which flock  # Should be empty on macOS
./scripts/detect-phase.sh 2>&1
# Check for exit 255 or "command not found"
```

**Решение:**
Обновиться до HYPE 2.0.15+ который использует mkdir-based locking вместо flock.
```bash
cd ~/.hype && git pull
hype upgrade --force
```

---

### PROBLEM: Stuck in_progress task

**Симптомы:**
- Задача в `in_progress` > 10 минут
- Executor для этой задачи не работает (нет процесса, лог не растёт)
- `bd list --status=in_progress` показывает старые задачи

**Причина:**
Executor упал/timeout без cleanup.

**Диагностика:**
```bash
bd list --status=in_progress --json | jq '.[] | {id, title, updated_at}'
# Проверить возраст updated_at
```

**Решение (runtime-fix):**
```bash
bd update <id> --status=open --remove-label=executor
```

**Note:** HYPE автоматически сбрасывает stale tasks через `check_stale_tasks()` (default 10 min). Дополнительно, `heal_stuck_tasks()` (2.1.4+) добавляет `needs-review` к tasks stuck >2 min без executor/needs-review labels.

---

### PROBLEM: Orphaned needs-review label

**Симптомы:**
- Closed задача с `needs-review` label
- Senior Executor не видит задачу (она closed)

**Причина:**
Задача была закрыта вручную или race condition.

**Диагностика:**
```bash
bd list --status=closed --json | jq '.[] | select(.labels | index("needs-review"))'
```

**Решение (runtime-fix):**
```bash
bd update <id> --remove-label=needs-review
```

---

### PROBLEM: Dependency cycle

**Симптомы:**
- Фаза `BLOCKED_CYCLES`
- `bd dep cycles` показывает циклы
- HYPE не переходит в IMPLEMENTATION

**Причина:**
Architect создал circular dependencies.

**Диагностика:**
```bash
bd dep cycles
```

**Решение (runtime-fix):**
```bash
bd dep remove <task-id> <depends-on-id>
# Для каждого цикла — разорвать одну зависимость
```

---

### PROBLEM: Race condition - task disappeared

**Симптомы:**
- "No such issue" после `bd list` показал задачу
- Задача была видна, потом исчезла

**Причина:**
Другой процесс (executor, senior) закрыл задачу между list и show.

**Диагностика:**
```bash
bd list --all --json | jq '.[] | select(.id == "<id>")'
```

**Решение:**
Это нормальное поведение. Retry операции.

---

### PROBLEM: Labels stuck (не применяются)

**Симптомы:**
- `bd update --label=X` выполняется, но label не появляется
- `bd show` не показывает добавленный label

**Причина:**
Daemon cache не синхронизирован.

**Диагностика:**
```bash
bd sync --force
bd show <id> --json | jq '.[0].labels'
```

**Решение (runtime-fix):**
```bash
bd sync --force
```

---

## Git проблемы

### PROBLEM: Orphaned worktree

**Симптомы:**
- `.hype-worktrees/executor-N` существует
- Executor не работает (нет процесса)
- `git worktree list` показывает orphaned worktree

**Причина:**
Executor crash или timeout без cleanup.

**Диагностика:**
```bash
ls -la .hype-worktrees/
git worktree list
pgrep -f executor
```

**Решение (runtime-fix):**
```bash
git worktree remove --force .hype-worktrees/executor-N
git worktree prune
```

**Note:** HYPE автоматически чистит stale worktrees через `cleanup_stale_worktrees()` (default 15 min).

---

### PROBLEM: index.lock stuck

**Симптомы:**
- "fatal: Unable to create '.git/index.lock': File exists"
- Git операции не работают

**Причина:**
Git процесс убит во время операции.

**Диагностика:**
```bash
ls -la .git/*.lock
pgrep -f git
```

**Решение (runtime-fix):**
```bash
# ТОЛЬКО если git процесс мёртв!
rm .git/index.lock
```

---

### PROBLEM: Merge stuck in progress

**Симптомы:**
- "You have unmerged paths"
- `.git/MERGE_HEAD` существует
- Git операции блокированы

**Причина:**
Crash во время merge.

**Диагностика:**
```bash
git status
ls .git/MERGE_HEAD
```

**Решение (runtime-fix):**
```bash
git merge --abort
```

---

### PROBLEM: Uncommitted changes block operations

**Симптомы:**
- "Your local changes would be overwritten"
- Executor не может работать

**Причина:**
Предыдущий executor не сделал commit перед exit.

**Диагностика:**
```bash
git status
git diff --stat
```

**Решение (runtime-fix):**
```bash
git stash
# Потом разобраться что в stash
```

---

### PROBLEM: Branch already exists

**Симптомы:**
- "fatal: A branch named 'task/beads-xxx' already exists"

**Причина:**
Retry после partial failure.

**Диагностика:**
```bash
git branch -a | grep task/
```

**Решение (runtime-fix):**
```bash
# ТОЛЬКО если ветка точно не нужна
git branch -D task/beads-xxx
```

---

## HYPE process проблемы

### PROBLEM: hype.lock stuck

**Симптомы:**
- "HYPE already running (PID N)" но процесса нет
- `ps aux | grep N` не находит процесс

**Причина:**
HYPE упал без cleanup (SIGKILL, crash).

**Диагностика:**
```bash
cat .hype/hype.lock
ps aux | grep $(cat .hype/hype.lock)
```

**Решение (runtime-fix):**
```bash
rm .hype/hype.lock
```

---

### PROBLEM: Phase stuck on INIT

**Симптомы:**
- INIT повторяется хотя SPEC.md существует
- detect-phase.sh возвращает INIT

**Причина:**
Маркер `.hype/needs-spec` застрял.

**Диагностика:**
```bash
ls -la .hype/needs-spec
cat SPEC.md | head -5
```

**Решение (runtime-fix):**
```bash
rm .hype/needs-spec
```

---

### PROBLEM: SMOKE_REVIEW loop

**Симптомы:**
- Фаза SMOKE_REVIEW повторяется бесконечно
- regression label не снимается

**Причина:**
Architect не убрал regression label после обработки.

**Диагностика:**
```bash
bd list --status=open --json | jq '.[] | select(.labels | index("regression"))'
```

**Решение (runtime-fix):**
```bash
bd update <id> --remove-label=regression
```

---

### PROBLEM: Zombie executors

**Симптомы:**
- Много процессов `claude` висят
- Memory/CPU высокий
- Задачи не продвигаются

**Причина:**
Executors не завершились корректно.

**Диагностика:**
```bash
pgrep -f claude
pgrep -f executor
ps aux | grep claude
```

**Решение (runtime-fix):**
```bash
# Осторожно — убьёт все claude процессы
pkill -f "claude.*executor"
```

---

### PROBLEM: Too many parallel executors

**Симптомы:**
- Больше `MAX_PARALLEL_EXECUTORS` процессов
- Rate limits от API
- Slow performance

**Причина:**
Backpressure не сработал.

**Диагностика:**
```bash
pgrep -c -f executor
cat .hype/config.sh | grep MAX_PARALLEL
```

**Решение:**
Подождать пока текущие executors завершатся. HYPE контролирует через backpressure.

---

### PROBLEM: All executor slots always free (backpressure 0)

**Fixed in:** 2.1.5

**Симптомы:**
- Backpressure log показывает "0/N active" при работающих executors
- Больше параллельных executors чем MAX_PARALLEL_EXECUTORS
- Daemon перегружен от бесконечного claim loop

**Причина:**
`count_active_executors()` считала по beads label `executor`, но labels ненадёжны из-за sync lag и race conditions. Tasks были in_progress без label → backpressure всегда 0 → бесконечный claim.

**Решение:**
Обновиться до 2.1.5+. `count_active_executors()` теперь считает по lock files (`executor-N.lock` в `.hype-worktrees/`), которые точно отражают время жизни executor.

---

### PROBLEM: Executor slots exhausted (.hype-worktrees missing)

**Fixed in:** 2.1.4

**Симптомы:**
- Ни один executor не запускается
- В логах: "No free slots"
- `.hype-worktrees/` директории не существует

**Причина:**
`find_free_slot()` использовала `mkdir` без `-p` для создания lock files внутри `.hype-worktrees/`. Если parent директория не существует, все 20 слотов fail silently.

**Решение:**
Обновиться до 2.1.4+. `find_free_slot()` теперь создаёт parent директорию через `mkdir -p`.

---

### PROBLEM: Needs-review label lost after executor completion

**Fixed in:** 2.1.4

**Симптомы:**
- Задача в `in_progress` без `executor` и без `needs-review` labels
- Senior executor не видит завершённую задачу
- Задача "зависает" без обработки

**Причина:**
Когда несколько executors завершались одновременно во время beads sync (git fetch), `bd_safe update --add-label=needs-review` silently failed через `|| true`.

**Решение:**
Обновиться до 2.1.4+. Completion path теперь retry 3 раза с 2s delay. Плюс self-healing в main loop: `heal_stuck_tasks()` автоматически добавляет `needs-review` к задачам stuck >2 минут без executor/needs-review labels.

---

### PROBLEM: Executor lock leak on early return

**Fixed in:** 2.1.4

**Симптомы:**
- Слоты executor'ов заканчиваются со временем
- Lock файлы остаются в `.hype-worktrees/` без процесса
- `ls .hype-worktrees/*.lock` показывает orphaned locks

**Причина:**
`run_executor()` имел два early return (task not open, claim failed) без вызова `cleanup_worktree`. Locks накапливались через циклы HYPE.

**Решение:**
Обновиться до 2.1.4+. Все exit paths теперь вызывают `cleanup_worktree`.

---

### PROBLEM: NO_MERGE decision not detected (infinite reopen loop)

**Fixed in:** 2.1.2

**Симптомы:**
- Задача с "No Merge" решением от senior executor переоткрывается снова и снова
- Бесконечный цикл: executor → senior → "No Merge" → reopen → executor
- Задача не закрывается

**Причина:**
`bd close --reason` записывает в поле `close_reason`, не в `notes`. Senior executor проверял только `notes`, не видел "No Merge" решение, и переоткрывал задачу.

**Решение:**
Обновиться до 2.1.2+. Senior executor теперь проверяет оба поля: `notes` и `close_reason`.

---

### PROBLEM: Reject counter not incremented on reopen (20+ retries)

**Fixed in:** 2.1.2

**Симптомы:**
- Задача циклит 20+ раз без эскалации к troubleshooter
- `reject:N` label не растёт
- Задача переоткрывается через "closed but main unchanged" path

**Причина:**
Reopen path "closed but main unchanged" был единственным code path без инкремента `reject:N`. Задача никогда не достигала reject:4 для эскалации.

**Решение:**
Обновиться до 2.1.2+. Reopen path теперь инкрементирует `reject:N` и эскалирует на troubleshooter при reject:4.

---

### PROBLEM: Daemon overload from claim loop

**Fixed in:** 2.1.5

**Симптомы:**
- Beads daemon медленный (>5s на запрос)
- CPU высокий от bd процессов
- В логах: много rapid-fire bd calls

**Причина:**
Cascading failure: backpressure bug (always 0) → infinite claim loop → daemon перегружен → slow responses → timeout/retry → ещё больше нагрузки.

**Решение:**
Обновиться до 2.1.5+. Root cause (backpressure) исправлен. Дополнительно: adaptive backoff удваивает iteration delay при slow daemon (>2s), cap 60s. detect-phase.sh оптимизирован с 2 bd calls до 1.

---

## Claude CLI проблемы

### PROBLEM: Agent file not found

**Симптомы:**
- "Agent file not found: .claude/agents/xxx.md"
- HYPE падает при запуске фазы

**Причина:**
1. Symlinks устарели после upgrade
2. Agent был переименован (например architect.md → architect-*.md)
3. `.claude/agents` — директория вместо symlink

**Диагностика:**
```bash
ls -la .claude/agents/
ls ~/.hype/core/agents/
file .claude/agents  # Should show "symbolic link"
```

**Решение (runtime-fix):**
```bash
hype upgrade --force
```

Если не помогает:
```bash
rm -rf .claude/agents
ln -sf ~/.hype/core/agents .claude/agents
```

---

### PROBLEM: "No messages returned" crash

**Симптомы:**
- Agent падает сразу после запуска
- В логах: "No messages returned"

**Причина:**
Пустой prompt или модель недоступна.

**Диагностика:**
```bash
cat .claude/agents/<agent>.md | head -20
claude --version
```

**Решение (report-only):**
Проверить agent файл. Это баг в HYPE — нужен doctor-log для архитектора.

---

### PROBLEM: Model unavailable / rate limit

**Симптомы:**
- "model not available" в логах
- 429 errors
- Операции timeout

**Причина:**
API rate limits или модель недоступна.

**Диагностика:**
```bash
grep -i "rate\|limit\|429\|unavailable" logs/hype.log | tail -20
```

**Решение:**
Подождать. HYPE автоматически retry с backoff.

---

### PROBLEM: Timeout без результата

**Симптомы:**
- Executor timeout (10 min по умолчанию)
- Worktree остался, задача open
- Нет коммита

**Причина:**
Задача слишком сложная или модель зависла.

**Диагностика:**
```bash
ls -la .hype-worktrees/
tail -100 logs/executor-<id>.log
```

**Решение:**
HYPE автоматически:
1. Reset stale task to open
2. Cleanup orphaned worktree
3. Retry с эскалацией модели

---

### PROBLEM: Script terminated on agent timeout

**Симптомы:**
- "Terminated: 15" в логах
- hype.sh внезапно завершается при timeout агента
- Exit code 124

**Причина:**
`set -e` убивает скрипт когда `run_claude_with_progress` возвращает non-zero (timeout=124). Error handling не успевает выполниться.

**Диагностика:**
```bash
grep -i "terminated\|exit 124" logs/hype.log
```

**Решение:**
Обновиться до HYPE 2.0.13+ где используется `|| exit_code=$?` pattern для перехвата exit code без срабатывания set -e.

```bash
cd ~/.hype && git pull
hype upgrade --force
```

---

## Файловая система проблемы

### PROBLEM: config.sh syntax error

**Симптомы:**
- HYPE падает при старте
- "Config validation failed"

**Причина:**
Синтаксическая ошибка в `.hype/config.sh`.

**Диагностика:**
```bash
bash -n .hype/config.sh
cat .hype/config.sh
```

**Решение (runtime-fix):**
```bash
# Восстановить из template
cp ~/.hype/templates/config.template.sh .hype/config.sh
```

---

### PROBLEM: Logs overflow

**Симптомы:**
- Диск заполнен
- `logs/` папка очень большая

**Причина:**
Много итераций без cleanup.

**Диагностика:**
```bash
du -sh logs/
ls -la logs/ | wc -l
```

**Решение (runtime-fix):**
```bash
# Архивировать старые логи
tar -czf logs-backup.tar.gz logs/
rm logs/*.log
```

---

## Milestones проблемы

### PROBLEM: Premature milestone

**Симптомы:**
- milestone:analysts-done существует
- Но analyst triggers ещё open/in_progress
- Фаза HELPERS не завершается корректно

**Причина:**
Race condition: milestone создан пока trigger был in_progress, потом timeout reset trigger to open.

**Диагностика:**
```bash
bd list --json | jq '.[] | select(.labels[]? | startswith("milestone:analysts"))'
bd list --json | jq '.[] | select(.title | startswith("run-analyst-")) | {id, status}'
```

**Решение:**
Self-healing в detect-phase.sh автоматически удаляет premature milestone.

**Manual fix:**
```bash
bd update <milestone-id> --remove-label=milestone:analysts-done
```
**Note (v2.3.1+):** HYPE больше не использует `bd delete` для milestones (создаёт tombstones). Вместо этого — `bd update --remove-label`.

---

## SMOKE_TEST проблемы

### PROBLEM: Testers not running (bd daemon frozen during SMOKE_TEST)

**Fixed in:** 2.2.6

**Симптомы:**
- `SMOKE_TEST: testers running (PID X)` в логах, но тестеры не работают
- `bd` commands timeout: `ERROR: bd command timeout: bd close ...`
- Tester logs show "Trigger already claimed" within 10-15 seconds (too fast for real test)
- Tester trigger tasks stuck in `open` (never claimed to `in_progress`)
- `bd show <id>` hangs (daemon frozen)

**Причина:**
До v2.2.6 `run-testers.sh` запускалось синхронно внутри HYPE main loop. 4+ Claude тестера + hype.sh одновременно вызывали `bd` — daemon перегружался и переставал отвечать. `check_beads` не запускалось (заблокировано внутри SMOKE_TEST), daemon не перезапускался. `bd_safe update --status=in_progress` таймаутил → интерпретировался как "already claimed" → тестер пропускал задачу.

**Диагностика:**
```bash
# Daemon alive but not responding?
timeout 5s bd show <any-id> 2>&1 || echo "DAEMON FROZEN"

# Check tester PID file
cat .hype/run-testers.pid 2>/dev/null
kill -0 $(cat .hype/run-testers.pid 2>/dev/null) 2>/dev/null && echo "RUNNING" || echo "DEAD"

# Check tester trigger states
bd list --all --json --limit 0 2>/dev/null | jq '.[] | select(.title | startswith("run-tester-")) | {id, title, status}'
```

**Решение:**
Обновиться до 2.2.6+. `run-testers.sh` запускается в background с PID tracking. HYPE продолжает тикать каждый цикл — `check_beads` обнаруживает и перезапускает frozen daemon.

**Manual fix (для старых версий):**
```bash
# 1. Kill frozen daemon
pkill -9 -f "bd daemon"
rm -f .beads/daemon.*
bd daemon start --log-level warn

# 2. Restart HYPE
hype stop && hype
```

---

### PROBLEM: Zombie trigger blocks phase transition (IMPLEMENTATION → SMOKE_TEST)

**Fixed in:** 2.2.5

**Симптомы:**
- Phase stuck on `IMPLEMENTATION` despite all real tasks being closed (100% progress)
- `bd list` shows a trigger task (e.g. `run-plan-review`) in `in_progress` from previous session
- Phase never transitions to SMOKE_TEST

**Причина:**
До v2.2.5 `detect-phase.sh` counted trigger tasks in OPEN/IN_PROGRESS totals. A zombie trigger (from crashed session) was counted as real work, blocking phase transition. `cleanup_stale_trigger()` couldn't help when bd daemon was also frozen.

**Диагностика:**
```bash
# Check for non-closed triggers
bd list --json --limit 0 | jq '.[] | select((.labels // []) | index("trigger")) | {id, title, status}'

# Check phase
./scripts/detect-phase.sh 2>&1 | jq .
```

**Решение:**
Обновиться до 2.2.5+. Три уровня защиты:
1. `detect-phase.sh` исключает trigger labels из OPEN/IN_PROGRESS
2. HYPE startup закрывает все orphaned triggers
3. `cleanup_stale_trigger()` чистит перед созданием новых

**Manual fix (для старых версий):**
```bash
bd close <trigger-id> --reason="Orphaned trigger"
```

---

### PROBLEM: Testers see OLD code (stale code loop)

**Симптомы:**
- SMOKE_TEST → bug → IMPLEMENTATION → fix → SMOKE_TEST → тот же bug
- Executor видит что фикс уже есть в исходниках
- Бесконечный цикл fix → test → same bug

**Причина:**
Python package без editable install или system python вместо venv.
Сервер запущен с установленным пакетом (site-packages), не с исходным кодом.

**Диагностика:**
```bash
# Проверить testing.yaml
cat .hype/testing.yaml

# Проверить какой python используется сервером
lsof -p $(cat .hype/server.pid 2>/dev/null) 2>/dev/null | grep python

# Сравнить mtime исходника vs установленного
stat -f %m src/module.py
stat -f %m $(python3 -c "import module; print(module.__file__)")
```

**Решение:**
Исправить testing.yaml — Opus создаёт конфиг при первом SMOKE_TEST через ensure_testing_config().
Если конфиг некорректный, testers найдут баги и система исправит в следующей итерации.

**Manual fix (testing.yaml):**
```yaml
# ДО (неправильно):
build_command: ""
start_command: python3 -m chatfilter.main

# ПОСЛЕ (правильно):
build_command: .venv/bin/pip install -e .
start_command: .venv/bin/python -m chatfilter.main
```

**Почему это важно:**
- `python3` = system python → читает `/Library/Frameworks/.../site-packages/`
- `.venv/bin/python` = venv python → читает проект
- `pip install -e .` = editable install → изменения видны сразу

---

### PROBLEM: Task stuck in blocked:troubleshoot

**Симптомы:**
- Задача с label `blocked:troubleshoot`
- Не подхватывается executors
- Была отклонена 4+ раз

**Причина:**
Задача исчерпала escalation ladder (reject:4+). Troubleshooter должен был обработать её.

**Диагностика:**
```bash
bd list --json | jq '.[] | select(.labels[]? == "blocked:troubleshoot") | {id, title, labels}'
ls -t logs/troubleshooter-*.log | head -3
```

**Решение (runtime-fix):**
```bash
# Вариант 1: Вручную переформулировать
bd update <id> --status=open --remove-label=blocked:troubleshoot \
  --add-label=reformulated --title="<новый подход>" --description="<новое описание>"

# Вариант 2: Закрыть как нерешаемую
bd close <id> --reason="Manual: removed from scope"

# Вариант 3: Пересбросить на troubleshooter
# (troubleshooter вызывается автоматически при следующем цикле)
```

---

### PROBLEM: USER_REVIEW phase — daemon stopped

**Симптомы:**
- Фаза `USER_REVIEW`
- HYPE daemon останавливается с сообщением "Daemon stopping"
- Задачи с `user-escalation` label

**Причина:**
Troubleshooter решил что задача требует решения пользователя (label `user-escalation`). Это штатное поведение — daemon останавливается чтобы пользователь принял решение.

**Диагностика:**
```bash
bd list --status=open --json | jq '.[] | select((.labels // []) | index("user-escalation"))'
cat .hype/evidence/user-review-report.md 2>/dev/null
```

**Решение (runtime-fix):**
```bash
# Прочитать отчёт
cat .hype/evidence/user-review-report.md

# Для каждой задачи выбрать действие:
bd close <id> --reason="User decision: skip this feature"
# или
bd update <id> --status=open --remove-label=user-escalation --description="<уточнённое описание>"

# Перезапустить HYPE
hype
```

---

### PROBLEM: Infinite regression loop (regress:N keeps growing)

**Симптомы:**
- Один и тот же баг возвращается после каждого SMOKE_TEST
- `regress:N` растёт (3+)
- Цикл: fix → test → same bug → fix

**Причина:**
1. Executor фиксит симптом, не причину
2. Код из старого пакета (см. "Testers see OLD code")
3. Задача слишком сложная для модели

**Диагностика:**
```bash
bd list --json | jq '.[] | select(.labels[]? | startswith("regress:")) | {id, title, labels}'
```

**Решение (runtime-fix):**
```bash
# Если regress:3+ — эскалировать вручную
bd update <id> --add-label=model:opus --notes="Manual escalation: persistent regression"

# Или закрыть и создать более точную задачу
bd close <id> --reason="Persistent regression, reformulating"
bd create --title="<более точное описание проблемы>" --type=bug --priority=1 --label=model:opus
```

---

### PROBLEM: reformulated task fails again

**Симптомы:**
- Задача с labels `reformulated` + `blocked:troubleshoot`
- Troubleshooter уже переформулировал, но опять reject:4

**Причина:**
Задача не решается автоматически даже после переформулировки.

**Диагностика:**
```bash
bd show <id> --json | jq '.[0] | {title, labels, notes}'
```

**Решение:**
Troubleshooter при 2-й неудаче с `reformulated` может только:
- Уменьшить scope (split)
- Убрать из scope (close)
- Эскалировать к user (`user-escalation`)

Если Troubleshooter не запустился — вручную:
```bash
bd close <id> --reason="Unresolvable after reformulation"
```

---

## Review Pipeline проблемы (v2.2)

### PROBLEM: Task stuck in reviewing

**Симптомы:**
- Задача в `in_progress` с label `reviewing` > 5 минут
- Reviewer не работает (нет процесса, лог не растёт)
- Lock файл `review-<task_id>.lock` может отсутствовать

**Причина:**
Reviewer crash или timeout без cleanup. Lock файл удалён, но label `reviewing` остался.

**Диагностика:**
```bash
bd list --status=in_progress --json --limit 0 | jq '.[] | select((.labels // []) | index("reviewing")) | {id, title, updated_at}'
ls -la .hype-worktrees/review-*.lock
ls -la .hype-worktrees/reviewer-*.lock
```

**Решение (runtime-fix):**
```bash
bd update <id> --remove-label=reviewing --add-label=needs-review
```

**Auto-recovery (v2.2+):**
`heal_stuck_tasks()` автоматически обнаруживает задачи stuck в `reviewing` >3 минут без активного reviewer lock. Возвращает в `needs-review`.

---

### PROBLEM: Task stuck in approved (merge queue not picking up)

**Симптомы:**
- Задача в `in_progress` с label `approved` > 10 минут
- `run-merge-queue.sh` не запускается или ошибки в логе
- Ветка `task/beads-<id>` существует

**Причина:**
1. Merge queue не запустился (hype.sh не дошёл до этого шага)
2. Git проблемы (lock, merge in progress)
3. Branch отсутствует на remote

**Диагностика:**
```bash
bd list --status=in_progress --json --limit 0 | jq '.[] | select((.labels // []) | index("approved")) | {id, title, updated_at}'
git branch -r | grep task/beads-
grep "MERGE" logs/hype.log | tail -10
```

**Решение (runtime-fix):**
```bash
# Вариант 1: Перезапустить merge queue
./scripts/run-merge-queue.sh

# Вариант 2: Вернуть на ревью
bd update <id> --remove-label=approved --add-label=needs-review
```

**Auto-recovery (v2.3.11+):**
`heal_stuck_tasks()`: предупреждение при >5 минут. Merge queue (v2.3.11) использует hybrid подход: fast script path → agent fallback → executor. Если empty squash — задача закрывается автоматически с reason.

---

### PROBLEM: Empty squash — task loops in merge queue forever

**Fixed in:** 2.2.2

**Симптомы:**
- Задача с `approved` label крутится в merge queue без прогресса
- В логах: "Main unchanged after merge" повторяется
- `reject:N` не растёт (merge queue возвращал 0 без действий)
- heal_stuck_tasks возвращает в executor, но тот ничего не меняет

**Причина:**
`git merge --squash` не даёт изменений (branch changes already in main). Merge queue логировал warning и возвращал 0, но label `approved` оставался → merge queue подбирал задачу снова → бесконечный цикл.

**Диагностика:**
```bash
# Проверить что branch уже в main
git log --oneline origin/main | head -5
git diff origin/main..origin/task/beads-<id>  # пустой diff = empty squash
```

**Решение:**
Обновиться до 2.2.2+. Merge queue теперь закрывает задачу с reason "Empty merge — branch changes already in main".

**Manual fix (для старых версий):**
```bash
bd close <id> --reason="Empty merge — branch already in main"
bd update <id> --remove-label=approved --add-label=reviewed
```

---

### PROBLEM: Merge conflict (approved → fast merge fails → agent fallback)

**Симптомы:**
- В логах: "Fast merge failed for <id>" → "Launching merger agent"
- Задача задерживается в `approved` пока agent работает (~2-5 мин)
- После agent: "MERGED (agent)" или "Merger agent failed — returning to executor"

**Причина:**
1. Другая задача мержится между ребейзом и пушем (race condition)
2. Ветка слишком разошлась с main
3. Конфликт в auto-generated файлах (lock files, build artifacts)

**Диагностика:**
```bash
bd show <id> --json | jq '.[0] | {id, title, labels, notes}'
grep "MERGE\|merger agent\|Fast merge" logs/hype.log | grep <id>
cat logs/merger-<id>.log  # лог агента-мёрджера
git log --oneline origin/main | head -10
```

**Auto-recovery (v2.3.11+):**
Hybrid merge queue — два уровня:
1. **Fast path** (`try_fast_merge`): rebase → squash → push. Если OK → задача закрыта. Бесплатно, ~5 сек
2. **Agent fallback** (`run_merger_agent`): если fast path fails — Claude opus agent получает diff + conflict context, разрешает конфликты, мержит, закрывает задачу. ~2-5 мин
3. **Executor fallback**: если и agent не справился → задача возвращается executor (`--status=open --remove-label=approved`) с подробными notes

**Решение (runtime-fix, если обе автоматики не справились):**
```bash
# Вариант 1: Ручной мерж
git fetch origin
git checkout task/beads-<id>
git rebase origin/main
# Resolve conflicts manually
git push --force-with-lease origin task/beads-<id>
bd update <id> --add-label=needs-review --remove-label=approved

# Вариант 2: Закрыть и пересоздать
bd close <id> --reason="Persistent merge conflicts"
```

---

### PROBLEM: Reviewer-executor thrashing (rapid reject without progress)

**Симптомы:**
- reject:N растёт быстро (3-4 за цикл)
- Reviewer отклоняет по одной и той же причине
- Executor не исправляет проблему

**Причина:**
1. Rejection reason слишком общий для executor
2. Executor не видит review notes
3. Модель executor слишком слабая для задачи

**Диагностика:**
```bash
bd show <id> --json | jq '.[0] | {labels, notes}'
tail -50 logs/reviewer-<id>.log 2>/dev/null
tail -50 logs/executor-<id>.log 2>/dev/null
```

**Решение (runtime-fix):**
```bash
# Эскалировать модель вручную
bd update <id> --add-label=model:opus --notes="Manual: persistent rejection"

# Или переформулировать задачу
bd update <id> --description="<более точное описание>"
```

**Auto-recovery (v2.2+):**
Escalation ladder: reject:2-3 → model escalation (haiku→sonnet→opus), reject:4 → Troubleshooter. Circuit breaker (v2.1.8+) через `last-reject:{TYPE}` label обнаруживает same-reason loops после reformulation и эскалирует к user-escalation.

**Note (v2.3.11+):** `reject:N` только для code quality rejections. Merge конфликты обрабатываются hybrid merge queue (fast script → agent fallback → executor). Counter `merge-conflict:N` убран.

---

### PROBLEM: Review timeout falsely escalates model (reject:N grows on infrastructure timeouts)

**Fixed in:** 2.2.2

**Симптомы:**
- reject:N растёт для нескольких задач одновременно
- Модели эскалируются до opus без реальных code quality проблем
- Задачи попадают к troubleshooter, хотя код нормальный
- В логах reviewer: timeout (exit 124), а не конкретные замечания

**Причина:**
До v2.2.2 timeout Claude при ревью (exit 124) трактовался как "no action" и инкрементировал `reject:N`. При медленном API или параллельной нагрузке — все ревью таймаутились, reject:N рос для всех задач, модели эскалировались впустую.

**Диагностика:**
```bash
# Проверить что задачи реджектятся по таймауту, не по содержанию
grep "REVIEW TIMEOUT" logs/hype.log | tail -10
# Проверить reject:N — если растёт для многих задач одновременно, это инфраструктурная проблема
bd list --status=in_progress --json --limit 0 | jq '.[] | select(.labels[]? | startswith("reject:")) | {id, title, labels}'
```

**Решение:**
Обновиться до 2.2.2+. Timeout теперь возвращает задачу в `needs-review` БЕЗ инкремента reject:N. Следующий reviewer попробует снова.

**Manual fix (для старых версий):**
```bash
# Сбросить ложные reject:N
bd update <id> --remove-label=reject:4 --add-label=reject:0 --remove-label=blocked:troubleshoot
bd update <id> --add-label=needs-review --status=in_progress
```

---

### PROBLEM: Secrets-warning blocks review progress

**Since:** 2.2.1

**Симптомы:**
- Задача с label `secrets-warning` в review pipeline
- Reviewer отклоняет из-за "security warning" для тестовых данных
- Задача циклит между executor и reviewer

**Причина:**
Preflight check в `run-reviewers.sh` нашёл credential-like patterns в diff (API keys, passwords, .env). Это soft warning — reviewer должен решить, но слабые модели (sonnet) могут перестраховаться и отклонить.

**Диагностика:**
```bash
# Проверить что именно нашёл preflight
bd show <id> --json | jq '.[0].labels'
grep "SECRETS_WARNING" logs/reviewer-*.log | tail -5
# Посмотреть diff задачи
git diff origin/main..origin/task/beads-<id> | grep -iE "sk-|api_key|password|secret|\.env"
```

**Решение (runtime-fix):**
```bash
# Если это тестовые данные — эскалировать модель до opus (лучше отличает real secrets от test data)
bd update <id> --add-label=model:opus --remove-label=secrets-warning
bd update <id> --add-label=needs-review
```

---

### PROBLEM: Trigger task stuck in review pipeline

**Fixed in:** 2.2.1

**Симптомы:**
- Задача с label `trigger` в `reviewing` или `needs-review` статусе
- В логах reviewer: "NO_BRANCH" error (trigger не имеет git branch)
- P0 bug count растёт, SMOKE_TEST блокируется
- Бесконечный цикл: trigger → review → NO_BRANCH → reject → review

**Причина:**
Trigger tasks — системные координационные задачи (run-analyst-*, run-tester-*), не пользовательский код. До v2.2.1 они могли попасть в review pipeline через heal_stuck_tasks (добавляло needs-review) или через get_review_tasks (не фильтровало по label trigger).

**Диагностика:**
```bash
bd list --json --limit 0 | jq '.[] | select((.labels // []) | index("trigger")) | {id, title, status, labels}'
```

**Решение:**
Обновиться до 2.2.1+. Trigger tasks исключены из всех task-fetching функций.

**Manual fix (для старых версий):**
```bash
bd close <id>  # Просто закрыть trigger
```

---

### PROBLEM: Orphaned reviewer slot (reviewer-N.lock stuck)

**Симптомы:**
- `MAX_PARALLEL_REVIEWERS` слотов заняты, но reviewer не работают
- `.hype-worktrees/reviewer-N.lock` существует без процесса

**Причина:**
Reviewer crash без cleanup lock.

**Диагностика:**
```bash
ls -la .hype-worktrees/reviewer-*.lock
pgrep -fl reviewer
```

**Решение (runtime-fix):**
```bash
rmdir .hype-worktrees/reviewer-N.lock
```

**Auto-recovery (v2.2+):**
`find_free_reviewer_slot()` автоматически чистит stale locks >20 минут.

---

## Doctor проблемы

### PROBLEM: Doctor report send failure (label not found)

**Fixed in:** 2.3.3. `send_doctor_report()` вызывает `gh label create "doctor-report"` перед `gh issue create` (idempotent).

---

## Формат doctor-log

```markdown
# Doctor Log
Date: YYYY-MM-DD HH:MM
Project: /path/to/project
HYPE Version: X.Y.Z

## Reported Symptom
[Что сказал пользователь — дословно]

## Collected Data
[ВСЕ результаты диагностических команд]

## Hypotheses Considered
1. [Гипотеза A]: [статус] — [почему подтвердилась/опровергнута]
2. [Гипотеза B]: [статус] — [почему подтвердилась/опровергнута]
3. [Гипотеза C]: [статус] — [почему подтвердилась/опровергнута]

## Final Diagnosis
**Root Cause:** [причина с доказательствами]
**Affected Component:** [скрипт/функция]
**Confidence:** [high/medium/low]
**Problem Type:** [runtime-fix | report-only]

## Evidence Supporting Diagnosis
[Конкретные данные, подтверждающие диагноз]

## Evidence Against (if any)
[Данные, которые не полностью согласуются — для честности]

## Suggested Fix
[Для разработчика HYPE]

## Workaround Applied
[Какие runtime-fix были применены, если были]
```
