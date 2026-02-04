#!/bin/bash
# core/scripts/detect-phase.sh
# Определяет текущую фазу проекта из состояния Beads и файлов.
#
# Фазы: INIT → PLANNING → HELPERS → PLAN_REVIEW → IMPLEMENTATION → FINAL_REVIEW → DONE
#        IDLE — проект существует, но нет активной работы (требует решения пользователя)
#
# Использование: ./scripts/detect-phase.sh
# Выводит: PHASE_NAME (одно слово, для использования в скриптах)

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
    echo "ERROR"
    >&2 echo "Beads (bd) не установлен"
    exit 1
fi

# Собираем статистику из beads (batched - 2 запроса вместо 11)
# Кэшируем JSON для всех фильтров через jq
ALL_TASKS_JSON=$(bd list --json 2>/dev/null || echo "[]")
CLOSED_TASKS_JSON=$(bd list --status=closed --json 2>/dev/null || echo "[]")

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

# Trigger tasks для analysts (из open tasks)
ANALYST_TRIGGERS_OPEN=$(echo "$ALL_TASKS_JSON" | jq '[.[] | select(.status == "open") | select(.title | test("^run-analyst-"))] | length' 2>/dev/null || echo "0")
PLAN_REVIEW_OPEN=$(echo "$ALL_TASKS_JSON" | jq '[.[] | select(.status == "open") | select(.title == "run-plan-review")] | length' 2>/dev/null || echo "0")

# === Debug output ===
if [ "${CLAUDEV_DEBUG:-false}" = "true" ]; then
    >&2 echo "=== detect-phase.sh DEBUG ==="
    >&2 echo "PROJECT_ROOT: $PROJECT_ROOT"
    >&2 echo "SPEC.md exists: $([ -f "$PROJECT_ROOT/SPEC.md" ] && echo "yes" || echo "no")"
    >&2 echo "Tasks: total=$TOTAL, open=$OPEN, in_progress=$IN_PROGRESS, closed=$CLOSED"
    >&2 echo "Milestones: planning=$HAS_PLANNING_DONE, analysts=$HAS_ANALYSTS_DONE, reviewed=$HAS_PLAN_REVIEWED, done=$HAS_PROJECT_DONE"
    >&2 echo "Triggers: analyst_open=$ANALYST_TRIGGERS_OPEN, plan_review=$PLAN_REVIEW_OPEN"
    >&2 echo "==========================="
fi

# === Определение фазы ===

# INIT: нужен Tech Writer для сбора требований
# Условия:
#   1. Нет SPEC.md (новый проект)
#   2. Есть milestone:project-done (итерация завершена, начинаем новую)
#   3. Beads пустой + есть .hype/needs-spec (после cleanup завершённой итерации)
if [ ! -f "$PROJECT_ROOT/SPEC.md" ]; then
    echo "INIT"
    exit 0
fi

if [ "$HAS_PROJECT_DONE" -gt 0 ]; then
    # Итерация завершена → DONE, hype.sh завершит работу
    echo "DONE"
    exit 0
fi

if [ "$TOTAL" -eq 0 ] && [ "$CLOSED" -eq 0 ]; then
    if [ -f "$PROJECT_ROOT/.hype/needs-spec" ]; then
        # После завершённой итерации, нужен новый SPEC
        echo "INIT"
    else
        # SPEC только создан, Architect должен создать план
        echo "PLANNING"
    fi
    exit 0
fi

# PLANNING: есть SPEC.md, есть задачи, но нет плана (milestone:planning-done)
if [ "$HAS_PLANNING_DONE" -eq 0 ]; then
    echo "PLANNING"
    exit 0
fi

# HELPERS (Analysts): план есть, но analysts не завершили
if [ "$HAS_ANALYSTS_DONE" -eq 0 ]; then
    echo "HELPERS"
    exit 0
fi

# PLAN_REVIEW: analysts закончили, Architect ревьюит
if [ "$HAS_PLAN_REVIEWED" -eq 0 ]; then
    echo "PLAN_REVIEW"
    exit 0
fi

# IMPLEMENTATION: есть открытые или in_progress задачи
if [ "$OPEN" -gt 0 ] || [ "$IN_PROGRESS" -gt 0 ]; then
    # Safety net: проверяем циклы перед началом реализации
    # NOTE: "bd dep cycles" outputs "✓ No dependency cycles detected" when clean
    # We check for actual cycle output (contains "→" arrow) not just word "cycle"
    cycles_output=$(bd dep cycles 2>&1 || true)
    if echo "$cycles_output" | grep -q "→"; then
        echo "BLOCKED_CYCLES"
        >&2 echo "Dependency cycles detected! Fix before implementation."
        >&2 echo "$cycles_output"
        exit 0  # exit 0 чтобы HYPE не добавил "UNKNOWN"
    fi
    echo "IMPLEMENTATION"
    exit 0
fi

# FINAL_REVIEW: все задачи closed, финальная проверка
if [ "$CLOSED" -gt 0 ] && [ "$OPEN" -eq 0 ] && [ "$IN_PROGRESS" -eq 0 ]; then
    echo "FINAL_REVIEW"
    exit 0
fi

# UNKNOWN: не удалось определить
echo "UNKNOWN"
>&2 echo "Stats: total=$TOTAL, open=$OPEN, in_progress=$IN_PROGRESS, closed=$CLOSED"
>&2 echo "Milestones: planning=$HAS_PLANNING_DONE, analysts=$HAS_ANALYSTS_DONE, reviewed=$HAS_PLAN_REVIEWED, done=$HAS_PROJECT_DONE"
exit 1
