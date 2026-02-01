#!/bin/bash
# core/scripts/run-executors.sh
# Запускает Executor агентов параллельно с backpressure контролем.
#
# Backpressure: количество активных executors ограничено через MAX_PARALLEL_EXECUTORS.
# Считаем через beads (in_progress + label=executor), не через gh pr list.
#
# Использование: ./scripts/run-executors.sh

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

MAX_PARALLEL="${MAX_PARALLEL_EXECUTORS:-3}"
TASK_TIMEOUT="${TASK_TIMEOUT:-10m}"
WORKTREES_DIR="$PROJECT_DIR/.hype-worktrees"

mkdir -p "$LOGS_DIR"

# === Worktree management ===
# Изоляция executors через git worktrees (избегает HEAD conflicts и beads import storms)

create_worktree() {
    local slot=$1
    local task_id=$2
    local worktree_path="$WORKTREES_DIR/executor-$slot"

    # Cleanup if exists (stale from crash)
    if [ -d "$worktree_path" ]; then
        git worktree remove --force "$worktree_path" 2>/dev/null || rm -rf "$worktree_path"
    fi

    mkdir -p "$WORKTREES_DIR"

    # Create worktree from current HEAD (detached)
    # --detach avoids branch conflicts between parallel executors
    if git worktree add --detach "$worktree_path" HEAD 2>/dev/null; then
        echo "$worktree_path"
        return 0
    else
        log "WARN" "Failed to create worktree for slot $slot, using main directory"
        echo "$PROJECT_DIR"
        return 1
    fi
}

cleanup_worktree() {
    local slot=$1
    local worktree_path="$WORKTREES_DIR/executor-$slot"

    if [ -d "$worktree_path" ]; then
        git worktree remove --force "$worktree_path" 2>/dev/null || rm -rf "$worktree_path"
    fi
}

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

    printf "${gray}%s${reset} [RUN-EXECUTORS] ${color}%s${reset}: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [RUN-EXECUTORS] $level: $msg" >> "$LOGS_DIR/hype.log"
}

# === Backpressure check ===
# Считаем active executors через beads (работает всегда, не зависит от gh)

count_active_executors() {
    # Считаем задачи в in_progress с label executor
    bd list --status=in_progress --json 2>/dev/null | \
        jq '[.[] | select(.labels[]? == "executor")] | length' 2>/dev/null || echo "0"
}

# === Get ready tasks for executors ===

get_ready_tasks() {
    # Получаем задачи готовые к работе (не blocked, не in_progress)
    # Фильтруем:
    #   - type: task, bug, feature (исключаем epic - это контейнеры)
    #   - исключаем служебные (triggers, milestones)
    #   - сортируем по приоритету (P0 первые)
    #   - sort -u для дедупликации (bd ready может вернуть дубликаты)
    bd ready --json 2>/dev/null | \
        jq -r '.[] | select(.issue_type == "task" or .issue_type == "bug" or .issue_type == "feature") | select(.title | test("^run-|^milestone:") | not) | "\(.priority):\(.id)"' 2>/dev/null | \
        sort -n | \
        cut -d: -f2 | \
        head -n "$MAX_PARALLEL"
}

# === Run single executor ===

