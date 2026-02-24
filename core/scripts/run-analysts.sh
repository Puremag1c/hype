#!/bin/bash
# core/scripts/run-analysts.sh
# Запускает 5 Analyst агентов параллельно.
# Каждый analyst claim своей trigger-задачи и закрывает её по завершении.
#
# Analysts: ux, security, ops, reliability, architecture
#
# Использование: ./scripts/run-analysts.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

PROJECT_DIR=$(pwd)
LOGS_DIR="$PROJECT_DIR/logs"
CONFIG_FILE="$PROJECT_DIR/.hype/config.sh"

# Load config
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

ANALYST_TIMEOUT="${ANALYST_TIMEOUT:-10m}"
# bd_safe is provided by common.sh with flock serialization

mkdir -p "$LOGS_DIR"

log() {
    local level=$1
    local msg=$2
    local color="" reset="\033[0m" gray="\033[90m"
    # HYPE brand colors (neon pink gradient)
    local hype_colored="\033[38;2;255;0;102mH\033[38;2;255;51;153mY\033[38;2;255;102;204mP\033[38;2;204;255;0mE\033[0m"

    case "$level" in
        INFO)  color="\033[32m" ;;  # green
        WARN)  color="\033[33m" ;;  # yellow
        ERROR) color="\033[31m" ;;  # red
    esac

    printf "${gray}%s${reset} [${hype_colored} ANALYZE] ${color}%s${reset}: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [HYPE ANALYZE] $level: $msg" >> "$LOGS_DIR/hype.log"
}

# All analysts
ANALYSTS=("ux" "security" "ops" "reliability" "architecture")

# Run single analyst
run_analyst() {
    local analyst=$1
    local bd_cache=$2  # Cached bd list --json (v1.9.0+)
    local trigger_task="run-analyst-$analyst"
    local agent_file=".claude/agents/analyst-$analyst.md"

    log "INFO" "Starting analyst-$analyst"

    # Find trigger task from cache
    local task_id
    # v2.4.5: filter by status=open to avoid picking stale duplicate triggers
    task_id=$(echo "$bd_cache" | jq -r ".[] | select(.status == \"open\") | select(.title == \"$trigger_task\") | .id" | head -1 || echo "")

    if [ -z "$task_id" ]; then
        log "WARN" "No trigger task for analyst-$analyst"
        return 0
    fi

    # Claim trigger task
    if ! bd_safe update "$task_id" --status=in_progress >/dev/null 2>&1; then
        log "INFO" "Trigger $trigger_task already claimed"
        return 0
    fi

    # Check if agent file exists
    if [ ! -f "$agent_file" ]; then
        log "WARN" "Agent file not found: $agent_file"
        bd_safe close "$task_id" --reason="Agent file not found" >/dev/null 2>&1
        return 0
    fi

    # Run analyst with timeout (with tool use enabled)
    local output_file="$LOGS_DIR/analyst-$analyst.log"
    local analyst_prompt
    analyst_prompt=$(cat "$agent_file" 2>/dev/null)

    # Read SPEC.md for scope context
    local spec_content
    spec_content=$(cat "$PROJECT_DIR/SPEC.md" 2>/dev/null || echo "SPEC.md not found")

    # Calculate plan size (exclude milestones, triggers, analyst tasks)
    local plan_size max_tasks
    plan_size=$(echo "$bd_cache" | jq '[.[] | select(.title | test("^run-|^milestone:") | not)] | length' 2>/dev/null || echo "5")
    if [ "$plan_size" -le 10 ]; then
        max_tasks=2
    elif [ "$plan_size" -le 25 ]; then
        max_tasks=3
    else
        max_tasks=5
    fi

    local full_prompt="$analyst_prompt

---
ANALYST: $analyst
TRIGGER_TASK: $task_id
PROJECT_ROOT: $PROJECT_DIR

## TASK BUDGET: $max_tasks
Current plan has $plan_size tasks. You may create **at most $max_tasks tasks**.
Only P0-P1 gaps that would block MVP. Skip nice-to-haves.

## SCOPE (SPEC.md):
$spec_content"

    # Run analyst with real-time progress logging
    local analyst_model
    analyst_model=$(map_model "${MODEL_ANALYSTS:-sonnet}")

    # Use || to prevent set -e from killing script on timeout/failure
    local exit_code=0
    run_claude_with_progress "$full_prompt" "$analyst_model" "$ANALYST_TIMEOUT" "$output_file" "ANALYST $analyst" "$LOGS_DIR" || exit_code=$?

    if [ $exit_code -ne 0 ]; then
        # Check if trigger was already closed before reset
        # (agent may have closed it right before timeout killed the process)
        local current_status
        current_status=$(bd_safe show "$task_id" --json 2>/dev/null | jq -r '.[0].status // "unknown"' 2>/dev/null || echo "unknown")

        if [ "$current_status" = "closed" ]; then
            log "INFO" "Analyst $analyst timeout, but trigger already closed"
            return 0
        fi

        if [ $exit_code -eq 124 ]; then
            log "WARN" "Analyst $analyst timeout"
            bd_safe update "$task_id" --status=open --notes="Timeout at $(date '+%Y-%m-%d %H:%M:%S')" >/dev/null 2>&1
        else
            log "ERROR" "Analyst $analyst failed (exit: $exit_code)"
            bd_safe update "$task_id" --status=open --notes="Failed (exit: $exit_code)" >/dev/null 2>&1
        fi
        return 0
    fi

    # Close trigger task (v2.4.5: check return code, retry on failure)
    if bd_safe close "$task_id" --reason="Analyst $analyst completed" 2>/dev/null; then
        log "INFO" "Analyst $analyst completed"
    else
        log "WARN" "Analyst $analyst trigger close failed, retrying..."
        sleep 1
        if bd_safe close "$task_id" --reason="Analyst $analyst completed (retry)" 2>/dev/null; then
            log "INFO" "Analyst $analyst completed (close retried)"
        else
            log "ERROR" "Analyst $analyst trigger close FAILED after retry: $task_id"
        fi
    fi
}

