#!/bin/bash
# core/scripts/run-merge-queue.sh
# Hybrid merge worker — fast script path + Claude merger agent fallback.
# Part of v2.2 parallel review pipeline, upgraded in v2.3.11.
#
# Flow: approved task → try_fast_merge (rebase+squash+push)
#       → success → close → done
#       → fail → merger agent resolves conflicts → close → done
#       → agent fail → return to executor
#
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
MERGER_TIMEOUT="${MERGER_TIMEOUT:-5m}"

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

# === Fast merge path (no Claude, pure git) ===

# Shared variable for error context (read by run_merger_agent after failure)
FAST_MERGE_ERROR=""

try_fast_merge() {
    local branch=$1
    local main_ref=$2
    local task_title=$3
    local task_id=$4

    FAST_MERGE_ERROR=""

    # Checkout main, pull latest
    git_nh checkout "$main_ref" 2>/dev/null || return 1
    git_nh pull origin "$main_ref" 2>/dev/null || return 1

    # Try rebase: checkout branch, rebase on main
    git_nh checkout "origin/$branch" 2>/dev/null || return 1
    if ! FAST_MERGE_ERROR=$(git_nh rebase "$main_ref" 2>&1); then
        git_nh rebase --abort 2>/dev/null || true
        git_nh checkout "$main_ref" 2>/dev/null || true
        return 1
    fi

    # Rebase succeeded — push rebased branch, then squash merge
    git_nh push origin HEAD:"$branch" --force-with-lease 2>/dev/null || true
    git_nh checkout "$main_ref" 2>/dev/null || return 1

    if ! FAST_MERGE_ERROR=$(git_nh merge --squash "origin/$branch" 2>&1); then
        git_nh merge --abort 2>/dev/null || git_nh reset --hard "origin/$main_ref" 2>/dev/null || true
        return 1
    fi

    # Commit squash merge
    if ! FAST_MERGE_ERROR=$(git_nh commit -m "$task_title

Task: $task_id" 2>&1); then
        git_nh reset --hard "origin/$main_ref" 2>/dev/null || true
        return 1
    fi

    # Push to main
    if ! FAST_MERGE_ERROR=$(git_nh push origin "$main_ref" 2>&1); then
        git_nh reset --hard "origin/$main_ref" 2>/dev/null || true
        return 1
    fi

    return 0
}

# === Merger agent (Claude resolves conflicts) ===

run_merger_agent() {
    local task_id=$1
    local branch=$2
    local main_ref=$3
    local task_json=$4
    local error_context=${5:-"Unknown error"}

    local task_title
    task_title=$(echo "$task_json" | jq -r '.[0].title // "Task"' 2>/dev/null)

    # Build context for agent: branch diff + error info
    local branch_diff
    branch_diff=$(git diff "origin/$main_ref..origin/$branch" 2>/dev/null | head -500 || echo "No diff available")
    local branch_diff_stat
    branch_diff_stat=$(git diff --stat "origin/$main_ref..origin/$branch" 2>/dev/null || echo "No stats")

    # Load agent prompt
    local merger_prompt
    merger_prompt=$(cat "$PROJECT_DIR/.claude/agents/merger.md" 2>/dev/null || \
                    cat "$SCRIPT_DIR/../agents/merger.md" 2>/dev/null || echo "")

    if [ -z "$merger_prompt" ]; then
        log "ERROR" "Merger agent prompt not found"
        return 1
    fi

    local full_prompt="$merger_prompt

---
TASK_ID=$task_id
TASK_TITLE=$task_title
BRANCH=$branch
MAIN_REF=$main_ref
PROJECT_ROOT=$PROJECT_DIR

## BRANCH CHANGES (diff stat)
$branch_diff_stat

## BRANCH DIFF (first 500 lines)
\`\`\`diff
$branch_diff
\`\`\`

## CONFLICT INFO (why fast merge failed)
\`\`\`
$error_context
\`\`\`

## YOUR JOB
1. Fetch latest, checkout main
2. Resolve the conflict (rebase + resolve, or apply changes manually)
3. Squash merge into main, push
4. bd close $task_id on success
5. bd update $task_id --status=open --remove-label=approved --notes=\"reason\" on failure"

    local output_file="$LOGS_DIR/merger-$task_id.log"
    local model
    model=$(map_model "opus")

    log "INFO" "Launching merger agent for $task_id (model: $model, timeout: $MERGER_TIMEOUT)"
    run_claude_with_progress "$full_prompt" "$model" "$MERGER_TIMEOUT" "$output_file" "MERGE" "$LOGS_DIR" || {
        log "WARN" "Merger agent exited with error for $task_id"
        return 1
    }

    # Verify: was task closed by agent?
    local post_status
    post_status=$(bd_safe show "$task_id" --json 2>/dev/null | jq -r '.[0].status // "unknown"' 2>/dev/null)

    if [ "$post_status" = "closed" ]; then
        return 0
    fi

    # Agent didn't close task — check if it at least pushed to main
    local main_after
    main_after=$(git rev-parse "$main_ref" 2>/dev/null || echo "unknown")
    git_nh fetch origin 2>/dev/null || true
    local remote_after
    remote_after=$(git rev-parse "origin/$main_ref" 2>/dev/null || echo "unknown")

    if [ "$main_after" != "$remote_after" ]; then
        # Agent pushed but didn't close — close for it
        git_nh checkout "$main_ref" 2>/dev/null || true
        git_nh pull origin "$main_ref" 2>/dev/null || true
        bd_safe close "$task_id" >/dev/null 2>&1 || true
        bd_safe update "$task_id" --remove-label=approved --add-label=reviewed >/dev/null 2>&1 || true
        return 0
    fi

    return 1
}

# === Main merge logic ===

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
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        log "WARN" "Dirty working tree — cleaning up before merge"
        git_nh checkout "$main_ref" 2>/dev/null || true
        git_nh reset --hard "origin/$main_ref" 2>/dev/null || true
    fi

    # Fetch latest
    git_nh fetch origin 2>/dev/null || true

    # Check branch exists
    if ! git rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
        local close_reason
        close_reason=$(echo "$task_json" | jq -r '.[0].close_reason // ""' 2>/dev/null)
        if echo "$close_reason" | grep -q "NO_MERGE:"; then
            log "SUCCESS" "APPROVED (no merge needed): $task_id"
            bd_safe update "$task_id" --remove-label=approved --add-label=reviewed >/dev/null 2>&1 || true
            return 0
        fi

        log "ERROR" "Branch $branch not found for $task_id"
        bd_safe update "$task_id" --status=open --remove-label=approved \
            --notes="Merge failed: branch $branch not found" >/dev/null 2>&1 || true
        return 0
    fi

    # Record main SHA before merge
    local main_before
    main_before=$(git rev-parse "$main_ref" 2>/dev/null || echo "unknown")

    # === Step 1: Try fast merge (pure git, no Claude) ===
    log "INFO" "Merging $task_id ($branch)"

    if try_fast_merge "$branch" "$main_ref" "$task_title" "$task_id"; then
        # Fast merge succeeded — verify not empty squash
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
        git_nh push origin --delete "$branch" 2>/dev/null || true
        log "SUCCESS" "MERGED: $task_id ($task_title)"
        return 0
    fi

    # === Step 2: Fast merge failed — clean state ===
    log "INFO" "Fast merge failed for $task_id — checking if agent needed"
    git_nh checkout "$main_ref" 2>/dev/null || true
    git_nh reset --hard "origin/$main_ref" 2>/dev/null || true

    # Check if branch has any actual changes vs main (empty merge detection)
    local has_diff
    has_diff=$(git diff --stat "origin/$main_ref..origin/$branch" 2>/dev/null | tail -1 || echo "")
    if [ -z "$has_diff" ]; then
        log "WARN" "Empty squash for $task_id — closing (no changes to merge)"
        bd_safe close "$task_id" --reason="Empty merge — branch changes already in main" >/dev/null 2>&1 || true
        bd_safe update "$task_id" --remove-label=approved --add-label=reviewed >/dev/null 2>&1 || true
        return 0
    fi

    # === Step 3: Launch merger agent ===
    log "INFO" "Launching merger agent for $task_id"

    if run_merger_agent "$task_id" "$branch" "$main_ref" "$task_json" "$FAST_MERGE_ERROR"; then
        # Agent succeeded
        git_nh push origin --delete "$branch" 2>/dev/null || true
        log "SUCCESS" "MERGED (agent): $task_id ($task_title)"
        return 0
    fi

    # === Step 4: Agent failed — return to executor ===
    log "WARN" "Merger agent failed for $task_id — returning to executor"
    # Clean state in case agent left dirty tree
    git_nh checkout "$main_ref" 2>/dev/null || true
    git_nh reset --hard "origin/$main_ref" 2>/dev/null || true
    bd_safe update "$task_id" --status=open --remove-label=approved \
        --notes="Merge failed (script + agent). Rebase $branch on $main_ref and resolve conflicts manually." >/dev/null 2>&1 || true
    return 0
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

    # Process one task per call (sequential, safe)
    local task_id
    for task_id in $tasks; do
        log "INFO" "Merge: $task_id"
        merge_task "$task_id"
        bd_safe sync 2>/dev/null || true
        return
    done
}

main "$@"