run_executor() {
    local slot=$1
    local task_id=$2
    local worktree_path=""

    # Check task status before claim (avoid race condition confusion)
    local current_status
    current_status=$(bd show "$task_id" --json 2>/dev/null | jq -r '.[0].status // "unknown"' 2>/dev/null)

    if [ "$current_status" != "open" ]; then
        log "INFO" "Task $task_id not open (status: $current_status), skipping"
        return 0
    fi

    # Try to claim the task (atomic via beads)
    # Remove needs-review in case this is a retry after timeout
    if ! bd update "$task_id" --status=in_progress --add-label=executor --remove-label=needs-review 2>/dev/null; then
        log "INFO" "Task $task_id claim failed (race condition), skipping"
        return 0
    fi

    # Create isolated worktree for this executor
    worktree_path=$(create_worktree "$slot" "$task_id")
    log "INFO" "Executor $slot using worktree: $worktree_path"

    # Get task details
    local task_json
    task_json=$(bd show "$task_id" --json 2>/dev/null || echo "[]")

    # Validate task exists (race condition protection)
    local task_title
    task_title=$(echo "$task_json" | jq -r '.[0].title // empty' 2>/dev/null || true)

    if [ -z "$task_title" ]; then
        log "WARN" "Task $task_id not found or invalid (race condition?), skipping"
        cleanup_worktree "$slot"
        return 0
    fi

    # Get model from label (fallback: sonnet with warning)
    local model
    model=$(echo "$task_json" | jq -r '.[0].labels[]? | select(startswith("model:")) | split(":")[1]' 2>/dev/null | head -1)
    if [ -z "$model" ]; then
        log "WARN" "Task $task_id has no model: label, using fallback sonnet"
        model="sonnet"
    fi

    log "INFO" "Starting executor for $task_id ($model): $task_title"

    # Run executor agent with timeout (with tool use enabled)
    local output_file="$LOGS_DIR/executor-$task_id.log"
    local executor_prompt
    executor_prompt=$(cat .claude/agents/executor.md 2>/dev/null || echo "# Executor agent not found")

    local full_prompt="$executor_prompt

---
TASK_ID: $task_id
TASK: $task_json
PROJECT_ROOT: $PROJECT_DIR
WORKTREE_PATH: $worktree_path"

    # Use stdin to avoid issues with prompts starting with "---"
    # Run claude in worktree directory for git isolation
    # Worktrees use redirect file to share .beads/ with main repo
    # All bd operations go through daemon (serializes SQLite access)
    # Note: must capture exit code BEFORE any other command
    printf '%s' "$full_prompt" | timeout_cmd "$TASK_TIMEOUT" bash -c "cd '$worktree_path' && claude --model '$model'" > "$output_file" 2>&1
    local exit_code=$?

    # Always cleanup worktree (success or failure)
    cleanup_worktree "$slot"

    if [ $exit_code -ne 0 ]; then
        if [ $exit_code -eq 124 ]; then
            log "WARN" "Executor timeout for $task_id"
            # Increment retry counter (take max if multiple exist, remove old label)
            local current_retry old_retry_label
            current_retry=$(echo "$task_json" | jq -r '[.[0].labels[]? | select(startswith("retry:")) | split(":")[1] | tonumber] | max // 0' 2>/dev/null)
            current_retry="${current_retry:-0}"
            local new_retry=$((current_retry + 1))

            # Remove old retry label if exists, add new one
            # Use append_notes to preserve review feedback
            local updated_notes
            updated_notes=$(append_notes "$task_id" "Timeout at $(date '+%Y-%m-%d %H:%M:%S')")
            old_retry_label=$(echo "$task_json" | jq -r '.[0].labels[]? | select(startswith("retry:"))' 2>/dev/null | head -1)
            if [ -n "$old_retry_label" ]; then
                bd update "$task_id" --status=open --remove-label=executor --remove-label="$old_retry_label" --add-label="retry:$new_retry" --notes="$updated_notes" 2>/dev/null || true
            else
                bd update "$task_id" --status=open --remove-label=executor --add-label="retry:$new_retry" --notes="$updated_notes" 2>/dev/null || true
            fi
        else
            log "ERROR" "Executor failed for $task_id (exit: $exit_code)"
            local updated_notes
            updated_notes=$(append_notes "$task_id" "Executor failed (exit: $exit_code)")
            bd update "$task_id" --status=open --remove-label=executor --notes="$updated_notes" 2>/dev/null || true
        fi
        return 0
    fi

    log "INFO" "Executor completed for $task_id"

    # Fallback: ensure labels are updated even if agent didn't do it
    # Agent should call: bd update --remove-label=executor --add-label=needs-review
    # But we ensure it as safety net
    bd update "$task_id" --remove-label=executor --add-label=needs-review 2>/dev/null || true
}

# === Main ===

main() {
    log "INFO" "=========================================="
    log "INFO" "RUN-EXECUTORS STARTED"
    log "INFO" "Max parallel: $MAX_PARALLEL"
    log "INFO" "=========================================="

    # Check backpressure
    local active
    active=$(count_active_executors)

    if [ "$active" -ge "$MAX_PARALLEL" ]; then
        log "INFO" "Executor queue full ($active/$MAX_PARALLEL), waiting for slots"
        exit 0
    fi

    local available_slots=$((MAX_PARALLEL - active))
    log "INFO" "Available slots: $available_slots (active: $active)"

    # Get ready tasks
    local tasks
    tasks=$(get_ready_tasks)

    if [ -z "$tasks" ]; then
        log "INFO" "No ready tasks for executors"
        exit 0
    fi

    # Start executors in parallel (up to available slots)
    # Non-blocking: launch and return immediately (streaming architecture)
    # Each executor gets its own slot number for worktree isolation
    local started=0
    for task_id in $tasks; do
        if [ $started -ge $available_slots ]; then
            break
        fi

        # Launch in subshell, detached from parent
        # Pass slot number for worktree isolation
        ( run_executor "$started" "$task_id" ) &
        ((started++))
    done

    # Detach all background jobs (won't receive SIGHUP if parent exits)
    disown -a 2>/dev/null || true

    log "INFO" "Launched $started executors (non-blocking)"
    # No wait — returns immediately, orchestrator will check progress next iteration
}

main "$@"
