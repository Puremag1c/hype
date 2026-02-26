#!/bin/bash
# core/scripts/run-seniors.sh
# Parallel reviewer launcher — part of v2.2 review pipeline.
# Runs up to MAX_PARALLEL_SENIORS concurrent code reviews.
#
# Each reviewer: claim → build context → claude review → handle result
# Lock-based backpressure via .hype-worktrees/senior-N.lock
#
# Usage: ./scripts/run-seniors.sh

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

MAX_PARALLEL="${MAX_PARALLEL_SENIORS:-3}"
REVIEW_TIMEOUT="${REVIEW_TIMEOUT:-8m}"
WORKTREES_DIR="$PROJECT_DIR/.hype-worktrees"

mkdir -p "$LOGS_DIR" "$WORKTREES_DIR"

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

    printf "${gray}%s${reset} [${hype_colored} REVIEW] ${color}%s${reset}: %s\n" "$(date '+%H:%M:%S')" "$level" "$msg"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [HYPE REVIEW] $level: $msg" >> "$LOGS_DIR/hype.log"
}

# === Slot management (lock-based backpressure) ===

count_active_seniors() {
    local count=0
    for lock in "$WORKTREES_DIR"/senior-*.lock; do
        [ -d "$lock" ] && ((count++)) || true
    done 2>/dev/null
    echo "$count"
}

find_free_senior_slot() {
    local slot=0
    while true; do
        local lock_dir="$WORKTREES_DIR/senior-$slot.lock"

        # Stale lock cleanup (>20 minutes = crashed senior)
        if [ -d "$lock_dir" ]; then
            local lock_age
            lock_age=$(( $(date +%s) - $(stat -f %m "$lock_dir" 2>/dev/null || stat -c %Y "$lock_dir" 2>/dev/null || echo 0) ))
            if [ "$lock_age" -gt 1200 ]; then
                rmdir "$lock_dir" 2>/dev/null || true
            fi
        fi

        if mkdir "$lock_dir" 2>/dev/null; then
            echo "$slot"
            return 0
        fi

        ((slot++))
        if [ "$slot" -ge 20 ]; then
            return 1  # Safety: max 20 slots
        fi
    done
}

cleanup_senior_slot() {
    local slot=$1
    rmdir "$WORKTREES_DIR/senior-$slot.lock" 2>/dev/null || true
}

# === Review context builder ===

get_review_model() {
    local task_json=$1
    local task_model reject_count
    task_model=$(echo "$task_json" | jq -r '.[0].labels[]? | select(startswith("model:")) | split(":")[1]' 2>/dev/null | head -1)
    reject_count=$(get_counter_value "$task_json" "reject")

    if [ "$reject_count" -ge 4 ]; then
        echo "opus"
    elif [ "$reject_count" -ge 2 ] && [ "$task_model" = "opus" ]; then
        echo "opus"
    else
        echo "sonnet"
    fi
}

