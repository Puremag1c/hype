#!/bin/bash
# core/scripts/detect-phase.sh
# Определяет текущую фазу проекта из состояния Beads и файлов.
#
# Фазы: PREPARING → PLANNING → ANALYZE → THINKING → [REFLEXING] → CODING → TESTING → VALIDATING → REPORTING → DONE
#        REFLEXING — срабатывает когда есть regression tasks (после TESTING нашёл баги)
#        IDLE — проект существует, но нет активной работы (требует решения пользователя)
#
# Использование: ./scripts/detect-phase.sh
# Выводит: JSON с phase и метаданными (v1.9.0+)
#
# Формат вывода:
# {
#   "phase": "CODING",
#   "stats": { "total": 55, "open": 3, "in_progress": 2, "closed": 50 },
#   "progress_pct": 91,
#   "in_progress_ids": ["beads-abc", "beads-def"],
#   "regression_count": 0,
#   "p0_bugs": 0
# }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# Находим корень проекта
find_project_root() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/.hype" ]; then
            echo "$dir"
            return 0
        fi
        dir=$(dirname "$dir")
    done
    echo "$PWD"
}

PROJECT_ROOT=$(find_project_root)

# Проверяем beads
if ! command -v bd &> /dev/null; then
    echo '{"phase":"ERROR","stats":{},"progress_pct":0,"in_progress_ids":[],"regression_count":0,"p0_bugs":0,"error":"bd not installed"}'
    >&2 echo "Beads (bd) не установлен"
    exit 1
fi

# Проверяем jq
if ! command -v jq &> /dev/null; then
    echo '{"phase":"ERROR","stats":{},"progress_pct":0,"in_progress_ids":[],"regression_count":0,"p0_bugs":0,"error":"jq not installed"}'
    >&2 echo "jq не установлен"
    exit 1
fi

# Собираем статистику из beads (1 запрос, всё через jq)
# ВАЖНО: --limit 0 для unlimited (по умолчанию 50)
ALL_TASKS_JSON=$(bd_safe list --json --limit 0 --all 2>/dev/null)
if [ $? -ne 0 ] || ! echo "$ALL_TASKS_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
    # Dolt embedded may transiently fail — retry once after brief wait
    >&2 echo "bd list failed, retrying after 2s..."
    sleep 2
    ALL_TASKS_JSON=$(bd_safe list --json --limit 0 --all 2>/dev/null)
    if [ $? -ne 0 ] || ! echo "$ALL_TASKS_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo '{"phase":"ERROR","stats":{},"progress_pct":0,"in_progress_ids":[],"regression_count":0,"p0_bugs":0,"error":"bd list failed or returned invalid JSON"}'
        >&2 echo "bd list failed after retry"
        exit 1
    fi
    >&2 echo "bd list recovered on retry"
fi

# Filter out sub-issues created by bd set-state (audit trail entries with .N suffixed IDs)
# e.g. task-abc.1, task-abc.2 — these inflate progress counters
ALL_TASKS_JSON=$(echo "$ALL_TASKS_JSON" | jq '[.[] | select(.id | test("\\.";"x") | not)]')

# v2.3.9: Пишем tick-cache для всех скриптов (run-seniors, heal, merge queue)
# Один bd call за цикл — остальные читают из файла
echo "$ALL_TASKS_JSON" > "$PROJECT_ROOT/.hype/tick-cache.json" 2>/dev/null || true

