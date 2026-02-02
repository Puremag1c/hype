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

TASK_TIMEOUT="${TASK_TIMEOUT:-10m}"

mkdir -p "$LOGS_DIR"

log() {
    local level=$1
    local msg=$2
    local color=""
    local reset="\033[0m"

    case "$level" in
        INFO)  color="\033[32m" ;;  # green
        WARN)  color="\033[33m" ;;  # yellow
        ERROR) color="\033[31m" ;;  # red
    esac

    # Colored output to terminal, plain to log file
    printf "${color}%s [RUN-ANALYSTS] %s: %s${reset}\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [RUN-ANALYSTS] $level: $msg" >> "$LOGS_DIR/hype.log"
}

# All analysts
ANALYSTS=("ux" "security" "ops" "reliability" "architecture")

# Run single analyst
run_analyst() {
    local analyst=$1
    local trigger_task="run-analyst-$analyst"
    local agent_file=".claude/agents/analyst-$analyst.md"

    log "INFO" "Starting analyst-$analyst"

    # Find trigger task
    local task_id
    task_id=$(bd list --json 2>/dev/null | jq -r ".[] | select(.title == \"$trigger_task\") | .id" | head -1)

    if [ -z "$task_id" ]; then
        log "WARN" "No trigger task for analyst-$analyst"
        return 0
    fi

    # Claim trigger task
    if ! bd update "$task_id" --status=in_progress >/dev/null 2>&1; then
        log "INFO" "Trigger $trigger_task already claimed"
        return 0
    fi

    # Check if agent file exists
    if [ ! -f "$agent_file" ]; then
        log "WARN" "Agent file not found: $agent_file"
        bd close "$task_id" --reason="Agent file not found" >/dev/null 2>&1
        return 0
    fi

    # Run analyst with timeout (with tool use enabled)
    local output_file="$LOGS_DIR/analyst-$analyst.log"
    local analyst_prompt
    analyst_prompt=$(cat "$agent_file" 2>/dev/null)

    # Read SPEC.md for scope context
    local spec_content
    spec_content=$(cat "$PROJECT_DIR/SPEC.md" 2>/dev/null || echo "SPEC.md not found")

    local full_prompt="$analyst_prompt

---
ANALYST: $analyst
TRIGGER_TASK: $task_id
PROJECT_ROOT: $PROJECT_DIR

## SCOPE (SPEC.md):
$spec_content"

    # Use stdin to avoid issues with prompts starting with "---"
    # Streaming: tee for real-time logs, strip_ansi removes terminal garbage
    set -o pipefail
    if ! printf '%s' "$full_prompt" | timeout_cmd "$TASK_TIMEOUT" claude --model sonnet 2>&1 | strip_ansi | tee "$output_file" >/dev/null; then
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            log "WARN" "Analyst $analyst timeout"
            bd update "$task_id" --status=open --notes="Timeout at $(date '+%Y-%m-%d %H:%M:%S')" >/dev/null 2>&1
        else
            log "ERROR" "Analyst $analyst failed (exit: $exit_code)"
            bd update "$task_id" --status=open --notes="Failed (exit: $exit_code)" >/dev/null 2>&1
        fi
        return 0
    fi
    set +o pipefail

    # Close trigger task
    bd close "$task_id" --reason="Analyst $analyst completed" >/dev/null 2>&1
    log "INFO" "Analyst $analyst completed"
}

# Main
main() {
    # Visual separation (terminal + file)
    echo ""
    echo "" >> "$LOGS_DIR/hype.log"
    log "INFO" "RUN-ANALYSTS: ${ANALYSTS[*]}"

    # Check that all trigger tasks exist
    local missing=0
    for analyst in "${ANALYSTS[@]}"; do
        if ! bd list --json 2>/dev/null | jq -e ".[] | select(.title == \"run-analyst-$analyst\")" > /dev/null 2>&1; then
            log "WARN" "Trigger task run-analyst-$analyst not found"
            ((missing++)) || true
        fi
    done

    if [ "$missing" -eq "${#ANALYSTS[@]}" ]; then
        log "ERROR" "No trigger tasks found. Create them first."
        exit 1
    fi

    # Run all analysts in parallel
    for analyst in "${ANALYSTS[@]}"; do
        run_analyst "$analyst" &
    done

    # Wait for all
    wait

    # Check completion status (milestone created by orchestrator)
    local open_triggers
    open_triggers=$(bd list --status=open --json 2>/dev/null | jq '[.[] | select(.title | startswith("run-analyst-"))] | length' 2>/dev/null || echo "0")

    if [ "$open_triggers" -eq 0 ]; then
        log "INFO" "All analysts completed"
    else
        log "INFO" "Some analysts still open ($open_triggers remaining)"
    fi

    # Sync only if daemon is not running (daemon auto-syncs)
    if ! bd sync --status 2>/dev/null | grep -q "auto-commit.*enabled"; then
        bd sync 2>/dev/null || true
    fi
    log "INFO" "RUN-ANALYSTS FINISHED"
}

main "$@"
