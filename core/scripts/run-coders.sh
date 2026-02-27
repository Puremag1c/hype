#!/bin/bash
# core/scripts/run-coders.sh
# Запускает Executor агентов параллельно с backpressure контролем.
#
# Backpressure: количество активных coders ограничено через MAX_PARALLEL_CODERS.
# Считаем через beads (in_progress + label=coder), не через gh pr list.
#
# Использование: ./scripts/run-coders.sh

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

MAX_PARALLEL="${MAX_PARALLEL_CODERS:-3}"
TASK_TIMEOUT="${TASK_TIMEOUT:-10m}"
WORKTREES_DIR="$PROJECT_DIR/.hype-worktrees"

mkdir -p "$LOGS_DIR"

# === Worktree management ===
# Изоляция coders через git worktrees (избегает HEAD conflicts и beads import storms)

# Symlink build artifact directories from project into worktree
# so coders can compile/test without re-downloading dependencies
setup_worktree_links() {
    local worktree_path="$1"
    local project_dir="$2"

    # Common build artifact dirs (gitignored, not in worktree)
    local dirs="deps _build node_modules .venv venv vendor target"
    for dir in $dirs; do
        if [ -d "$project_dir/$dir" ] && [ ! -e "$worktree_path/$dir" ]; then
            ln -sf "$project_dir/$dir" "$worktree_path/$dir"
        fi
    done
}

# find_free_slot - allocates a slot with lock-based protection
# Uses mkdir for atomic lock acquisition (prevents race conditions between HYPE cycles)
# Lock is released only after cleanup_worktree completes
find_free_slot() {
    mkdir -p "$WORKTREES_DIR"
    local slot=0
    while true; do
        local lock_dir="$WORKTREES_DIR/coder-$slot.lock"

        # Check for stale lock (older than 30 minutes = crashed coder)
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
    local worktree_path="$WORKTREES_DIR/coder-$slot"

    # Cleanup if exists (stale from crash)
    if [ -d "$worktree_path" ]; then
        timeout 30s git worktree remove --force "$worktree_path" 2>/dev/null || rm -rf "$worktree_path"
    fi

    # Prune stale worktree tracking entries (fixes 56% failure rate when
    # previous worktree was rm -rf'd without git worktree remove)
    git worktree prune 2>/dev/null || true

    mkdir -p "$WORKTREES_DIR"

    # Create worktree from current HEAD (detached)
    # --detach avoids branch conflicts between parallel coders
    # Suppress stdout ("HEAD is now at...") to avoid polluting worktree_path
    local wt_stderr
    if wt_stderr=$(git worktree add --detach "$worktree_path" HEAD 2>&1 >/dev/null); then
        setup_worktree_links "$worktree_path" "$PROJECT_DIR"
        echo "$worktree_path"
        return 0
    fi

    # Retry once after brief delay (concurrent git lock contention)
    log "WARN" "Worktree creation failed for slot $slot: $wt_stderr — retrying..."
    sleep 1
    git worktree prune 2>/dev/null || true

    if git worktree add --detach "$worktree_path" HEAD >/dev/null 2>&1; then
        setup_worktree_links "$worktree_path" "$PROJECT_DIR"
        echo "$worktree_path"
        return 0
    else
        log "WARN" "Failed to create worktree for slot $slot after retry, using main directory"
        echo "$PROJECT_DIR"
        return 1
    fi
}