build_review_context() {
    local task_id=$1
    local task_json=$2
    local branch_name="task/beads-$task_id"
    local base_branch
    base_branch=$(get_base_branch)

    local task_title task_description task_notes done_when
    task_title=$(echo "$task_json" | jq -r '.[0].title // "Unknown"' 2>/dev/null)
    task_description=$(echo "$task_json" | jq -r '.[0].description // ""' 2>/dev/null)
    task_notes=$(echo "$task_json" | jq -r '.[0].notes // ""' 2>/dev/null)
    done_when=$(echo "$task_description" | grep -oE 'done_when:\s*[^\n]+' | sed 's/done_when:\s*//' || true)

    local commits diff diff_stat
    commits=$(git log --oneline "origin/$base_branch..origin/$branch_name" 2>/dev/null || echo "No commits")
    diff_stat=$(git diff --stat "origin/$base_branch..origin/$branch_name" 2>/dev/null | tail -5 || echo "No changes")
    diff=$(git diff "origin/$base_branch..origin/$branch_name" 2>/dev/null | head -500 || echo "No diff")

    local coder_log=""
    local coder_log_file="$LOGS_DIR/coder-$task_id.log"
    if [ -f "$coder_log_file" ]; then
        coder_log=$(tail -50 "$coder_log_file" 2>/dev/null || true)
    fi

    # Security warning (v2.1.8: soft scanner)
    local secrets_warning=""
    if echo "$task_json" | jq -r '.[0].labels[]?' 2>/dev/null | grep -q "^secrets-warning$"; then
        secrets_warning="### SECURITY WARNING
The automated secret scanner flagged potential credentials in this diff.
**Your job**: Determine if these are REAL secrets (API keys, passwords, tokens) or TEST DATA (mock credentials, fixtures, test constants).
- Real secrets → REJECT the task. Explain what must be removed.
- Test data / mock credentials → safe to proceed, ignore the warning."
    fi

    # CHANGELOG context (prevent regression)
    local changelog_context=""
    if type get_changelog_context &>/dev/null; then
        changelog_context=$(get_changelog_context 3 2>/dev/null || true)
    fi

    cat <<EOF
## Task: $task_title
ID: $task_id
Branch: $branch_name
${secrets_warning:+
$secrets_warning
}
### Done When
$done_when

### Task Notes
$task_notes

### Commits
$commits

### Diff Stats
$diff_stat

### Diff (first 500 lines)
\`\`\`diff
$diff
\`\`\`

### Executor Log (last 50 lines)
\`\`\`
$coder_log
\`\`\`
${changelog_context:+
$changelog_context
}
EOF
}

# === Preflight check (simplified) ===

preflight_check() {
    local task_id=$1
    local task_json=$2
    local branch_name="task/beads-$task_id"
    local base_branch
    base_branch=$(get_base_branch)

    # Audit tasks don't need branch checks
    if is_audit_task "$task_json"; then
        echo "AUDIT_REVIEW"
        return 0
    fi

    # Check branch exists
    if ! git rev-parse --verify "origin/$branch_name" >/dev/null 2>&1; then
        echo "NO_BRANCH"
        return 0
    fi

    # Check has commits
    local commit_count
    commit_count=$(git rev-list --count "origin/$base_branch..origin/$branch_name" 2>/dev/null || echo "0")
    if [ "$commit_count" -eq 0 ]; then
        # Distinguish "no work done" from "work already merged"
        local main_sha branch_sha
        main_sha=$(git rev-parse "origin/$base_branch" 2>/dev/null || echo "")
        branch_sha=$(git rev-parse "origin/$branch_name" 2>/dev/null || echo "")
        if [ -n "$main_sha" ] && [ "$main_sha" = "$branch_sha" ]; then
            echo "ALREADY_MERGED"
            return 0
        fi
        echo "NO_COMMITS"
        return 0
    fi

    # Check for potential secrets in diff (soft warning — reviewer decides)
    if git diff "origin/$base_branch..origin/$branch_name" 2>/dev/null | grep -qiE "(sk-[a-zA-Z0-9]{20,}|api_key\s*=|password\s*=|secret\s*=|\.env)"; then
        echo "SECRETS_WARNING"
        return 0
    fi

    echo "PASS"
}

# === Run single reviewer ===

run_reviewer() {
    local slot=$1
    local task_id=$2

    local task_json
    task_json=$(bd_safe show "$task_id" --json 2>/dev/null || echo "[]")

    # Atomic claim (lock + label)
    if ! try_claim_for_review "$task_id" "$WORKTREES_DIR"; then
        log "INFO" "Task $task_id already claimed by another reviewer"
        cleanup_senior_slot "$slot"
        return 0
    fi

    # Ensure cleanup on exit
    trap "release_review_lock '$task_id' '$WORKTREES_DIR'; cleanup_senior_slot '$slot'" EXIT INT TERM

    # Fetch latest (shared, but safe for reads)
    git fetch origin 2>/dev/null || true

    # Preflight
    local preflight
    preflight=$(preflight_check "$task_id" "$task_json")

    case "$preflight" in
        AUDIT_REVIEW)
            # Audit tasks: approve directly (no code to review)
            log "INFO" "Audit task $task_id — approving"
            approve_task "$task_id"
            release_review_lock "$task_id" "$WORKTREES_DIR"
            cleanup_senior_slot "$slot"
            trap - EXIT INT TERM
            return 0
            ;;
        SECRETS_WARNING)
            # Soft warning: add label, let Claude reviewer decide (not hard reject)
            bd_safe update "$task_id" --add-label=secrets-warning >/dev/null 2>&1 || true
            log "WARN" "SECRETS WARNING: $task_id - potential secrets in diff, reviewer will decide"
            # Re-fetch task_json so build_review_context sees the new label
            task_json=$(bd_safe show "$task_id" --json 2>/dev/null || echo "[]")
            # Fall through to Claude review (no return)
            ;;
        ALREADY_MERGED)
            log "INFO" "Task $task_id branch identical to main — work already merged, closing"
            bd_safe close "$task_id" --reason="Work already merged to main (branch tip = main tip)." 2>/dev/null || true
            release_review_lock "$task_id" "$WORKTREES_DIR"
            cleanup_senior_slot "$slot"
            trap - EXIT INT TERM
            return 0
            ;;
        NO_BRANCH|NO_COMMITS)
            log "WARN" "Preflight failed for $task_id: $preflight"
            # Reject back to coder with circuit breaker check
            local reject_count
            reject_count=$(get_counter_value "$task_json" "reject")
            ((reject_count++))
            set_counter_label "$task_id" "reject" "$reject_count" "$task_json"

            if [ "$reject_count" -ge 4 ]; then
                # Circuit breaker: if task was already reformulated AND same rejection reason → user-escalation
                local has_reformulated last_reject_reason
                has_reformulated=$(echo "$task_json" | jq -r '[.[0].labels[]? | select(. == "reformulated")] | length' 2>/dev/null || echo "0")
                last_reject_reason=$(echo "$task_json" | jq -r '.[0].labels[]? | select(startswith("last-reject:")) | split(":")[1]' 2>/dev/null | head -1)

                if [ "$has_reformulated" != "0" ] && [ "$last_reject_reason" = "$preflight" ]; then
                    # CIRCUIT BREAKER: same reason after reformulation → escalate to user
                    log "WARN" "CIRCUIT BREAKER: $task_id - $preflight after reformulation (same reason). Escalating to user."
                    bd_safe update "$task_id" --status=open \
                        --remove-label=reviewing --remove-label=coder \
                        --remove-label=blocked:troubleshoot \
                        --add-label=user-escalation \
                        --notes="Circuit breaker: $preflight persists after reformulation. Automated resolution impossible — escalating to user." >/dev/null 2>&1 || true
                else
                    # Track rejection reason for circuit breaker detection on next cycle
                    if [ -n "$last_reject_reason" ]; then
                        bd_safe update "$task_id" --remove-label="last-reject:$last_reject_reason" >/dev/null 2>&1 || true
                    fi
                    bd_safe update "$task_id" --add-label="last-reject:$preflight" >/dev/null 2>&1 || true

                    # Route to troubleshooter
                    reject_from_review "$task_id"
                    bd_safe update "$task_id" --add-label=blocked:troubleshoot \
                        --notes="Preflight: $preflight after $reject_count attempts. Escalated." >/dev/null 2>&1 || true
                    log "WARN" "TROUBLESHOOT: $task_id - $preflight (reject:$reject_count)"
                fi
            else
                # Model escalation at reject >= 2 (same as Claude rejection path)
                if [ "$reject_count" -ge 2 ]; then
                    local current_model
                    current_model=$(echo "$task_json" | jq -r '.[0].labels[]? | select(startswith("model:")) | split(":")[1]' 2>/dev/null | head -1)
                    current_model=${current_model:-sonnet}
                    local next_model="$current_model"
                    [ "$current_model" = "haiku" ] && next_model="sonnet"
                    [ "$current_model" = "sonnet" ] && next_model="opus"
                    if [ "$next_model" != "$current_model" ]; then
                        clean_model_label "$task_id" "$next_model"
                        log "WARN" "ESCALATE: $task_id $current_model → $next_model (reject:$reject_count, $preflight)"
                    fi
                fi
                reject_from_review "$task_id"
            fi

            release_review_lock "$task_id" "$WORKTREES_DIR"
            cleanup_senior_slot "$slot"
            trap - EXIT INT TERM
            return 0
            ;;
    esac

    # Build context
    local context
    context=$(build_review_context "$task_id" "$task_json")

    # Build full prompt
    local reviewer_prompt
    reviewer_prompt=$(cat "$PROJECT_DIR/.claude/agents/senior.md" 2>/dev/null || cat "$SCRIPT_DIR/../agents/senior.md" 2>/dev/null)

    local review_model
    review_model=$(get_review_model "$task_json")
    local mapped_model
    mapped_model=$(map_model "$review_model")

    local full_prompt="$reviewer_prompt

---
TASK_ID=$task_id
PROJECT_ROOT=$PROJECT_DIR

## PRE-COMPUTED CONTEXT
$context

## YOUR JOB
1. Review the diff above
2. Check if it matches done_when criteria
3. If good: bd update --remove-label=reviewing --add-label=approved
4. If bad: bd update --status=open --remove-label=reviewing --notes=\"reason\""

    # Run reviewer
    local output_file="$LOGS_DIR/senior-$task_id.log"
    local exit_code=0
    run_claude_with_progress "$full_prompt" "$mapped_model" "$REVIEW_TIMEOUT" "$output_file" "REVIEW $slot" "$LOGS_DIR" || exit_code=$?

    # Timeout is not a rejection — return to queue without incrementing reject:N
    if [ "$exit_code" -eq 124 ]; then
        log "WARN" "REVIEW TIMEOUT: $task_id (${REVIEW_TIMEOUT}) — returning to queue"
        bd_safe update "$task_id" --add-label=needs-review --remove-label=reviewing >/dev/null 2>&1 || true
        release_review_lock "$task_id" "$WORKTREES_DIR"
        cleanup_senior_slot "$slot"
        trap - EXIT INT TERM
        return 0
    fi

    # Post-processing: check what reviewer did
    local updated_json
    updated_json=$(bd_safe show "$task_id" --json 2>/dev/null || echo "[]")

    # v2.3.19: Ownership check — if coder label appeared, another process claimed the task
    # (reviewer claude rejects → sets open → coder claims → in_progress+coder)
    local has_coder
    has_coder=$(echo "$updated_json" | jq -r '[.[0].labels[]? | select(. == "coder")] | length' 2>/dev/null || echo "0")
    if [ "$has_coder" != "0" ]; then
        log "WARN" "Review lost ownership of $task_id (coder label present)"
        # Still increment reject:N so escalation ladder doesn't stall
        local reject_count
        reject_count=$(get_counter_value "$updated_json" "reject")
        ((reject_count++))
        set_counter_label "$task_id" "reject" "$reject_count" "$updated_json"
        # Model escalation (coder already running, but next cycle benefits)
        if [ "$reject_count" -ge 2 ]; then
            local current_model
            current_model=$(echo "$updated_json" | jq -r '.[0].labels[]? | select(startswith("model:")) | split(":")[1]' 2>/dev/null | head -1)
            current_model=${current_model:-sonnet}
            local next_model="$current_model"
            [ "$current_model" = "haiku" ] && next_model="sonnet"
            [ "$current_model" = "sonnet" ] && next_model="opus"
            if [ "$next_model" != "$current_model" ]; then
                clean_model_label "$task_id" "$next_model"
                log "WARN" "ESCALATE: $task_id $current_model → $next_model (reject:$reject_count, lost ownership)"
            fi
        fi
        release_review_lock "$task_id" "$WORKTREES_DIR"
        cleanup_senior_slot "$slot"
        trap - EXIT INT TERM
        return 0
    fi

    local task_status
    task_status=$(echo "$updated_json" | jq -r '.[0].status // "unknown"' 2>/dev/null)
    local has_approved
    has_approved=$(echo "$updated_json" | jq -r '[.[0].labels[]? | select(. == "approved")] | length' 2>/dev/null || echo "0")

    if [ "$task_status" = "closed" ]; then
        # Reviewer closed task (NO_MERGE case)
        log "SUCCESS" "CLOSED (no merge): $task_id"
    elif [ "$has_approved" != "0" ]; then
        # Approved — merge queue will pick it up
        log "SUCCESS" "APPROVED: $task_id"
    elif [ "$task_status" = "open" ]; then
        # Rejected — increment reject:N and escalate
        local reject_count
        reject_count=$(get_counter_value "$updated_json" "reject")
        ((reject_count++))
        set_counter_label "$task_id" "reject" "$reject_count" "$updated_json"

        local notes
        notes=$(echo "$updated_json" | jq -r '.[0].notes // ""' 2>/dev/null | tail -1 | head -c 80)

        if [ "$reject_count" -ge 4 ]; then
            bd_safe update "$task_id" --add-label=blocked:troubleshoot \
                --notes="Escalated: returned $reject_count times. Last: $notes" >/dev/null 2>&1 || true
            log "WARN" "TROUBLESHOOT: $task_id (reject:$reject_count)"
        elif [ "$reject_count" -ge 2 ]; then
            # Model escalation for coder
            local current_model
            current_model=$(echo "$updated_json" | jq -r '.[0].labels[]? | select(startswith("model:")) | split(":")[1]' 2>/dev/null | head -1)
            current_model=${current_model:-sonnet}
            local next_model="$current_model"
            [ "$current_model" = "haiku" ] && next_model="sonnet"
            [ "$current_model" = "sonnet" ] && next_model="opus"
            if [ "$next_model" != "$current_model" ]; then
                clean_model_label "$task_id" "$next_model"
                log "WARN" "ESCALATE: $task_id $current_model → $next_model (reject:$reject_count)"
            fi
        fi
        log "WARN" "REJECTED: $task_id - ${notes:-no reason} (reject:$reject_count)"
    else
        # No action — reviewer didn't do anything
        local reject_count
        reject_count=$(get_counter_value "$updated_json" "reject")
        ((reject_count++))
        set_counter_label "$task_id" "reject" "$reject_count" "$updated_json"

        if [ "$reject_count" -ge 4 ]; then
            # v2.3.16: Clean state — remove reviewing/needs-review, set open so troubleshooter finds it
            bd_safe update "$task_id" --status=open \
                --remove-label=reviewing --remove-label=needs-review \
                --add-label=blocked:troubleshoot \
                --notes="Reviewer failed to act after $reject_count attempts." >/dev/null 2>&1 || true
            log "WARN" "TROUBLESHOOT: $task_id - no review action (reject:$reject_count)"
        elif [ "$reject_count" -ge 2 ]; then
            local current_model
            current_model=$(echo "$updated_json" | jq -r '.[0].labels[]? | select(startswith("model:")) | split(":")[1]' 2>/dev/null | head -1)
            current_model=${current_model:-sonnet}
            local next_model="$current_model"
            [ "$current_model" = "haiku" ] && next_model="sonnet"
            [ "$current_model" = "sonnet" ] && next_model="opus"
            if [ "$next_model" != "$current_model" ]; then
                clean_model_label "$task_id" "$next_model"
            fi
            # Re-add needs-review (v2.1.10: Claude may have removed it)
            bd_safe update "$task_id" --add-label=needs-review --remove-label=reviewing \
                --notes="Review escalated (reject:$reject_count)." >/dev/null 2>&1 || true
        else
            log "WARN" "REVIEW RETRY: $task_id - no action (reject:$reject_count)"
            # Re-add needs-review (v2.1.10 fix)
            bd_safe update "$task_id" --add-label=needs-review --remove-label=reviewing >/dev/null 2>&1 || true
        fi
    fi

    # Cleanup
    release_review_lock "$task_id" "$WORKTREES_DIR"
    cleanup_senior_slot "$slot"
    trap - EXIT INT TERM
}

# === Get review-ready tasks ===

get_review_tasks() {
    local cache="${HYPE_IN_PROGRESS_CACHE:-}"
    if [ -n "$cache" ]; then
        echo "$cache"
    else
        bd_safe list --status=in_progress --json --limit 0 2>/dev/null || echo "[]"
    fi | jq -r '.[] | select((.labels // []) | index("needs-review")) | select((.labels // []) | index("coder") | not) | select((.labels // []) | index("trigger") | not) | select(.title | test("^milestone:") | not) | .id' 2>/dev/null || echo ""
}

# === Main ===

main() {
    echo ""
    echo "" >> "$LOGS_DIR/hype.log"

    local active
    active=$(count_active_seniors)

    if [ "$active" -ge "$MAX_PARALLEL" ]; then
        log "INFO" "Review queue full ($active/$MAX_PARALLEL)"
        exit 0
    fi

    local available=$((MAX_PARALLEL - active))

    # Fetch in_progress tasks once (from cache or fresh)
    local all_in_progress
    if [ -n "${HYPE_IN_PROGRESS_CACHE:-}" ]; then
        all_in_progress="$HYPE_IN_PROGRESS_CACHE"
    else
        all_in_progress=$(bd_safe list --status=in_progress --json --limit 0 2>/dev/null || echo "[]")
    fi

    local tasks
    tasks=$(echo "$all_in_progress" | jq -r '.[] | select((.labels // []) | index("needs-review")) | select((.labels // []) | index("coder") | not) | select((.labels // []) | index("trigger") | not) | select(.title | test("^milestone:") | not) | .id' 2>/dev/null || echo "")

    if [ -z "$tasks" ]; then
        log "INFO" "No tasks need review"
        exit 0
    fi

    local task_count
    task_count=$(echo "$tasks" | wc -l | tr -d ' ')
    log "INFO" "Checking $task_count review tasks (slots: $available/$MAX_PARALLEL)"

    local started=0
    for task_id in $tasks; do
        if [ $started -ge $available ]; then
            break
        fi

        local slot
        slot=$(find_free_senior_slot) || {
            log "ERROR" "No reviewer slots available"
            break
        }

        # Extract title from cached list data (avoid extra bd show per task)
        local task_title
        task_title=$(echo "$all_in_progress" | jq -r ".[] | select(.id == \"$task_id\") | .title // \"unknown\"" 2>/dev/null | head -c 40 || echo "unknown")
        log "INFO" "Review: $task_id \"$task_title\" (slot $slot)"

        ( run_reviewer "$slot" "$task_id" ) &
        ((started++))
    done

    disown -a 2>/dev/null || true
    log "INFO" "Started $started reviewer(s)"
}

main "$@"