# Статистика из кэшированных данных
OPEN=$(echo "$ALL_TASKS_JSON" | jq '[.[] | select(.status == "open") | select((.labels // []) | index("trigger") | not)] | length' 2>/dev/null || echo "0")
IN_PROGRESS=$(echo "$ALL_TASKS_JSON" | jq '[.[] | select(.status == "in_progress") | select((.labels // []) | index("trigger") | not)] | length' 2>/dev/null || echo "0")
# Exclude triggers and milestone-labeled tasks from CLOSED (consistent with OPEN/IN_PROGRESS)
CLOSED=$(echo "$ALL_TASKS_JSON" | jq '[.[] | select(.status == "closed") |
  select((.labels // []) | index("trigger") | not) |
  select((.labels // []) | any(startswith("milestone:")) | not)
] | length' 2>/dev/null || echo "0")

# Milestones — v2.3.9: файлы в .hype/ (не beads задачи)
# Backward compat: проверяем beads для проектов начатых на ≤v2.3.8
HYPE_DIR="$PROJECT_ROOT/.hype"
_check_milestone() {
    local name="$1"
    # File-based (v2.3.9+)
    if [ -f "$HYPE_DIR/milestone-${name}" ]; then echo 1; return; fi
    # Legacy: beads task with milestone label (≤v2.3.8)
    echo "$ALL_TASKS_JSON" | jq '[.[] | select(.labels[]? == "milestone:'"$name"'")] | length' 2>/dev/null || echo "0"
}
HAS_PLANNING_DONE=$(_check_milestone "planning-done")
HAS_ANALYSTS_DONE=$(_check_milestone "analysts-done")
HAS_PLAN_REVIEWED=$(_check_milestone "plan-reviewed")
HAS_PROJECT_DONE=$(_check_milestone "project-done")
HAS_TESTING_DONE=$(_check_milestone "testing-done")
HAS_VALIDATING_DONE=$(_check_milestone "validating-done")

# P0 bugs (block TESTING milestone)
# Trigger tasks have label "trigger" - exclude them from P0 bug count
# Fallback: also exclude by title pattern for backward compatibility (pre-label triggers)
P0_BUGS_OPEN=$(echo "$ALL_TASKS_JSON" | jq '[.[] |
  select(.status == "open") |
  select(.priority == 0) |
  select((.labels // []) | index("trigger") | not) |
  select(.title | test("^run-(tester|analyst|smoke|plan)-") | not) |
  select(.title | test("^run-completion$") | not)
] | length' 2>/dev/null || echo "0")

# Smoke tasks needing triage (from TESTING, need Architect review)
SMOKE_TRIAGE_OPEN=$(echo "$ALL_TASKS_JSON" | jq '[.[] | select(.status == "open") | select((.labels[]? == "smoke") or (.labels[]? == "regression"))] | length' 2>/dev/null || echo "0")
# Backward compat alias
REGRESSION_OPEN=$SMOKE_TRIAGE_OPEN

# In-progress task IDs (for show_active_work in hype.sh)
IN_PROGRESS_IDS=$(echo "$ALL_TASKS_JSON" | jq -c '[.[] | select(.status == "in_progress") | .id]' 2>/dev/null || echo "[]")

# Review pipeline counts (v2.2: tasks in reviewing/approved are in_progress but tracked separately)
REVIEWING=$(echo "$ALL_TASKS_JSON" | jq '[.[] | select(.status == "in_progress") | select((.labels // []) | index("reviewing"))] | length' 2>/dev/null || echo "0")
APPROVED=$(echo "$ALL_TASKS_JSON" | jq '[.[] | select(.status == "in_progress") | select((.labels // []) | index("approved"))] | length' 2>/dev/null || echo "0")

# Progress percentage
TOTAL=$(echo "$ALL_TASKS_JSON" | jq 'length' 2>/dev/null || echo "0")
REAL_TOTAL=$((OPEN + IN_PROGRESS + CLOSED))
if [ "$REAL_TOTAL" -gt 0 ]; then
    PROGRESS_PCT=$(( (CLOSED * 100) / REAL_TOTAL ))
else
    PROGRESS_PCT=0
fi

# Trigger tasks (из open tasks)
# Primary: detect by label (new triggers)
# Fallback: detect by title pattern (legacy triggers without label)
TRIGGERS_OPEN=$(echo "$ALL_TASKS_JSON" | jq '[.[] |
  select(.status == "open") |
  select(
    ((.labels // []) | index("trigger")) or
    (.title | test("^run-(tester|analyst|smoke|plan)-")) or
    (.title == "run-completion")
  )
] | length' 2>/dev/null || echo "0")

# Specific trigger counts (for phase logic)
ANALYST_TRIGGERS_OPEN=$(echo "$ALL_TASKS_JSON" | jq '[.[] | select(.status == "open") | select(.title | test("^run-analyst-"))] | length' 2>/dev/null || echo "0")
TESTER_TRIGGERS_OPEN=$(echo "$ALL_TASKS_JSON" | jq '[.[] | select(.status == "open") | select(.title | test("^run-tester-"))] | length' 2>/dev/null || echo "0")
THINKING_OPEN=$(echo "$ALL_TASKS_JSON" | jq '[.[] | select(.status == "open") | select(.title == "run-plan-review")] | length' 2>/dev/null || echo "0")

# === Debug output ===
if [ "${CLAUDEV_DEBUG:-false}" = "true" ]; then
    >&2 echo "=== detect-phase.sh DEBUG ==="
    >&2 echo "PROJECT_ROOT: $PROJECT_ROOT"
    >&2 echo "SPEC.md exists: $([ -f "$PROJECT_ROOT/SPEC.md" ] && echo "yes" || echo "no")"
    >&2 echo "Tasks: total=$TOTAL, open=$OPEN, in_progress=$IN_PROGRESS, closed=$CLOSED"
    >&2 echo "Milestones: planning=$HAS_PLANNING_DONE, analysts=$HAS_ANALYSTS_DONE, reviewed=$HAS_PLAN_REVIEWED, smoke=$HAS_TESTING_DONE, done=$HAS_PROJECT_DONE"
    >&2 echo "Triggers: total=$TRIGGERS_OPEN (analyst=$ANALYST_TRIGGERS_OPEN, tester=$TESTER_TRIGGERS_OPEN, plan_review=$THINKING_OPEN)"
    >&2 echo "Review pipeline: reviewing=$REVIEWING, approved=$APPROVED"
    >&2 echo "P0 bugs open: $P0_BUGS_OPEN, regressions: $REGRESSION_OPEN"
    >&2 echo "==========================="
fi

# === JSON output function ===
output_json() {
    local phase="$1"
    jq -n \
        --arg phase "$phase" \
        --argjson total "$REAL_TOTAL" \
        --argjson open "$OPEN" \
        --argjson in_progress "$IN_PROGRESS" \
        --argjson closed "$CLOSED" \
        --argjson reviewing "$REVIEWING" \
        --argjson approved "$APPROVED" \
        --argjson progress_pct "$PROGRESS_PCT" \
        --argjson in_progress_ids "$IN_PROGRESS_IDS" \
        --argjson regression_count "$REGRESSION_OPEN" \
        --argjson p0_bugs "$P0_BUGS_OPEN" \
        '{
            phase: $phase,
            stats: {
                total: $total,
                open: $open,
                in_progress: $in_progress,
                closed: $closed,
                reviewing: $reviewing,
                approved: $approved
            },
            progress_pct: $progress_pct,
            in_progress_ids: $in_progress_ids,
            regression_count: $regression_count,
            p0_bugs: $p0_bugs
        }'
}

# === Определение фазы ===

# FORCE PHASE: позволяет переместиться к любой фазе
# Используется: echo "TESTING" > .hype/force-phase
# Файл удаляется после прочтения (one-shot)
if [ -f "$PROJECT_ROOT/.hype/force-phase" ]; then
    FORCED_PHASE=$(cat "$PROJECT_ROOT/.hype/force-phase" | tr -d '[:space:]')
    rm -f "$PROJECT_ROOT/.hype/force-phase"
    if [ -n "$FORCED_PHASE" ]; then
        output_json "$FORCED_PHASE"
        exit 0
    fi
fi

# PREPARING: нужен Tech Writer для сбора требований
# Условия:
#   1. Нет SPEC.md (новый проект)
#   2. Есть milestone:project-done (итерация завершена, начинаем новую)
#   3. Beads пустой + есть .hype/needs-spec (после cleanup завершённой итерации)
if [ ! -f "$PROJECT_ROOT/SPEC.md" ]; then
    output_json "PREPARING"
    exit 0
fi

if [ "$HAS_PROJECT_DONE" -gt 0 ]; then
    # Итерация завершена → DONE, hype.sh завершит работу
    output_json "DONE"
    exit 0
fi

if [ "$TOTAL" -eq 0 ] && [ "$CLOSED" -eq 0 ]; then
    # v2.3.9: Если есть файловые milestones — bd вернул пустой ответ, не новый проект
    if [ "$HAS_PLANNING_DONE" -gt 0 ]; then
        >&2 echo "ERROR: bd returned 0 tasks but milestones exist — bd returned empty response"
        output_json "ERROR"
        exit 1
    fi
    if [ -f "$PROJECT_ROOT/.hype/needs-spec" ]; then
        # После завершённой итерации, нужен новый SPEC
        output_json "PREPARING"
    else
        # SPEC только создан, Architect должен создать план
        output_json "PLANNING"
    fi
    exit 0
fi

# PLANNING: есть SPEC.md, есть задачи, но нет плана (milestone:planning-done)
if [ "$HAS_PLANNING_DONE" -eq 0 ]; then
    output_json "PLANNING"
    exit 0
fi

# ANALYZE (Analysts): план есть, но analysts не завершили
if [ "$HAS_ANALYSTS_DONE" -eq 0 ]; then
    output_json "ANALYZE"
    exit 0
fi

# SELF-HEALING: Check for premature milestone (triggers still pending)
# Race condition: milestone created while trigger was in_progress, then timeout reset it to open
PENDING_ANALYST_TRIGGERS=$(echo "$ALL_TASKS_JSON" | jq '[.[] | select(.status == "open" or .status == "in_progress") | select(.title | test("^run-analyst-"))] | length' 2>/dev/null || echo "0")
if [ "$PENDING_ANALYST_TRIGGERS" -gt 0 ] && [ "$HAS_ANALYSTS_DONE" -gt 0 ]; then
    >&2 echo "SELF-HEAL: Removing premature milestone:analysts-done ($PENDING_ANALYST_TRIGGERS triggers pending)"
    # v2.3.9: delete file milestone (+ legacy bd cleanup)
    rm -f "$HYPE_DIR/milestone-analysts-done" 2>/dev/null || true
    MILESTONE_IDS=$(echo "$ALL_TASKS_JSON" | jq -r '.[] | select(.labels[]? == "milestone:analysts-done") | .id' 2>/dev/null || true)
    for mid in $MILESTONE_IDS; do
        bd_safe update "$mid" --remove-label="milestone:analysts-done" >/dev/null 2>&1 || true
    done
    output_json "ANALYZE"
    exit 0
fi

# THINKING: analysts закончили, Architect ревьюит
if [ "$HAS_PLAN_REVIEWED" -eq 0 ]; then
    output_json "THINKING"
    exit 0
fi

# CONSULTATION: tasks with user-escalation label need human decision
# Takes priority over REFLEXING and CODING — daemon stops until user acts
USER_ESCALATION_COUNT=$(echo "$ALL_TASKS_JSON" | jq '[.[] | select(.status == "open") | select((.labels // []) | index("user-escalation"))] | length' 2>/dev/null || echo "0")
if [ "$USER_ESCALATION_COUNT" -gt 0 ]; then
    output_json "CONSULTATION"
    exit 0
fi

# TESTING: testers actively running — stay in TESTING regardless of new tasks
# v2.3.13: prevents phase switch to CODING while testers create findings
TESTERS_PID_FILE="$PROJECT_ROOT/.hype/run-testers.pid"
if [ -f "$TESTERS_PID_FILE" ] && kill -0 "$(cat "$TESTERS_PID_FILE" 2>/dev/null)" 2>/dev/null; then
    output_json "TESTING"
    exit 0
fi

# REFLEXING: smoke/regression tasks найдены - Architect триажит перед coders
# Предотвращает race condition между Architect и Coder
# Reached only when testers are NOT running (PID check above)
if [ "$SMOKE_TRIAGE_OPEN" -gt 0 ]; then
    output_json "REFLEXING"
    exit 0
fi

# TESTING via triggers: все реальные задачи закрыты, есть только tester trigger tasks
# Это позволяет run-testers.sh подхватить trigger и запустить tester agent
if [ "$TESTER_TRIGGERS_OPEN" -gt 0 ] && [ "$IN_PROGRESS" -eq 0 ]; then
    # Проверяем что ВСЕ open задачи - это trigger tasks (не реальная работа)
    # Use label-based detection with fallback to title patterns
    NON_TRIGGER_OPEN=$(echo "$ALL_TASKS_JSON" | jq '[.[] |
      select(.status == "open") |
      select(
        ((.labels // []) | index("trigger") | not) and
        (.title | test("^run-(tester|analyst|smoke|plan)-") | not) and
        (.title != "run-completion")
      )
    ] | length' 2>/dev/null || echo "0")

    if [ "$NON_TRIGGER_OPEN" -eq 0 ] && [ "$HAS_TESTING_DONE" -eq 0 ]; then
        output_json "TESTING"
        exit 0
    fi
fi

# CODING: есть открытые или in_progress задачи
if [ "$OPEN" -gt 0 ] || [ "$IN_PROGRESS" -gt 0 ]; then
    # Safety net: проверяем циклы перед началом реализации
    cycles_output=$(bd_safe dep cycles 2>&1 || true)
    if echo "$cycles_output" | grep -q "→"; then
        output_json "BLOCKED_CYCLES"
        >&2 echo "Dependency cycles detected! Fix before implementation."
        >&2 echo "$cycles_output"
        exit 0  # exit 0 чтобы HYPE не добавил "UNKNOWN"
    fi
    output_json "CODING"
    exit 0
fi

# TESTING: все задачи closed, но smoke test не пройден
# P0 bugs возвращают в CODING для фикса
if [ "$CLOSED" -gt 0 ] && [ "$OPEN" -eq 0 ] && [ "$IN_PROGRESS" -eq 0 ]; then
    if [ "$HAS_TESTING_DONE" -eq 0 ]; then
        # P0 bugs block smoke test - return to CODING
        if [ "$P0_BUGS_OPEN" -gt 0 ]; then
            >&2 echo "P0 bugs found ($P0_BUGS_OPEN), returning to CODING"
            output_json "CODING"
            exit 0
        fi
        output_json "TESTING"
        exit 0
    fi
    # Smoke test passed → check if validation done
    if [ "$HAS_VALIDATING_DONE" -eq 0 ]; then
        output_json "VALIDATING"
        exit 0
    fi
    # Validation passed → REPORTING (completion agent)
    output_json "REPORTING"
    exit 0
fi

# UNKNOWN: не удалось определить
output_json "UNKNOWN"
>&2 echo "Stats: total=$TOTAL, open=$OPEN, in_progress=$IN_PROGRESS, closed=$CLOSED"
>&2 echo "Milestones: planning=$HAS_PLANNING_DONE, analysts=$HAS_ANALYSTS_DONE, reviewed=$HAS_PLAN_REVIEWED, done=$HAS_PROJECT_DONE"
exit 1
