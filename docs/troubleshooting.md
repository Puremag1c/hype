# HYPE Troubleshooting

Справочник проблем для Doctor-агента. Формат оптимизирован для LLM-поиска.

---

## Beads проблемы

### PROBLEM: Beads daemon frozen

**Симптомы:**
- Команды `bd` зависают на 30+ секунд
- `bd sync --status` не отвечает
- В логах: timeout на bd операциях

**Причина:**
Daemon завис или SQLite lock не освободился.

**Диагностика:**
```bash
timeout 5s bd sync --status
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
HYPE 2.0.14+ использует `bd_safe()` с сериализацией через mkdir-lock. Все bd вызовы выполняются последовательно.

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

**Note:** HYPE автоматически сбрасывает stale tasks через `check_stale_tasks()` (default 10 min).

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
bd delete <milestone-id>
```

---

## SMOKE_TEST проблемы

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

## Формат doctor-log

```markdown
# Doctor Log
Date: YYYY-MM-DD HH:MM
Project: /path/to/project

## Reported Symptom
[Что сказал пользователь]

## Diagnosis
[Что обнаружено]

## Root Cause
[Почему произошло]

## Affected Component
[Какой скрипт/функция]

## Evidence
[Логи, команды, вывод]

## Suggested Fix
[Для разработчика HYPE]

## Workaround Applied
[Какие runtime-fix были применены, если были]
```
