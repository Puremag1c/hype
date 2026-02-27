# HYPE Troubleshooting

Справочник проблем для Doctor-агента. Формат оптимизирован для LLM-поиска.

---

## Beads проблемы

> **v2.5+ (beads v0.55+):** Daemon удалён в v0.50, sync — no-op в v0.51. Beads использует Dolt embedded.
> Проблемы daemon frozen/zombie/explosion больше невозможны.

### PROBLEM: bd commands timeout/hang

**Симптомы:**
- Команды `bd` зависают на 30+ секунд
- В логах: "bd command timeout" или "bd backend unhealthy"

**Причина:**
Dolt embedded может зависнуть при повреждённой базе или lock contention.

**Диагностика:**
```bash
bd doctor                       # Встроенная диагностика
timeout 5s bd list --limit 1    # Простой health check
ls -la /tmp/hype-bd.lock.d      # Проверить stale lock
```

**Решение:**
```bash
# 1. Убрать stale lock (если HYPE не запущен)
rmdir /tmp/hype-bd.lock.d 2>/dev/null

# 2. Проверить базу
bd admin cleanup --force

# 3. Если ничего не помогает — пересоздать
rm -rf .beads/*.db
bd create --title="test" && bd close $(bd list --json | jq -r '.[0].id')
```

**Auto-recovery (v2.5+):**
`check_beads()` в common.sh использует `bd list --limit 1` probe. 3 попытки с 2s pause. `bd_safe()` auto-retry для write operations (update, close, create, set-state).

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
- Coder для этой задачи не работает (нет процесса, лог не растёт)
- `bd list --status=in_progress` показывает старые задачи

**Причина:**
Coder упал/timeout без cleanup.

**Диагностика:**
```bash
bd list --status=in_progress --json | jq '.[] | {id, title, updated_at}'
# Проверить возраст updated_at
```

**Решение (runtime-fix):**
```bash
bd update <id> --status=open --remove-label=coder
```

**Note:** HYPE автоматически сбрасывает stale tasks через `check_stale_tasks()` (default 10 min). Дополнительно, `heal_stuck_tasks()` (2.1.4+) добавляет `needs-review` к tasks stuck >2 min без coder/needs-review labels.

---

### PROBLEM: Orphaned needs-review label

**Симптомы:**
- Closed задача с `needs-review` label
- Senior не видит задачу (она closed)

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
- HYPE не переходит в CODING

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
Другой процесс (coder, senior) закрыл задачу между list и show.

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
Stale Dolt lock или конкурентный доступ к БД.

**Диагностика:**
```bash
bd doctor --fix
bd show <id> --json | jq '.[0].labels'
```

**Решение (runtime-fix):**
```bash
bd doctor --fix
```

---

### PROBLEM: Build fails in worktree (missing deps)

**Fixed in:** 2.5.11

**Симптомы:**
- Coder in worktree runs `mix test` / `npm test` → "deps not found" / "module not found"
- Reject cascade (10+ rejects) for tasks that should be trivial
- Only happens when project has build artifacts (`deps/`, `node_modules/`, etc.)

**Причина:**
`git worktree add` creates a clean checkout without gitignored build artifact directories. Coders need `deps/`, `_build/`, `node_modules/`, `.venv/`, `vendor/`, `target/` to compile and test.

**Диагностика:**
```bash
ls -la .hype-worktrees/coder-0/deps     # Should be symlink or exist
ls -la .hype-worktrees/coder-0/node_modules
```

**Решение:**
Обновиться до 2.5.11+. `create_worktree()` now calls `setup_worktree_links()` which auto-symlinks build artifact dirs from project root into worktree.

**Manual fix (для старых версий):**
```bash
ln -sf "$PROJECT_DIR/deps" .hype-worktrees/coder-0/deps
ln -sf "$PROJECT_DIR/node_modules" .hype-worktrees/coder-0/node_modules
```

---

## Git проблемы

### PROBLEM: Orphaned worktree

**Симптомы:**
- `.hype-worktrees/coder-N` существует
- Coder не работает (нет процесса)
- `git worktree list` показывает orphaned worktree

**Причина:**
Coder crash или timeout без cleanup.

**Диагностика:**
```bash
ls -la .hype-worktrees/
git worktree list
pgrep -f coder
```