# Main
main() {
    # Visual separation (terminal + file)
    echo ""
    echo "" >> "$LOGS_DIR/hype.log"
    log "INFO" "ANALYZE: ${ANALYSTS[*]}"

    # Cache bd list at start (v1.9.0 optimization)
    local bd_cache
    bd_cache=$(bd_safe list --json --limit 0 2>/dev/null || echo "[]")

    # Check that all trigger tasks exist (using cache)
    local missing=0
    for analyst in "${ANALYSTS[@]}"; do
        if ! echo "$bd_cache" | jq -e ".[] | select(.title == \"run-analyst-$analyst\")" > /dev/null 2>&1; then
            log "WARN" "Trigger task run-analyst-$analyst not found"
            ((missing++)) || true
        fi
    done

    if [ "$missing" -eq "${#ANALYSTS[@]}" ]; then
        log "ERROR" "No trigger tasks found. Create them first."
        exit 1
    fi

    # Run all analysts in parallel (pass cache)
    for analyst in "${ANALYSTS[@]}"; do
        run_analyst "$analyst" "$bd_cache" &
    done

    # Wait for all
    wait

    # Check completion status (milestone created by HYPE)
    local open_triggers
    open_triggers=$(bd_safe list --status=open --json --limit 0 2>/dev/null | jq '[.[] | select(.title | startswith("run-analyst-"))] | length' 2>/dev/null || echo "0")

    if [ "$open_triggers" -eq 0 ]; then
        log "INFO" "All analysts completed"
    else
        log "INFO" "Some analysts still open ($open_triggers remaining)"
    fi

    # Dolt auto-commits — no sync needed since v0.51
    log "INFO" "ANALYZE FINISHED"
}

main "$@"
