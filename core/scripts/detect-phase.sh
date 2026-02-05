#!/bin/bash
# core/scripts/detect-phase.sh
# Определяет текущую фазу проекта из состояния Beads и файлов.
#
# Фазы: INIT → PLANNING → HELPERS → PLAN_REVIEW → [SMOKE_REVIEW] → IMPLEMENTATION → SMOKE_TEST → FINAL_REVIEW → DONE
#        SMOKE_REVIEW — срабатывает когда есть regression tasks (после SMOKE_TEST нашёл баги)
#        IDLE — проект существует, но нет активной работы (требует решения пользователя)
#
# Использование: ./scripts/detect-phase.sh
# Выводит: JSON с phase и метаданными (v1.9.0+)
#
# Формат вывода:
# {
#   "phase": "IMPLEMENTATION",
#   "stats": { "total": 55, "open": 3, "in_progress": 2, "closed": 50 },
#   "progress_pct": 91,
#   "in_progress_ids": ["beads-abc", "beads-def"],
#   "regression_count": 0,
#   "p0_bugs": 0
# }

set -euo pipefail

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

# Собираем статистику из beads (batched - 2 запроса вместо 11)
# Кэшируем JSON для всех фильтров через jq
# ВАЖНО: --limit 0 для unlimited (по умолчанию 50, что ломает milestone detection)
ALL_TASKS_JSON=$(bd list --json --limit 0 2>/dev/null || echo "[]")
CLOSED_TASKS_JSON=$(bd list --status=closed --json --limit 0 2>/dev/null || echo "[]")

# Статистика из кэшированных данных
TOTAL=$(echo "$ALL_TASKS_JSON" | jq 'length' 2>/dev/null || echo "0")
OPEN=$(echo "$ALL_TASKS_JSON" | jq '[.[] | select(.status == "open")] | length' 2>/dev/null || echo "0")
IN_PROGRESS=$(echo "$ALL_TASKS_JSON" | jq '[.[] | select(.status == "in_progress")] | length' 2>/dev/null || echo "0")
CLOSED=$(echo "$CLOSED_TASKS_JSON" | jq 'length' 2>/dev/null || echo "0")

# Milestones (из closed tasks)
HAS_PLANNING_DONE=$(echo "$CLOSED_TASKS_JSON" | jq '[.[] | select(.labels[]? == "milestone:planning-done")] | length' 2>/dev/null || echo "0")
HAS_ANALYSTS_DONE=$(echo "$CLOSED_TASKS_JSON" | jq '[.[] | select(.labels[]? == "milestone:analysts-done")] | length' 2>/dev/null || echo "0")
HAS_PLAN_REVIEWED=$(echo "$CLOSED_TASKS_JSON" | jq '[.[] | select(.labels[]? == "milestone:plan-reviewed")] | length' 2>/dev/null || echo "0")
HAS_PROJECT_DONE=$(echo "$CLOSED_TASKS_JSON" | jq '[.[] | select(.labels[]? == "milestone:project-done")] | length' 2>/dev/null || echo "0")
HAS_SMOKE_TEST_DONE=$(echo "$CLOSED_TASKS_JSON" | jq '[.[] | select(.labels[]? == "milestone:smoke-test-done")] | length' 2>/dev/null || echo "0")

# P0 bugs (block SMOKE_TEST milestone)
P0_BUGS_OPEN=$(echo "$ALL_TASKS_JSON" | jq '[.[] | select(.status == "open") | select(.priority == 0)] | length' 2>/dev/null || echo "0")

# Regression tasks (from SMOKE_TEST, need Architect review)
REGRESSION_OPEN=$(echo "$ALL_TASKS_JSON" | jq '[.[] | select(.status == "open") | select(.labels[]? == "regression")] | length' 2>/dev/null || echo "0")

# In-progress task IDs (for show_active_work in hype.sh)
IN_PROGRESS_IDS=$(echo "$ALL_TASKS_JSON" | jq -c '[.[] | select(.status == "in_progress") | .id]' 2>/dev/null || echo "[]")

# Progress percentage (TOTAL from ALL_TASKS doesn't include closed, so calculate real total)
REAL_TOTAL=$((OPEN + IN_PROGRESS + CLOSED))
if [ "$REAL_TOTAL" -gt 0 ]; then
    PROGRESS_PCT=$(( (CLOSED * 100) / REAL_TOTAL ))
else
    PROGRESS_PCT=0
fi

# Trigger tasks для analysts (из open tasks)
ANALYST_TRIGGERS_OPEN=$(echo "$ALL_TASKS_JSON" | jq '[.[] | select(.status == "open") | select(.title | test("^run-analyst-"))] | length' 2>/dev/null || echo "0")
PLAN_REVIEW_OPEN=$(echo "$ALL_TASKS_JSON" | jq '[.[] | select(.status == "open") | select(.title == "run-plan-review")] | length' 2>/dev/null || echo "0")

