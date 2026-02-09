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

# find_free_slot - allocates a slot with lock-based protection
# Uses mkdir for atomic lock acquisition (prevents race conditions between HYPE cycles)
# Lock is released only after cleanup_worktree completes
find_free_slot() {
    mkdir -p "$WORKTREES_DIR"
    local slot=0
    while true; do
        local lock_dir="$WORKTREES_DIR/executor-$slot.lock"

        # Check for stale lock (older than 30 minutes = crashed executor)
        if [ -d "$lock_dir" ]; then
            local lock_age
            lock_age=$(( $(date +%s) - $(stat -f %m "$lock_dir" 2>/dev/null || stat -c %Y "$lock_dir" 2>/dev/null || echo 0) ))
            if [ "$lock_age" -gt 1800 ]; then
                rmdir "$lock_dir" 2>/dev/null || true
            fi
        fi

        # Try to acquire lock via mkdir (atomic)
        if mkdir "$lock_dir" 2>/dev/null; then
            echo "$slot"
            return 0
        fi

        ((slot++))

        # Safety: don't loop forever
        if [ "$slot" -gt 20 ]; then
            >&2 echo "ERROR: No free slots found after checking 20 slots"
            return 1
        fi
    done
}

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
    # Suppress stdout ("HEAD is now at...") to avoid polluting worktree_path
    if git worktree add --detach "$worktree_path" HEAD >/dev/null 2>&1; then
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
    local lock_dir="$WORKTREES_DIR/executor-$slot.lock"

    if [ -d "$worktree_path" ]; then
        git worktree remove --force "$worktree_path" 2>/dev/null || rm -rf "$worktree_path"
    fi

    # Release lock AFTER worktree is fully cleaned up
    # This prevents race condition where new executor gets slot before cleanup completes
    rmdir "$lock_dir" 2>/dev/null || true
}

log() {
    local level=$1
    local msg=$2
    local color="" reset="\033[0m" gray="\033[90m"
    # HYPE brand colors (neon pink gradient)
    local hype_colored="\033[38;2;255;0;102mH\033[38;2;255;51;153mY\033[38;2;255;102;204mP\033[38;2;204;255;0mE\033[0m"

    case "$level" in
        INFO|SUCCESS)  color="\033[32m" ;;
        WARN)          color="\033[33m" ;;
        ERROR|FATAL)   color="\033[31m" ;;
        TASK_START)    color="\033[36m" ;;
    esac

    printf "${gray}%s${reset} [${hype_colored} WORK] ${color}%s${reset}: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [HYPE WORK] $level: $msg" >> "$LOGS_DIR/hype.log"
}

# === Backpressure check ===
# Считаем active executors через beads (работает всегда, не зависит от gh)

count_active_executors() {
    local cache=${1:-""}  # Optional cache from main() (v1.9.0+)

    if [ -n "$cache" ]; then
        # Use provided cache
        echo "$cache" | jq '[.[] | select(.labels[]? == "executor")] | length' 2>/dev/null || echo "0"
    else
        # Fallback: fresh bd list
        bd_safe list --status=in_progress --json 2>/dev/null | \
            jq '[.[] | select(.labels[]? == "executor")] | length' 2>/dev/null || echo "0"
    fi
}

# === Get ready tasks for executors ===

