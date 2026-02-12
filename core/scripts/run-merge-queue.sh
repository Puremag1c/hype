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

# Git without hooks — merge queue is infrastructure.
# Target project's bd hooks (post-checkout, prepare-commit-msg, post-merge, pre-push)
# call `bd` directly, bypassing bd_safe mutex. Under load this overwhelms the daemon,
# hooks fail, git commit aborts, and staged changes poison the working tree for all
# subsequent merge attempts. (v2.3.4)
git_nh() {
    git -c core.hooksPath=/dev/null "$@"
}

# Get tasks ready for merge (approved label, in_progress status)
get_approved_tasks() {
    local cache="${HYPE_IN_PROGRESS_CACHE:-}"
    if [ -n "$cache" ]; then
        echo "$cache"
    else
        bd_safe list --status=in_progress --json --limit 0 2>/dev/null || echo "[]"
    fi | jq -r '.[] | select((.labels // []) | index("approved")) | select((.labels // []) | index("trigger") | not) | .id' 2>/dev/null || echo ""
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

    # Pre-flight: ensure clean working tree (v2.3.4)
    # Previous failed merge can leave staged changes from git merge --squash.
    # With dirty tree ALL subsequent git operations fail silently → false "conflicts".
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        log "WARN" "Dirty working tree — cleaning up before merge (likely from previous failed commit)"
        git_nh checkout "$main_ref" 2>/dev/null || true
        git_nh reset --hard "origin/$main_ref" 2>/dev/null || true
    fi

    # Fetch latest
    git_nh fetch origin 2>/dev/null || true

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

    # Auto-rebase branch on main before merge (v2.2.7)
    # Most "conflicts" are just stale branches — another task merged while this was in review.
    # Rebase resolves these automatically without wasting a full executor cycle.
    log "INFO" "Merging $task_id ($branch)"
    git_nh checkout "$main_ref" 2>/dev/null || true
    git_nh pull origin "$main_ref" 2>/dev/null || true

    # Try rebase: checkout branch, rebase on main, force-push
    git_nh checkout "origin/$branch" 2>/dev/null || true
    if ! git_nh rebase "$main_ref" 2>/dev/null; then
        # Rebase failed — likely timing conflict (another task merged, shifting lines)
        git_nh rebase --abort 2>/dev/null || true
        git_nh checkout "$main_ref" 2>/dev/null || true

        # Use separate merge-conflict:N counter (NOT reject:N — merge conflicts are infra, not code quality)
        local conflict_count
        conflict_count=$(get_counter_value "$task_json" "merge-conflict")
        ((conflict_count++))
        set_counter_label "$task_id" "merge-conflict" "$conflict_count" "$task_json"

        if [ "$conflict_count" -ge 6 ]; then
            # Real persistent conflict — return to executor for manual rebase
            log "WARN" "Merge conflict for $task_id (attempt $conflict_count) — returning to executor"
            bd_safe update "$task_id" --status=open --remove-label=approved \
                --notes="Persistent merge conflict on $branch after $conflict_count attempts. Rebase on $main_ref and resolve conflicts manually." >/dev/null 2>&1 || true
        else
            # Timing conflict — stay approved, skip this cycle, try next task
            # Next cycle merge queue will retry after other tasks have merged
            log "INFO" "Merge conflict for $task_id (attempt $conflict_count/6) — skipping, will retry next cycle"
            bd_safe update "$task_id" --notes="Merge conflict (attempt $conflict_count/6). Waiting for other merges to complete." >/dev/null 2>&1 || true
            return 1  # Signal to main() to try next approved task
        fi
        return 0
    fi

    # Rebase succeeded — push rebased branch, then squash merge
    git_nh push origin HEAD:"$branch" --force-with-lease 2>/dev/null || true
    git_nh checkout "$main_ref" 2>/dev/null || true

    if ! git_nh merge --squash "origin/$branch" 2>/dev/null; then
        # Should not happen after successful rebase, but safety net
        git_nh merge --abort 2>/dev/null || git_nh reset --hard "origin/$main_ref" 2>/dev/null || true
        log "ERROR" "Merge failed after successful rebase for $task_id"
        bd_safe update "$task_id" --status=open --remove-label=approved \
            --notes="Unexpected merge failure after rebase. Return to executor." >/dev/null 2>&1 || true
        return 0
    fi

    # Commit squash merge (v2.3.4: handle failure instead of || true)
    # If commit fails, staged changes from merge --squash poison the working tree.
    if ! git_nh commit -m "$task_title

Task: $task_id" 2>/dev/null; then
        log "ERROR" "Commit failed for $task_id — cleaning staged changes"
        git_nh reset --hard "origin/$main_ref" 2>/dev/null || true
        bd_safe update "$task_id" --status=open --remove-label=approved \
            --notes="Commit failed after squash merge. Return to executor." >/dev/null 2>&1 || true
        return 0
    fi

    if ! git_nh push origin "$main_ref" 2>/dev/null; then
        # Push failed — another task pushed to main between our merge and push
        git_nh reset --hard "origin/$main_ref" 2>/dev/null || true

        local conflict_count
        conflict_count=$(get_counter_value "$task_json" "merge-conflict")
        ((conflict_count++))
        set_counter_label "$task_id" "merge-conflict" "$conflict_count" "$task_json"

        if [ "$conflict_count" -ge 6 ]; then
            log "ERROR" "Push failed for $task_id (attempt $conflict_count) — returning to executor"
            bd_safe update "$task_id" --status=open --remove-label=approved \
                --notes="Push to $main_ref failed $conflict_count times. Rebase on $main_ref and retry." >/dev/null 2>&1 || true
        else
            log "INFO" "Push failed for $task_id (attempt $conflict_count/6) — will retry next cycle"
            bd_safe update "$task_id" --notes="Push failed (attempt $conflict_count/6). Will retry." >/dev/null 2>&1 || true
            return 1  # Try next approved task
        fi
        return 0
    fi

    # Verify main actually changed
    local main_after
    main_after=$(git rev-parse "$main_ref" 2>/dev/null || echo "unknown")

    if [ "$main_before" != "unknown" ] && [ "$main_before" = "$main_after" ]; then
        log "WARN" "Empty squash for $task_id — closing (no changes to merge)"
        bd_safe close "$task_id" --reason="Empty merge — branch changes already in main" >/dev/null 2>&1 || true
        bd_safe update "$task_id" --remove-label=approved --add-label=reviewed >/dev/null 2>&1 || true
        return 0
    fi

    # Close task
    bd_safe close "$task_id" >/dev/null 2>&1 || true
    bd_safe update "$task_id" --remove-label=approved --add-label=reviewed >/dev/null 2>&1 || true

    # Cleanup remote branch
    git_nh push origin --delete "$branch" 2>/dev/null || true

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

    # Try to merge one task per call (sequential, safe)
    # On conflict (return 1), skip to next approved task instead of blocking the queue
    local task_id
    for task_id in $tasks; do
        log "INFO" "Merge: $task_id"
        if merge_task "$task_id"; then
            # return 0 = merged or returned to executor — done for this cycle
            bd_safe sync 2>/dev/null || true
            return
        fi
        # return 1 = conflict, task stays approved — try next task
        log "INFO" "Skipped $task_id (conflict), trying next..."
    done
    bd_safe sync 2>/dev/null || true
}

main "$@"
