#!/bin/bash
# core/scripts/run-senior-executor.sh
# Обрабатывает задачи с label=needs-review через Senior Executor агента.
# Работает ПОСЛЕДОВАТЕЛЬНО — один PR за раз (quality gate).
#
# Использование: ./scripts/run-senior-executor.sh

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
    local color="" reset="\033[0m" gray="\033[90m"

    case "$level" in
        INFO|SUCCESS)  color="\033[32m" ;;
        WARN)          color="\033[33m" ;;
        ERROR|FATAL)   color="\033[31m" ;;
        TASK_START)    color="\033[36m" ;;
    esac

    printf "${gray}%s${reset} [HYPE CHECK] ${color}%s${reset}: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [HYPE CHECK] $level: $msg" >> "$LOGS_DIR/hype.log"
}

# === Get tasks needing review ===

get_review_tasks() {
    # Tasks with label=needs-review but WITHOUT executor label
    # (executor label means task is being worked on, not ready for review)
    bd list --status=in_progress --json 2>/dev/null | \
        jq -r '.[] | select((.labels | index("needs-review")) and ((.labels | index("executor")) | not)) | .id' 2>/dev/null || true
}

# === Process single review task ===

process_review() {
    local task_id=$1

    log "INFO" "Processing review for $task_id"

    # Get task details
    local task_json
    task_json=$(bd show "$task_id" --json 2>/dev/null || echo "[]")

    # Validate task exists (race condition protection)
    local task_title
    task_title=$(echo "$task_json" | jq -r '.[0].title // empty' 2>/dev/null || true)

    if [ -z "$task_title" ]; then
        log "WARN" "Task $task_id not found or invalid (race condition?), skipping"
        return 0
    fi

    # Check if senior-executor agent exists
    local agent_file=".claude/agents/senior-executor.md"
    local agent_prompt
    if [ -f "$agent_file" ]; then
        agent_prompt=$(cat "$agent_file")
    else
        agent_prompt="# Senior Executor
You are a senior developer doing code review.
Review the code, check for issues, and either approve or request changes.
If approved, mark the task as complete with bd close."
    fi

    # Run senior executor (with tool use enabled)
    local output_file="$LOGS_DIR/senior-executor-$task_id.log"

    local full_prompt="$agent_prompt

---
TASK_ID: $task_id
PROJECT_ROOT: $PROJECT_DIR
ACTION: Review and merge if ready"

    # Use stdin to avoid issues with prompts starting with "---"
    # Streaming: tee for real-time logs, strip_ansi removes terminal garbage
    set -o pipefail
    if printf '%s' "$full_prompt" | timeout_cmd "$TASK_TIMEOUT" claude --model opus 2>&1 | strip_ansi | tee "$output_file" >/dev/null; then
        log "INFO" "Review completed for $task_id"
    else
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            log "WARN" "Review timeout for $task_id"
        else
            log "ERROR" "Review failed for $task_id (exit: $exit_code)"
        fi
    fi
    set +o pipefail

    # Always cleanup: if task is closed, remove needs-review label
    # (Claude might have closed task before crashing)
    local task_status
    task_status=$(bd show "$task_id" --json 2>/dev/null | jq -r '.[0].status // "unknown"' 2>/dev/null || echo "unknown")

    if [ "$task_status" = "closed" ]; then
        log "INFO" "Task $task_id is closed, cleaning up labels"
        bd update "$task_id" --remove-label needs-review --add-label reviewed >/dev/null 2>&1 || true
    fi
}

# === Main ===

main() {
    # Visual separation (terminal + file)
    echo ""
    echo "" >> "$LOGS_DIR/hype.log"
    log "INFO" "CHECK (streaming mode)"

    # Get tasks needing review
    local tasks
    tasks=$(get_review_tasks)

    if [ -z "$tasks" ]; then
        log "INFO" "No tasks need review"
        exit 0
    fi

    # Process ONE task per call (streaming architecture)
    # Quality gate: thorough review of each task
    # Next iteration will pick up remaining tasks
    local task_id
    task_id=$(echo "$tasks" | head -n 1)

    if [ -n "$task_id" ]; then
        log "INFO" "Review: $task_id"
        process_review "$task_id"
        bd sync 2>/dev/null || true
        log "INFO" "Processed 1 review"
    fi
}

main "$@"