get_ready_tasks() {
    # Получаем задачи готовые к работе (не blocked, не in_progress)
    # Фильтруем:
    #   - type: task, bug, feature (исключаем epic - это контейнеры)
    #   - исключаем служебные (triggers, milestones)
    #   - исключаем smoke и regression (ждут smoke_review от Architect)
    #   - сортируем по приоритету (P0 первые)
    #   - sort -u для дедупликации (bd ready может вернуть дубликаты)
    bd_safe ready --json 2>/dev/null | \
        jq -r '.[] | select(.issue_type == "task" or .issue_type == "bug" or .issue_type == "feature") | select(.title | test("^run-|^milestone:") | not) | select((.labels // []) | any(test("^milestone:")) | not) | select((.labels // []) | index("regression") | not) | select((.labels // []) | index("smoke") | not) | select((.labels // []) | index("user-escalation") | not) | "\(.priority):\(.id)"' 2>/dev/null | \
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
    current_status=$(bd_safe show "$task_id" --json 2>/dev/null | jq -r '.[0].status // "unknown"' 2>/dev/null)

    if [ "$current_status" != "open" ]; then
        log "INFO" "Task $task_id not open (status: $current_status), skipping"
        cleanup_worktree "$slot"
        return 0
    fi

    # Try to claim the task (atomic via beads)
    # Remove needs-review in case this is a retry after timeout
    if ! bd_safe update "$task_id" --status=in_progress --add-label=executor --remove-label=needs-review >/dev/null 2>&1; then
        log "INFO" "Task $task_id claim failed (race condition), skipping"
        cleanup_worktree "$slot"
        return 0
    fi

    # Create isolated worktree for this executor
    worktree_path=$(create_worktree "$slot" "$task_id")
    log "INFO" "Executor $slot using worktree: $worktree_path"

    # Get task details
    local task_json
    task_json=$(bd_safe show "$task_id" --json 2>/dev/null || echo "[]")

    # Validate task exists (race condition protection)
    local task_title
    task_title=$(echo "$task_json" | jq -r '.[0].title // empty' 2>/dev/null || true)

    if [ -z "$task_title" ]; then
        log "WARN" "Task $task_id not found or invalid (race condition?), skipping"
        cleanup_worktree "$slot"
        return 0
    fi

    # Get model from label (fallback: sonnet with warning)
    local requested_model model
    requested_model=$(echo "$task_json" | jq -r '.[0].labels[]? | select(startswith("model:")) | split(":")[1]' 2>/dev/null | head -1)
    if [ -z "$requested_model" ]; then
        log "WARN" "Task $task_id has no model: label, using fallback sonnet"
        requested_model="sonnet"
    fi

    # Map to allowed model (respects ALLOWED_MODELS from config)
    model=$(map_model "$requested_model")
    if [ "$model" != "$requested_model" ]; then
        log "INFO" "Model mapped: $requested_model → $model (ALLOWED_MODELS=$ALLOWED_MODELS)"
    fi

    log "INFO" "Starting executor for $task_id ($model): $task_title"

    # Run executor agent with timeout (with tool use enabled)
    local output_file="$LOGS_DIR/executor-$task_id.log"
    local executor_prompt
    executor_prompt=$(cat .claude/agents/executor.md 2>/dev/null || echo "# Executor agent not found")

    # Build retry context if this is a retry attempt
    local retry_context
    retry_context=$(build_retry_context "$task_id")

    local full_prompt="$executor_prompt

---
TASK_ID: $task_id
TASK: $task_json
PROJECT_ROOT: $PROJECT_DIR
WORKTREE_PATH: $worktree_path
${retry_context:+
$retry_context}"

    # Run executor with real-time progress logging
    # Uses worktree for git isolation, all bd operations through daemon
    # Use || to prevent set -e from killing script on timeout/failure
    local exit_code=0
    run_claude_with_progress "$full_prompt" "$model" "$TASK_TIMEOUT" "$output_file" "EXEC $slot" "$LOGS_DIR" "$worktree_path" || exit_code=$?

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

            # Save structured attempt result
            local updated_notes
            updated_notes=$(save_attempt_result "$task_id" "TIMEOUT after $TASK_TIMEOUT - task may be too large or complex")

            # Remove old retry label if exists, add new one
            old_retry_label=$(echo "$task_json" | jq -r '.[0].labels[]? | select(startswith("retry:"))' 2>/dev/null | head -1)
            if [ -n "$old_retry_label" ]; then
                bd_safe update "$task_id" --status=open --remove-label=executor --remove-label="$old_retry_label" --add-label="retry:$new_retry" --notes="$updated_notes" >/dev/null 2>&1 || true
            else
                bd_safe update "$task_id" --status=open --remove-label=executor --add-label="retry:$new_retry" --notes="$updated_notes" >/dev/null 2>&1 || true
            fi
        else
            log "ERROR" "Executor failed for $task_id (exit: $exit_code)"
            # Save structured attempt result
            local updated_notes
            updated_notes=$(save_attempt_result "$task_id" "FAILED with exit code $exit_code")
            bd_safe update "$task_id" --status=open --remove-label=executor --notes="$updated_notes" >/dev/null 2>&1 || true
        fi
        return 0
    fi

    log "INFO" "Executor completed for $task_id"

    # Fallback: ensure labels are updated even if agent didn't do it
    # Agent should call: bd update --remove-label=executor --add-label=needs-review
    # But we ensure it as safety net
    bd_safe update "$task_id" --remove-label=executor --add-label=needs-review >/dev/null 2>&1 || true
}

# === Run auditor for analysis tasks ===
# Auditor: no worktree, no branch, no commits - just reads and writes findings

