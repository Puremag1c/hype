#!/bin/bash
# core/scripts/run-merge-queue.sh
# Sequential merge worker — takes approved tasks one at a time.
# Part of v2.2 parallel review pipeline.
#
# Flow: approved task → merge --squash → push → close → cleanup branch
# Audit tasks: close without merge (no branch).
#
# Usage: ./scripts/run-merge-queue.sh

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

mkdir -p "$LOGS_DIR"

log() {
    local level=$1
    local msg=$2
    local color="" reset="\033[0m" gray="\033[90m"
    local hype_colored="\033[38;2;255;0;102mH\033[38;2;255;51;153mY\033[38;2;255;102;204mP\033[38;2;204;255;0mE\033[0m"

    case "$level" in
        INFO)    color="\033[32m" ;;
        WARN)    color="\033[33m" ;;
        ERROR)   color="\033[31m" ;;
        SUCCESS) color="\033[35m" ;;
    esac

    printf "${gray}%s${reset} [${hype_colored} MERGE] ${color}%s${reset}: %s\n" "$(date '+%H:%M:%S')" "$level" "$msg"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [HYPE MERGE] $level: $msg" >> "$LOGS_DIR/hype.log"
}

# Get tasks ready for merge (approved label, in_progress status)
get_approved_tasks() {
    bd_safe list --status=in_progress --json --limit 0 2>/dev/null | \
        jq -r '.[] | select((.labels // []) | index("approved")) | select((.labels // []) | index("trigger") | not) | .id' 2>/dev/null
}

# Merge one approved task
merge_task() {
    local task_id=$1

    local task_json
    task_json=$(bd_safe show "$task_id" --json 2>/dev/null || echo "[]")
    local task_title
    task_title=$(echo "$task_json" | jq -r '.[0].title // "Task"' 2>/dev/null)

    # Check if audit task (no branch, no merge needed)
    if is_audit_task "$task_json"; then
        log "INFO" "Audit task $task_id — closing without merge"
        bd_safe close "$task_id" --reason="Audit approved, no merge needed" >/dev/null 2>&1 || true
        bd_safe update "$task_id" --remove-label=approved --add-label=reviewed >/dev/null 2>&1 || true
        return 0
    fi

    # Check if already closed (race with reviewer NO_MERGE)
    local current_status
    current_status=$(echo "$task_json" | jq -r '.[0].status // "unknown"' 2>/dev/null)
    if [ "$current_status" = "closed" ]; then
        log "INFO" "Task $task_id already closed, skipping merge"
        return 0
    fi

    local branch="task/beads-$task_id"
    local main_ref
    main_ref=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")

    # Fetch latest
    git fetch origin 2>/dev/null || true

    # Check branch exists
    if ! git rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
        # Check if task was closed with NO_MERGE by reviewer
        local close_reason
        close_reason=$(echo "$task_json" | jq -r '.[0].close_reason // ""' 2>/dev/null)
        if echo "$close_reason" | grep -q "NO_MERGE:"; then
            log "SUCCESS" "APPROVED (no merge needed): $task_id"
            bd_safe update "$task_id" --remove-label=approved --add-label=reviewed >/dev/null 2>&1 || true
            return 0
        fi

        log "ERROR" "Branch $branch not found for $task_id"
        # Remove approved, reopen for executor to fix
        bd_safe update "$task_id" --status=open --remove-label=approved \
            --notes="Merge failed: branch $branch not found" >/dev/null 2>&1 || true
        return 0
    fi

    # Record main SHA before merge
    local main_before
    main_before=$(git rev-parse "$main_ref" 2>/dev/null || echo "unknown")

    # Merge to main
    log "INFO" "Merging $task_id ($branch)"
    git checkout "$main_ref" 2>/dev/null || true
    git pull origin "$main_ref" 2>/dev/null || true

    if ! git merge --squash "origin/$branch" 2>/dev/null; then
        # Merge conflict
        git merge --abort 2>/dev/null || git reset --hard "origin/$main_ref" 2>/dev/null || true
        log "WARN" "Merge conflict for $task_id"

        # Increment reject:N
        local reject_count
        reject_count=$(get_counter_value "$task_json" "reject")
        ((reject_count++))
        set_counter_label "$task_id" "reject" "$reject_count"

        # Return to executor (not reviewer)
        bd_safe update "$task_id" --status=open --remove-label=approved \
            --notes="Merge conflict on $branch. Rebase on $main_ref and resolve. (reject:$reject_count)" >/dev/null 2>&1 || true

        if [ "$reject_count" -ge 4 ]; then
            bd_safe update "$task_id" --add-label=blocked:troubleshoot \
                --notes="Merge conflicts persist after $reject_count attempts. Escalated." >/dev/null 2>&1 || true
            log "WARN" "TROUBLESHOOT: $task_id - merge conflicts persist (reject:$reject_count)"
        fi
        return 0
    fi

    # Commit and push
    git commit -m "$task_title

Task: $task_id" 2>/dev/null || true

    if ! git push origin "$main_ref" 2>/dev/null; then
        log "ERROR" "Push failed for $task_id, returning to executor"
        git reset --hard "origin/$main_ref" 2>/dev/null || true

        # Increment reject:N and return to executor
        local reject_count
        reject_count=$(get_counter_value "$task_json" "reject")
        ((reject_count++))
        set_counter_label "$task_id" "reject" "$reject_count"

        bd_safe update "$task_id" --status=open --remove-label=approved \
            --notes="Push to $main_ref failed after squash merge. Rebase on $main_ref and retry. (reject:$reject_count)" >/dev/null 2>&1 || true

        if [ "$reject_count" -ge 4 ]; then
            bd_safe update "$task_id" --add-label=blocked:troubleshoot \
                --notes="Push failures persist after $reject_count attempts. Escalated." >/dev/null 2>&1 || true
            log "WARN" "TROUBLESHOOT: $task_id - push failures persist (reject:$reject_count)"
        fi
        return 0
    fi

    # Verify main actually changed
    local main_after
    main_after=$(git rev-parse "$main_ref" 2>/dev/null || echo "unknown")

    if [ "$main_before" != "unknown" ] && [ "$main_before" = "$main_after" ]; then
        log "WARN" "Main unchanged after merge of $task_id — possible empty squash"
        # Nothing to close — will retry next cycle
        return 0
    fi

    # Close task
    bd_safe close "$task_id" >/dev/null 2>&1 || true
    bd_safe update "$task_id" --remove-label=approved --add-label=reviewed >/dev/null 2>&1 || true

    # Cleanup remote branch
    git push origin --delete "$branch" 2>/dev/null || true

    log "SUCCESS" "MERGED: $task_id ($task_title)"
}

# Main
main() {
    echo ""
    echo "" >> "$LOGS_DIR/hype.log"
    log "INFO" "MERGE QUEUE: checking approved tasks"

    local tasks
    tasks=$(get_approved_tasks)

    if [ -z "$tasks" ]; then
        log "INFO" "No approved tasks to merge"
        exit 0
    fi

    # Process ONE task per call (sequential, safe)
    local task_id
    task_id=$(echo "$tasks" | head -n 1)

    if [ -n "$task_id" ]; then
        log "INFO" "Merge: $task_id"
        merge_task "$task_id"
        bd_safe sync 2>/dev/null || true
    fi
}

main "$@"
