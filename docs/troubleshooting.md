# HYPE Troubleshooting

Справочник проблем для Doctor-агента. Формат оптимизирован для LLM-поиска.

---

## Beads проблемы

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

**Auto-recovery:**
`check_beads()` в common.sh использует `bd list --limit 1` probe. 3 попытки с 2s pause. `bd_safe()` auto-retry для write operations (update, close, create, set-state).

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

**Note:** HYPE автоматически сбрасывает stale tasks через `check_stale_tasks()` (default 10 min). Дополнительно, `heal_stuck_tasks()` добавляет `needs-review` к tasks stuck >2 min без coder/needs-review labels.

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
`create_worktree()` calls `setup_worktree_links()` which auto-symlinks build artifact dirs from project root into worktree.

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

**Причина:**
`detect-phase.sh` входил в REFLEXING как только ЛЮБОЙ тестер создавал smoke задачу, не дожидаясь завершения всех тестеров. Async тестеры заканчивают с разницей в 5-8 минут → каждый завершённый тестер триггерил отдельный REFLEXING.

**Решение:**
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
**Note:** HYPE больше не использует `bd delete` для milestones (создаёт tombstones). Вместо этого — `bd update --remove-label`.

---

## TESTING проблемы

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

### PROBLEM: CONSULTATION phase — interactive Manager doesn't start

**Симптомы:**
- Фаза `CONSULTATION` в логах
- Интерактивное окно не открывается
- HYPE крутится в цикле без диалога

**Причина:**
1. `manager-review.md` отсутствует или повреждён
2. Claude CLI не установлен или не авторизован
3. Модель недоступна

**Диагностика:**
```bash
ls -la .claude/agents/manager-review.md
claude --version
bd list --status=open --json --limit 0 | jq '.[] | select((.labels // []) | index("user-escalation")) | {id, title}'
```

**Решение (runtime-fix):**
```bash
# Обновить HYPE (переустановит агентов)
hype upgrade --force

# Или вручную снять эскалацию если решение известно:
bd update <id> --status=open --remove-label=user-escalation --remove-label=blocked:troubleshoot --notes="Manual: <решение>"
```

**Note:** CONSULTATION использует интерактивный Manager (как PREPARING). Manager объясняет проблему, собирает решение пользователя, записывает в notes задачи. Troubleshooter подхватывает на следующем цикле. Если Manager упал — labels остались, HYPE повторит CONSULTATION на следующем цикле.

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

## Review Pipeline проблемы

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

**Auto-recovery:**
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

**Auto-recovery:**
`heal_stuck_tasks()`: предупреждение при >5 минут. Merge queue использует hybrid подход: fast script path → agent fallback → coder. Если empty squash — задача закрывается автоматически с reason.

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

**Auto-recovery:**
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

**Auto-recovery:**
Escalation ladder: reject:2-3 → model escalation (haiku→sonnet→opus), reject:4 → Troubleshooter. Circuit breaker через `last-reject:{TYPE}` label обнаруживает same-reason loops после reformulation и эскалирует к user-escalation.

**Note:** `reject:N` только для code quality rejections. Merge конфликты обрабатываются hybrid merge queue (fast script → agent fallback → coder).

---

### PROBLEM: Secrets-warning blocks review progress

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

### PROBLEM: Audit findings not reviewed (task auto-closed)

**Симптомы:**
- Audit задача закрыта, но findings в notes не привели к fix-задачам
- В логах: "Audit review failed for <id>" с exit code
- Audit задача вернулась в `needs-review` (retry loop)

**Причина:**
1. Plan-reviewer timeout (audit_review mode, 5 min default)
2. Plan-reviewer не смог прочитать findings из notes (пустые notes)
3. До текущей версии: Senior авто-одобрял audit задачи → findings никем не читались

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

**Auto-recovery:**
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

**Auto-recovery:**
`find_free_senior_slot()` автоматически чистит stale locks >20 минут.

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