# === Debug output ===
if [ "${CLAUDEV_DEBUG:-false}" = "true" ]; then
    >&2 echo "=== detect-phase.sh DEBUG ==="
    >&2 echo "PROJECT_ROOT: $PROJECT_ROOT"
    >&2 echo "SPEC.md exists: $([ -f "$PROJECT_ROOT/SPEC.md" ] && echo "yes" || echo "no")"
    >&2 echo "Tasks: total=$TOTAL, open=$OPEN, in_progress=$IN_PROGRESS, closed=$CLOSED"
    >&2 echo "Milestones: planning=$HAS_PLANNING_DONE, analysts=$HAS_ANALYSTS_DONE, reviewed=$HAS_PLAN_REVIEWED, smoke=$HAS_SMOKE_TEST_DONE, done=$HAS_PROJECT_DONE"
    >&2 echo "Triggers: analyst_open=$ANALYST_TRIGGERS_OPEN, plan_review=$PLAN_REVIEW_OPEN"
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
                closed: $closed
            },
            progress_pct: $progress_pct,
            in_progress_ids: $in_progress_ids,
            regression_count: $regression_count,
            p0_bugs: $p0_bugs
        }'
}

# === Определение фазы ===

# FORCE PHASE: позволяет переместиться к любой фазе
# Используется: echo "SMOKE_TEST" > .hype/force-phase
# Файл удаляется после прочтения (one-shot)
if [ -f "$PROJECT_ROOT/.hype/force-phase" ]; then
    FORCED_PHASE=$(cat "$PROJECT_ROOT/.hype/force-phase" | tr -d '[:space:]')
    rm -f "$PROJECT_ROOT/.hype/force-phase"
    if [ -n "$FORCED_PHASE" ]; then
        output_json "$FORCED_PHASE"
        exit 0
    fi
fi

# INIT: нужен Tech Writer для сбора требований
# Условия:
#   1. Нет SPEC.md (новый проект)
#   2. Есть milestone:project-done (итерация завершена, начинаем новую)
#   3. Beads пустой + есть .hype/needs-spec (после cleanup завершённой итерации)
if [ ! -f "$PROJECT_ROOT/SPEC.md" ]; then
    output_json "INIT"
    exit 0
fi

if [ "$HAS_PROJECT_DONE" -gt 0 ]; then
    # Итерация завершена → DONE, hype.sh завершит работу
    output_json "DONE"
    exit 0
fi

if [ "$TOTAL" -eq 0 ] && [ "$CLOSED" -eq 0 ]; then
    if [ -f "$PROJECT_ROOT/.hype/needs-spec" ]; then
        # После завершённой итерации, нужен новый SPEC
        output_json "INIT"
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

# HELPERS (Analysts): план есть, но analysts не завершили
if [ "$HAS_ANALYSTS_DONE" -eq 0 ]; then
    output_json "HELPERS"
    exit 0
fi

# PLAN_REVIEW: analysts закончили, Architect ревьюит
if [ "$HAS_PLAN_REVIEWED" -eq 0 ]; then
    output_json "PLAN_REVIEW"
    exit 0
fi

# SMOKE_REVIEW: regression tasks найдены - Architect обрабатывает перед executors
# Предотвращает race condition между Architect и Executor
if [ "$REGRESSION_OPEN" -gt 0 ]; then
    output_json "SMOKE_REVIEW"
    exit 0
fi

# IMPLEMENTATION: есть открытые или in_progress задачи
if [ "$OPEN" -gt 0 ] || [ "$IN_PROGRESS" -gt 0 ]; then
    # Safety net: проверяем циклы перед началом реализации
    cycles_output=$(bd dep cycles 2>&1 || true)
    if echo "$cycles_output" | grep -q "→"; then
        output_json "BLOCKED_CYCLES"
        >&2 echo "Dependency cycles detected! Fix before implementation."
        >&2 echo "$cycles_output"
        exit 0  # exit 0 чтобы HYPE не добавил "UNKNOWN"
    fi
    output_json "IMPLEMENTATION"
    exit 0
fi

# SMOKE_TEST: все задачи closed, но smoke test не пройден
# P0 bugs возвращают в IMPLEMENTATION для фикса
if [ "$CLOSED" -gt 0 ] && [ "$OPEN" -eq 0 ] && [ "$IN_PROGRESS" -eq 0 ]; then
    if [ "$HAS_SMOKE_TEST_DONE" -eq 0 ]; then
        # P0 bugs block smoke test - return to IMPLEMENTATION
        if [ "$P0_BUGS_OPEN" -gt 0 ]; then
            >&2 echo "P0 bugs found ($P0_BUGS_OPEN), returning to IMPLEMENTATION"
            output_json "IMPLEMENTATION"
            exit 0
        fi
        output_json "SMOKE_TEST"
        exit 0
    fi
    # Smoke test passed → FINAL_REVIEW
    output_json "FINAL_REVIEW"
    exit 0
fi

# UNKNOWN: не удалось определить
output_json "UNKNOWN"
>&2 echo "Stats: total=$TOTAL, open=$OPEN, in_progress=$IN_PROGRESS, closed=$CLOSED"
>&2 echo "Milestones: planning=$HAS_PLANNING_DONE, analysts=$HAS_ANALYSTS_DONE, reviewed=$HAS_PLAN_REVIEWED, done=$HAS_PROJECT_DONE"
exit 1