run_auditor() {
    local task_id=$1

    # Try to claim the task
    if ! bd_safe update "$task_id" --status=in_progress --add-label=executor --remove-label=needs-review >/dev/null 2>&1; then
        log "INFO" "Task $task_id claim failed (race condition), skipping"
        return 0
    fi

    # Get task details
    local task_json
    task_json=$(bd_safe show "$task_id" --json 2>/dev/null || echo "[]")

    local task_title
    task_title=$(echo "$task_json" | jq -r '.[0].title // empty' 2>/dev/null || true)

    if [ -z "$task_title" ]; then
        log "WARN" "Task $task_id not found, skipping"
        return 0
    fi

    log "INFO" "Starting auditor for $task_id: $task_title"

    # Determine model from task labels (default: sonnet for auditor)
    local task_model
    task_model=$(echo "$task_json" | jq -r '.[0].labels[]? | select(startswith("model:")) | split(":")[1]' 2>/dev/null | head -1)
    task_model=${task_model:-sonnet}

    local model
    model=$(map_model "$task_model")
    if [ "$task_model" != "sonnet" ]; then
        log "INFO" "Using $task_model for $task_id"
    fi

    # Build prompt
    local auditor_prompt
    auditor_prompt=$(cat .claude/agents/auditor.md 2>/dev/null || echo "# Auditor agent not found")

    local full_prompt="$auditor_prompt

---
TASK_ID: $task_id
TASK: $task_json
PROJECT_ROOT: $PROJECT_DIR"

    local output_file="$LOGS_DIR/auditor-$task_id.log"
    local audit_timeout="${AUDIT_TIMEOUT:-5m}"

    # Run auditor (no worktree needed - auditor doesn't create branches)
    # Use || to prevent set -e from killing script on timeout/failure
    local exit_code=0
    run_claude_with_progress "$full_prompt" "$model" "$audit_timeout" "$output_file" "AUDIT" "$LOGS_DIR" "$PROJECT_DIR" || exit_code=$?

    if [ $exit_code -ne 0 ]; then
        if [ $exit_code -eq 124 ]; then
            log "WARN" "Auditor timeout for $task_id"
        else
            log "ERROR" "Auditor failed for $task_id (exit: $exit_code)"
        fi

        # Get current retry count
        local audit_retry
        audit_retry=$(echo "$task_json" | jq -r '.[0].labels[]? | select(startswith("audit-retry:")) | split(":")[1]' 2>/dev/null | head -1)
        audit_retry=${audit_retry:-0}

        if [ "$audit_retry" -ge 2 ]; then
            # 3rd failure - escalate to Architect
            local task_desc
            task_desc=$(echo "$task_json" | jq -r '.[0].description // ""' 2>/dev/null)

            log "WARN" "ESCALATE: $task_id - auditor failed 3 times, creating architect task"
            bd_safe create --title="Review failed audit: $task_title" --type=task --priority=1 \
                --labels="model:opus,escalation" \
                --description="## Context
Audit task $task_id failed after 3 attempts (timeout/error).

## Original Task
**Title:** $task_title
**Description:** $task_desc

## Failure Info
- Exit code: $exit_code (124 = timeout)
- Model used: opus (after escalation from sonnet)

## Required Action
1. Review if audit scope is too large
2. Either: split into smaller audits, or reformulate
3. Close $task_id with appropriate reason" >/dev/null 2>&1 || true

            bd_safe update "$task_id" --status=open --remove-label=executor \
                --add-label=blocked:escalated \
                --notes="Escalated to Architect: auditor failed 3 times (timeout/error)." >/dev/null 2>&1 || true
        else
            # Determine current model and escalate one level up
            local current_model
            current_model=$(echo "$task_json" | jq -r '.[0].labels[]? | select(startswith("model:")) | split(":")[1]' 2>/dev/null | head -1)
            current_model=${current_model:-sonnet}

            local next_retry=$((audit_retry + 1))

            if [ "$current_model" = "haiku" ]; then
                # haiku → sonnet
                log "INFO" "Escalating $task_id: haiku → sonnet (retry $next_retry)"
                bd_safe update "$task_id" --status=open --remove-label=executor \
                    --remove-label="audit-retry:$audit_retry" --remove-label=model:haiku \
                    --add-label=model:sonnet --add-label="audit-retry:$next_retry" \
                    --notes="Retry $next_retry: escalated haiku → sonnet." >/dev/null 2>&1 || true
            elif [ "$current_model" = "sonnet" ]; then
                # sonnet → opus
                log "INFO" "Escalating $task_id: sonnet → opus (retry $next_retry)"
                bd_safe update "$task_id" --status=open --remove-label=executor \
                    --remove-label="audit-retry:$audit_retry" --remove-label=model:sonnet \
                    --add-label=model:opus --add-label="audit-retry:$next_retry" \
                    --notes="Retry $next_retry: escalated sonnet → opus." >/dev/null 2>&1 || true
            else
                # opus → stay opus, just increment retry
                log "INFO" "RETRY: $task_id - opus retry $next_retry"
                bd_safe update "$task_id" --status=open --remove-label=executor \
                    --remove-label="audit-retry:$audit_retry" --add-label="audit-retry:$next_retry" \
                    --notes="Retry $next_retry: opus retry." >/dev/null 2>&1 || true
            fi
        fi
        return 0
    fi

    log "INFO" "Auditor completed for $task_id"

    # Ensure needs-review is set
    bd_safe update "$task_id" --remove-label=executor --add-label=needs-review >/dev/null 2>&1 || true
}