cleanup_worktree() {
    local slot=$1
    local worktree_path="$WORKTREES_DIR/coder-$slot"
    local lock_dir="$WORKTREES_DIR/coder-$slot.lock"

    if [ -d "$worktree_path" ]; then
        timeout 30s git worktree remove --force "$worktree_path" 2>/dev/null || rm -rf "$worktree_path"
    fi

    # Release lock AFTER worktree is fully cleaned up
    # This prevents race condition where new coder gets slot before cleanup completes
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
# Count active coders by lock files (not beads labels — labels are unreliable
# due to sync lag and race conditions between parallel subshells)
# Lock lifecycle: find_free_slot() creates → cleanup_worktree() removes

count_active_coders() {
    local count=0
    for lock in "$WORKTREES_DIR"/coder-*.lock; do
        [ -d "$lock" ] && ((count++))
    done
    echo "$count"
}

# === Get ready tasks for coders ===

get_ready_tasks() {
    # Получаем задачи готовые к работе (не blocked, не in_progress)
    # Фильтруем:
    #   - type: task, bug, feature (исключаем epic - это контейнеры)
    #   - исключаем служебные (triggers, milestones)
    #   - исключаем smoke и regression (ждут reflexing от Architect)
    #   - сортируем по приоритету (P0 первые)
    #   - sort -u для дедупликации (bd ready может вернуть дубликаты)
    bd_safe ready --json 2>/dev/null | \
        jq -r '.[] | select(.issue_type == "task" or .issue_type == "bug" or .issue_type == "feature") | select(.title | test("^run-|^milestone:") | not) | select((.labels // []) | any(test("^milestone:")) | not) | select((.labels // []) | index("trigger") | not) | select((.labels // []) | index("needs-review") | not) | select((.labels // []) | index("regression") | not) | select((.labels // []) | index("smoke") | not) | select((.labels // []) | index("user-escalation") | not) | select((.labels // []) | any(startswith("blocked:")) | not) | "\(.priority):\(.id)"' 2>/dev/null | \
        sort -n | \
        cut -d: -f2 | \
        head -n "$MAX_PARALLEL" || echo ""
}

# === Run single coder ===

run_coder() {
    local slot=$1
    local task_id=$2
    local worktree_path=""

    # Check task status before claim (avoid race condition confusion)
    local current_status
    current_status=$(bd_safe show "$task_id" --json 2>/dev/null | jq -r '.[0].status // "unknown"' 2>/dev/null || echo "unknown")

    if [ "$current_status" != "open" ]; then
        log "INFO" "Task $task_id not open (status: $current_status), skipping"
        cleanup_worktree "$slot"
        return 0
    fi

    # Try to claim the task (atomic via beads)
    # Remove needs-review in case this is a retry after timeout
    if ! bd_safe update "$task_id" --status=in_progress --add-label=coder --remove-label=needs-review >/dev/null 2>&1; then
        log "INFO" "Task $task_id claim failed (race condition), skipping"
        cleanup_worktree "$slot"
        return 0
    fi

    # Create isolated worktree for this coder
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

    log "INFO" "Starting coder for $task_id ($model): $task_title"

    # Run coder agent with timeout (with tool use enabled)
    local output_file="$LOGS_DIR/coder-$task_id.log"
    local coder_prompt
    coder_prompt=$(cat .claude/agents/coder.md 2>/dev/null || echo "# Coder agent not found")

    # Build retry context if this is a retry attempt
    local retry_context
    retry_context=$(build_retry_context "$task_id")

    local base_branch
    base_branch=$(get_base_branch)

    local full_prompt="$coder_prompt

---
TASK_ID: $task_id
TASK: $task_json
PROJECT_ROOT: $PROJECT_DIR
WORKTREE_PATH: $worktree_path
BASE_BRANCH: $base_branch
${retry_context:+
$retry_context}"

    # Run coder with real-time progress logging
    # Uses worktree for git isolation, all bd operations through daemon
    # Use || to prevent set -e from killing script on timeout/failure
    local exit_code=0
    run_claude_with_progress "$full_prompt" "$model" "$TASK_TIMEOUT" "$output_file" "CODE $slot" "$LOGS_DIR" "$worktree_path" || exit_code=$?

    # Always cleanup worktree (success or failure)
    cleanup_worktree "$slot"

    # Guard: check if task was already handled by senior coder during our run.
    # Without this, a zombie coder timeout reopens a task that senior already closed.
    local post_status
    post_status=$(bd_safe show "$task_id" --json 2>/dev/null | jq -r '.[0].status // "unknown"' 2>/dev/null || echo "unknown")
    if [ "$post_status" = "closed" ]; then
        log "INFO" "Task $task_id already closed (reviewed during coder run), skipping post-processing"
        return 0
    fi

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
                bd_safe update "$task_id" --status=open --remove-label=coder --remove-label="$old_retry_label" --add-label="retry:$new_retry" --notes="$updated_notes" >/dev/null 2>&1 || true
            else
                bd_safe update "$task_id" --status=open --remove-label=coder --add-label="retry:$new_retry" --notes="$updated_notes" >/dev/null 2>&1 || true
            fi
        else
            log "ERROR" "Executor failed for $task_id (exit: $exit_code)"
            # Save structured attempt result
            local updated_notes
            updated_notes=$(save_attempt_result "$task_id" "FAILED with exit code $exit_code")
            bd_safe update "$task_id" --status=open --remove-label=coder --notes="$updated_notes" >/dev/null 2>&1 || true
        fi
        return 0
    fi

    log "INFO" "Coder completed for $task_id"

    # Safety net: ensure labels updated (agent should do it, this is fallback)
    # Split strategy: combined op first, fallback to critical-only (remove coder label)
    # HEAL (hype.sh heal_stuck_tasks Part A) adds needs-review within ≤2 min if needed
    bd_safe update "$task_id" --remove-label=coder --add-label=needs-review >/dev/null 2>&1 || {
        log "WARN" "Combined label update failed for $task_id, trying remove-coder only"
        bd_safe update "$task_id" --remove-label=coder >/dev/null 2>&1 || true
    }
}

# === Run auditor for analysis tasks ===
# Auditor: no worktree, no branch, no commits - just reads and writes findings

run_auditor() {
    local task_id=$1

    # Try to claim the task
    if ! bd_safe update "$task_id" --status=in_progress --add-label=coder --remove-label=needs-review >/dev/null 2>&1; then
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

    # Guard: check if task was already handled during our run
    local post_status
    post_status=$(bd_safe show "$task_id" --json 2>/dev/null | jq -r '.[0].status // "unknown"' 2>/dev/null || echo "unknown")
    if [ "$post_status" = "closed" ]; then
        log "INFO" "Task $task_id already closed (reviewed during auditor run), skipping post-processing"
        return 0
    fi

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
            # Guard: don't escalate if already an escalation task (prevents fork bomb GH#25)
            local existing_labels
            existing_labels=$(echo "$task_json" | jq -r '.[0].labels[]?' 2>/dev/null || true)
            if echo "$existing_labels" | grep -q "^escalation$"; then
                log "WARN" "SKIP escalation for $task_id - already an escalation task"
                bd_safe update "$task_id" --status=open --remove-label=coder \
                    --add-label=blocked:escalation-loop \
                    --notes="Blocked: recursive escalation detected (GH#25)." >/dev/null 2>&1 || true
            else
            # 3rd failure - escalate to Architect
            local task_desc
            task_desc=$(echo "$task_json" | jq -r '.[0].description // ""' 2>/dev/null)
            # Sanitize: strip AUDIT SCOPE marker to prevent is_audit_task false positive (GH#25)
            task_desc=$(echo "$task_desc" | sed 's/AUDIT SCOPE/[audit scope]/gI')

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

            bd_safe update "$task_id" --status=open --remove-label=coder \
                --add-label=blocked:escalated \
                --notes="Escalated to Architect: auditor failed 3 times (timeout/error)." >/dev/null 2>&1 || true
            fi
        else
            # Determine current model and escalate one level up
            local current_model
            current_model=$(echo "$task_json" | jq -r '.[0].labels[]? | select(startswith("model:")) | split(":")[1]' 2>/dev/null | head -1)
            current_model=${current_model:-sonnet}

            local next_retry=$((audit_retry + 1))

            if [ "$current_model" = "haiku" ]; then
                # haiku → sonnet
                log "INFO" "Escalating $task_id: haiku → sonnet (retry $next_retry)"
                bd_safe update "$task_id" --status=open --remove-label=coder \
                    --remove-label="audit-retry:$audit_retry" --remove-label=model:haiku \
                    --add-label=model:sonnet --add-label="audit-retry:$next_retry" \
                    --notes="Retry $next_retry: escalated haiku → sonnet." >/dev/null 2>&1 || true
            elif [ "$current_model" = "sonnet" ]; then
                # sonnet → opus
                log "INFO" "Escalating $task_id: sonnet → opus (retry $next_retry)"
                bd_safe update "$task_id" --status=open --remove-label=coder \
                    --remove-label="audit-retry:$audit_retry" --remove-label=model:sonnet \
                    --add-label=model:opus --add-label="audit-retry:$next_retry" \
                    --notes="Retry $next_retry: escalated sonnet → opus." >/dev/null 2>&1 || true
            else
                # opus → stay opus, just increment retry
                log "INFO" "RETRY: $task_id - opus retry $next_retry"
                bd_safe update "$task_id" --status=open --remove-label=coder \
                    --remove-label="audit-retry:$audit_retry" --add-label="audit-retry:$next_retry" \
                    --notes="Retry $next_retry: opus retry." >/dev/null 2>&1 || true
            fi
        fi
        return 0
    fi

    log "INFO" "Auditor completed for $task_id"

    # Safety net: ensure labels updated (agent should do it, this is fallback)
    # Split strategy: combined op first, fallback to critical-only (remove coder label)
    bd_safe update "$task_id" --remove-label=coder --add-label=needs-review >/dev/null 2>&1 || {
        log "WARN" "Combined label update failed for $task_id, trying remove-coder only"
        bd_safe update "$task_id" --remove-label=coder >/dev/null 2>&1 || true
    }
}

# === Main ===

main() {
    # Visual separation (terminal + file)
    echo ""
    echo "" >> "$LOGS_DIR/hype.log"

    # Check backpressure (count by lock files, not beads labels)
    local active
    active=$(count_active_coders)

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

    # Start coders in parallel (up to available slots)
    # Non-blocking: launch and return immediately (streaming architecture)
    # Each coder gets its own slot number for worktree isolation
    # Slots are allocated via lock files (find_free_slot) to prevent race conditions
    local started=0
    local skipped=0
    for task_id in $tasks; do
        if [ $started -ge $available_slots ]; then
            break
        fi

        # Single bd show for status check + task details (merged to reduce daemon load)
        local task_json current_status task_title model
        task_json=$(bd_safe show "$task_id" --json 2>/dev/null || echo "[]")
        current_status=$(echo "$task_json" | jq -r '.[0].status // "unknown"' 2>/dev/null || echo "unknown")

        if [ "$current_status" != "open" ]; then
            log "INFO" "SKIP: $task_id already $current_status"
            ((skipped++)) || true
            continue
        fi

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
            ( run_coder "$slot" "$task_id" ) &
        fi
        ((started++))
    done

    # Detach all background jobs (won't receive SIGHUP if parent exits)
    disown -a 2>/dev/null || true

    log "INFO" "Started $started coder(s), skipped $skipped"
    # No wait — returns immediately, HYPE will check progress next iteration
}

main "$@"