**Решение (runtime-fix):**
```bash
git worktree remove --force .hype-worktrees/coder-N
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
- Coder не может работать

**Причина:**
Предыдущий coder не сделал commit перед exit.

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

### PROBLEM: Phase stuck on PREPARING

**Симптомы:**
- PREPARING повторяется хотя SPEC.md существует
- detect-phase.sh возвращает PREPARING

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

### PROBLEM: REFLEXING loop

**Симптомы:**
- Фаза REFLEXING повторяется бесконечно
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

### PROBLEM: REFLEXING phase bouncing (TESTING → REFLEXING → CODING loop)

**Симптомы:**
- Фаза прыгает: TESTING → REFLEXING → CODING → REFLEXING → CODING
- QA (Opus) вызывается 3-4 раза вместо одного
- Задачи видны как "крутящиеся" часами

**Причина (≤v2.3.12):**
`detect-phase.sh` входил в REFLEXING как только ЛЮБОЙ тестер создавал smoke задачу, не дожидаясь завершения всех тестеров. Async тестеры (v2.2.6) заканчивают с разницей в 5-8 минут → каждый завершённый тестер триггерил отдельный REFLEXING.

**Исправлено в v2.3.13:**
`detect-phase.sh` проверяет PID файл `run-testers.pid` — пока тестеры работают, REFLEXING откладывается. Все findings накапливаются, Architect триажит один раз.

---

### PROBLEM: Zombie coders

**Симптомы:**
- Много процессов `claude` висят
- Memory/CPU высокий
- Задачи не продвигаются

**Причина:**
Coders не завершились корректно.

**Диагностика:**
```bash
pgrep -f claude
pgrep -f coder
ps aux | grep claude
```

**Решение (runtime-fix):**
```bash
# Осторожно — убьёт все claude процессы
pkill -f "claude.*coder"
```

---

### PROBLEM: Too many parallel coders

**Симптомы:**
- Больше `MAX_PARALLEL_CODERS` процессов
- Rate limits от API
- Slow performance

**Причина:**
Backpressure не сработал.

**Диагностика:**
```bash
pgrep -c -f coder
cat .hype/config.sh | grep MAX_PARALLEL
```

**Решение:**
Подождать пока текущие coders завершатся. HYPE контролирует через backpressure.

---

### PROBLEM: All coder slots always free (backpressure 0)

**Fixed in:** 2.1.5

**Симптомы:**
- Backpressure log показывает "0/N active" при работающих coders
- Больше параллельных coders чем MAX_PARALLEL_CODERS
- Daemon перегружен от бесконечного claim loop

**Причина:**
`count_active_coders()` считала по beads label `coder`, но labels ненадёжны из-за sync lag и race conditions. Tasks были in_progress без label → backpressure всегда 0 → бесконечный claim.

**Решение:**
Обновиться до 2.1.5+. `count_active_coders()` теперь считает по lock files (`coder-N.lock` в `.hype-worktrees/`), которые точно отражают время жизни coder.

---

### PROBLEM: Coder slots exhausted (.hype-worktrees missing)

**Fixed in:** 2.1.4

**Симптомы:**
- Ни один coder не запускается
- В логах: "No free slots"
- `.hype-worktrees/` директории не существует

**Причина:**
`find_free_slot()` использовала `mkdir` без `-p` для создания lock files внутри `.hype-worktrees/`. Если parent директория не существует, все 20 слотов fail silently.

**Решение:**
Обновиться до 2.1.4+. `find_free_slot()` теперь создаёт parent директорию через `mkdir -p`.

---

### PROBLEM: Needs-review label lost after coder completion

**Fixed in:** 2.1.4

**Симптомы:**
- Задача в `in_progress` без `coder` и без `needs-review` labels
- Senior не видит завершённую задачу
- Задача "зависает" без обработки

**Причина:**
Когда несколько coders завершались одновременно во время beads sync (git fetch), `bd_safe update --add-label=needs-review` silently failed через `|| true`.

**Решение:**
Обновиться до 2.1.4+. Completion path теперь retry 3 раза с 2s delay. Плюс self-healing в main loop: `heal_stuck_tasks()` автоматически добавляет `needs-review` к задачам stuck >2 минут без coder/needs-review labels.

---

### PROBLEM: Coder lock leak on early return

**Fixed in:** 2.1.4

**Симптомы:**
- Слоты coder'ов заканчиваются со временем
- Lock файлы остаются в `.hype-worktrees/` без процесса
- `ls .hype-worktrees/*.lock` показывает orphaned locks

**Причина:**
`run_coder()` имел два early return (task not open, claim failed) без вызова `cleanup_worktree`. Locks накапливались через циклы HYPE.

**Решение:**
Обновиться до 2.1.4+. Все exit paths теперь вызывают `cleanup_worktree`.

---

### PROBLEM: NO_MERGE decision not detected (infinite reopen loop)

**Fixed in:** 2.1.2

**Симптомы:**
- Задача с "No Merge" решением от senior переоткрывается снова и снова
- Бесконечный цикл: coder → senior → "No Merge" → reopen → coder
- Задача не закрывается

**Причина:**
`bd close --reason` записывает в поле `close_reason`, не в `notes`. Senior проверял только `notes`, не видел "No Merge" решение, и переоткрывал задачу.

**Решение:**
Обновиться до 2.1.2+. Senior теперь проверяет оба поля: `notes` и `close_reason`.

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
- Beads backend медленный (>5s на запрос)
- CPU высокий от bd процессов
- В логах: много rapid-fire bd calls

**Причина:**
Cascading failure: backpressure bug (always 0) → infinite claim loop → backend перегружен → slow responses → timeout/retry → ещё больше нагрузки.

**Решение:**
Обновиться до 2.1.5+. Root cause (backpressure) исправлен. Дополнительно: adaptive backoff удваивает iteration delay при slow backend (>2s), cap 60s. detect-phase.sh оптимизирован с 2 bd calls до 1.

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
- Coder timeout (10 min по умолчанию)
- Worktree остался, задача open
- Нет коммита

**Причина:**
Задача слишком сложная или модель зависла.

**Диагностика:**
```bash
ls -la .hype-worktrees/
tail -100 logs/coder-<id>.log
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
- Фаза ANALYZE не завершается корректно

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

## TESTING проблемы

### PROBLEM: Testers not running (bd frozen during TESTING)

**Fixed in:** 2.2.6 (daemon issues eliminated in v2.5 with Dolt backend)

**Симптомы:**
- `TESTING: testers running (PID X)` в логах, но тестеры не работают
- `bd` commands timeout: `ERROR: bd command timeout: bd close ...`
- Tester logs show "Trigger already claimed" within 10-15 seconds (too fast for real test)
- Tester trigger tasks stuck in `open` (never claimed to `in_progress`)
- `bd show <id>` hangs (daemon frozen)

**Причина:**
До v2.2.6 `run-testers.sh` запускалось синхронно внутри HYPE main loop. 4+ Claude тестера + hype.sh одновременно вызывали `bd` — daemon перегружался и переставал отвечать. `check_beads` не запускалось (заблокировано внутри TESTING), daemon не перезапускался. `bd_safe update --status=in_progress` таймаутил → интерпретировался как "already claimed" → тестер пропускал задачу.

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
# 1. Clean stale locks
bd doctor --fix

# 2. Restart HYPE
hype stop && hype
```

---

### PROBLEM: Zombie trigger blocks phase transition (CODING → TESTING)

**Fixed in:** 2.2.5

**Симптомы:**
- Phase stuck on `CODING` despite all real tasks being closed (100% progress)
- `bd list` shows a trigger task (e.g. `run-plan-review`) in `in_progress` from previous session
- Phase never transitions to TESTING

**Причина:**
До v2.2.5 `detect-phase.sh` counted trigger tasks in OPEN/IN_PROGRESS totals. A zombie trigger (from crashed session) was counted as real work, blocking phase transition. `cleanup_stale_trigger()` couldn't help when the beads backend was also unresponsive.

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
- TESTING → bug → CODING → fix → TESTING → тот же bug
- Coder видит что фикс уже есть в исходниках
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
Исправить testing.yaml — Opus создаёт конфиг при первом TESTING через ensure_testing_config().
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
- Не подхватывается coders
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

### PROBLEM: CONSULTATION phase — hype stopped

**Симптомы:**
- Фаза `CONSULTATION`
- HYPE останавливается с сообщением о user escalation
- Задачи с `user-escalation` label

**Причина:**
Troubleshooter решил что задача требует решения пользователя (label `user-escalation`). Это штатное поведение — HYPE останавливается чтобы пользователь принял решение.

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
- Один и тот же баг возвращается после каждого TESTING
- `regress:N` растёт (3+)
- Цикл: fix → test → same bug → fix

**Причина:**
1. Coder фиксит симптом, не причину
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
- Senior не работает (нет процесса, лог не растёт)
- Lock файл `review-<task_id>.lock` может отсутствовать

**Причина:**
Senior crash или timeout без cleanup. Lock файл удалён, но label `reviewing` остался.

**Диагностика:**
```bash
bd list --status=in_progress --json --limit 0 | jq '.[] | select((.labels // []) | index("reviewing")) | {id, title, updated_at}'
ls -la .hype-worktrees/review-*.lock
ls -la .hype-worktrees/senior-*.lock
```

**Решение (runtime-fix):**
```bash
bd update <id> --remove-label=reviewing --add-label=needs-review
```

**Auto-recovery (v2.2+):**
`heal_stuck_tasks()` автоматически обнаруживает задачи stuck в `reviewing` >3 минут без активного senior lock. Возвращает в `needs-review`.

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
`heal_stuck_tasks()`: предупреждение при >5 минут. Merge queue (v2.3.11) использует hybrid подход: fast script path → agent fallback → coder. Если empty squash — задача закрывается автоматически с reason.

---

### PROBLEM: Empty squash — task loops in merge queue forever

**Fixed in:** 2.2.2

**Симптомы:**
- Задача с `approved` label крутится в merge queue без прогресса
- В логах: "Main unchanged after merge" повторяется
- `reject:N` не растёт (merge queue возвращал 0 без действий)
- heal_stuck_tasks возвращает в coder, но тот ничего не меняет

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
- После agent: "MERGED (agent)" или "Merger agent failed — returning to coder"

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
3. **Coder fallback**: если и agent не справился → задача возвращается coder (`--status=open --remove-label=approved`) с подробными notes

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

### PROBLEM: Senior-coder thrashing (rapid reject without progress)

**Симптомы:**
- reject:N растёт быстро (3-4 за цикл)
- Senior отклоняет по одной и той же причине
- Coder не исправляет проблему

**Причина:**
1. Rejection reason слишком общий для coder
2. Coder не видит review notes
3. Модель coder слишком слабая для задачи

**Диагностика:**
```bash
bd show <id> --json | jq '.[0] | {labels, notes}'
tail -50 logs/senior-<id>.log 2>/dev/null
tail -50 logs/coder-<id>.log 2>/dev/null
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

**Note (v2.3.11+):** `reject:N` только для code quality rejections. Merge конфликты обрабатываются hybrid merge queue (fast script → agent fallback → coder). Counter `merge-conflict:N` убран.

---

### PROBLEM: Review timeout falsely escalates model (reject:N grows on infrastructure timeouts)

**Fixed in:** 2.2.2

**Симптомы:**
- reject:N растёт для нескольких задач одновременно
- Модели эскалируются до opus без реальных code quality проблем
- Задачи попадают к troubleshooter, хотя код нормальный
- В логах senior: timeout (exit 124), а не конкретные замечания

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
Обновиться до 2.2.2+. Timeout теперь возвращает задачу в `needs-review` БЕЗ инкремента reject:N. Следующий senior попробует снова.

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
- Senior отклоняет из-за "security warning" для тестовых данных
- Задача циклит между coder и senior

**Причина:**
Preflight check в `run-seniors.sh` нашёл credential-like patterns в diff (API keys, passwords, .env). Это soft warning — senior должен решить, но слабые модели (sonnet) могут перестраховаться и отклонить.

**Диагностика:**
```bash
# Проверить что именно нашёл preflight
bd show <id> --json | jq '.[0].labels'
grep "SECRETS_WARNING" logs/senior-*.log | tail -5
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
- В логах senior: "NO_BRANCH" error (trigger не имеет git branch)
- P0 bug count растёт, TESTING блокируется
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

### PROBLEM: Audit findings not reviewed (task auto-closed)

**Since:** 2.5.9

**Симптомы:**
- Audit задача закрыта, но findings в notes не привели к fix-задачам
- В логах: "Audit review failed for <id>" с exit code
- Audit задача вернулась в `needs-review` (retry loop)

**Причина:**
1. Plan-reviewer timeout (audit_review mode, 5 min default)
2. Plan-reviewer не смог прочитать findings из notes (пустые notes)
3. До v2.5.9: Senior авто-одобрял audit задачи → findings никем не читались

**Диагностика:**
```bash
# Проверить audit задачи
bd list --json --limit 0 | jq '.[] | select((.labels // []) | index("audit")) | {id, title, status, labels}'

# Проверить лог audit review
cat logs/audit-review-<id>.log 2>/dev/null

# Проверить findings (notes)
bd show <id> --json | jq '.[0].notes'
```

**Решение (runtime-fix):**
```bash
# Если findings есть но plan-reviewer таймаутнул — пересбросить на ревью
bd update <id> --add-label=needs-review --remove-label=reviewing
```

**Auto-recovery (v2.5.9+):**
При timeout plan-reviewer задача автоматически возвращается в `needs-review`. Senior подберёт на следующем тике.

---

### PROBLEM: Orphaned senior slot (senior-N.lock stuck)

**Симптомы:**
- `MAX_PARALLEL_SENIORS` слотов заняты, но senior не работают
- `.hype-worktrees/senior-N.lock` существует без процесса

**Причина:**
Senior crash без cleanup lock.

**Диагностика:**
```bash
ls -la .hype-worktrees/senior-*.lock
pgrep -fl senior
```

**Решение (runtime-fix):**
```bash
rmdir .hype-worktrees/senior-N.lock
```

**Auto-recovery (v2.2+):**
`find_free_senior_slot()` автоматически чистит stale locks >20 минут.

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