# === Main ===

main() {
    # Visual separation (terminal + file)
    echo ""
    echo "" >> "$LOGS_DIR/hype.log"

    # Cache in_progress tasks for backpressure check (v1.9.0 optimization)
    local in_progress_cache
    in_progress_cache=$(bd_safe list --status=in_progress --json 2>/dev/null || echo "[]")

    # Check backpressure (using cache)
    local active
    active=$(count_active_executors "$in_progress_cache")

    if [ "$active" -ge "$MAX_PARALLEL" ]; then
        log "INFO" "Executor queue full ($active/$MAX_PARALLEL), waiting for slots"
        exit 0
    fi

    local available_slots=$((MAX_PARALLEL - active))

    # Get ready tasks
    local tasks
    tasks=$(get_ready_tasks)

    if [ -z "$tasks" ]; then
        log "INFO" "No ready tasks (slots: $available_slots/$MAX_PARALLEL)"
        exit 0
    fi

    local task_count
    task_count=$(echo "$tasks" | wc -l | tr -d ' ')
    log "INFO" "Checking $task_count ready tasks (slots: $available_slots/$MAX_PARALLEL)"

    # Start executors in parallel (up to available slots)
    # Non-blocking: launch and return immediately (streaming architecture)
    # Each executor gets its own slot number for worktree isolation
    # Slots are allocated via lock files (find_free_slot) to prevent race conditions
    local started=0
    local skipped=0
    for task_id in $tasks; do
        if [ $started -ge $available_slots ]; then
            break
        fi

        # Pre-check status (reduce race condition confusion in logs)
        local current_status task_title model
        current_status=$(bd_safe show "$task_id" --json 2>/dev/null | jq -r '.[0].status // "unknown"' 2>/dev/null || echo "unknown")

        if [ "$current_status" != "open" ]; then
            log "INFO" "SKIP: $task_id already $current_status"
            ((skipped++)) || true
            continue
        fi

        # Get task details for logging and routing
        local task_json
        task_json=$(bd_safe show "$task_id" --json 2>/dev/null || echo "[]")
        task_title=$(echo "$task_json" | jq -r '.[0].title // "unknown"' 2>/dev/null | head -c 40)
        model=$(echo "$task_json" | jq -r '.[0].labels[]? | select(startswith("model:")) | split(":")[1]' 2>/dev/null | head -1)
        model="${model:-sonnet}"

        # Route: audit tasks → Auditor, code tasks → Executor
        if is_audit_task "$task_json"; then
            log "TASK_START" "$task_id \"$task_title\" (AUDIT, sonnet)"
            # Auditor: no worktree, no slot (doesn't create branches)
            ( run_auditor "$task_id" ) &
        else
            local slot
            slot=$(find_free_slot) || {
                log "ERROR" "Failed to allocate slot for $task_id, skipping"
                ((skipped++)) || true
                continue
            }
            log "TASK_START" "$task_id \"$task_title\" (slot $slot, $model)"
            # Executor: uses worktree for isolation
            ( run_executor "$slot" "$task_id" ) &
        fi
        ((started++))
    done

    # Detach all background jobs (won't receive SIGHUP if parent exits)
    disown -a 2>/dev/null || true

    log "INFO" "Started $started executor(s), skipped $skipped"
    # No wait — returns immediately, HYPE will check progress next iteration
}

main "$@"
