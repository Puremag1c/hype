#!/bin/bash
# core/scripts/run-senior-executor.sh
# Обрабатывает задачи с label=needs-review через Senior Executor агента.
# Работает ПОСЛЕДОВАТЕЛЬНО — один PR за раз (quality gate).
#
# Оптимизации:
# - Pre-flight checks (reject без Claude если очевидные проблемы)
# - Context injection (diff/commits/task передаются в prompt)
# - Tiered review (opus задачи → opus review, остальные → sonnet)
# - Executor logs передаются для контекста
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
REVIEW_TIMEOUT="${REVIEW_TIMEOUT:-5m}"  # Shorter timeout for optimized reviews

mkdir -p "$LOGS_DIR"

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

    printf "${gray}%s${reset} [${hype_colored} CHECK] ${color}%s${reset}: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [HYPE CHECK] $level: $msg" >> "$LOGS_DIR/hype.log"
}

# === Get tasks needing review ===

get_review_tasks() {
    # Tasks with label=needs-review (executor label irrelevant - needs-review means executor finished)
    # Exclude milestone tasks (they should never be in review queue)
    bd_safe list --status=in_progress --json 2>/dev/null | \
        jq -r '.[] | select(.labels | index("needs-review")) | select((.labels // []) | any(test("^milestone:")) | not) | .id' 2>/dev/null || true
}

# === Pre-flight checks (reject without Claude) ===
# Note: is_audit_task() is defined in common.sh

preflight_check() {
    local task_id=$1
    local branch_name="task/beads-$task_id"
    local task_json=$2

    # Check 0: Is this an audit task? (different flow)
    if is_audit_task "$task_json"; then
        # Audit tasks don't need commits - they produce findings in notes
        local notes
        notes=$(echo "$task_json" | jq -r '.[0].notes // ""' 2>/dev/null)

        # Check that executor wrote findings (at least 50 chars)
        if [ -z "$notes" ] || [ ${#notes} -lt 50 ]; then
            echo "NO_FINDINGS"
            return 0
        fi

        # Route to Architect for review
        echo "AUDIT_REVIEW"
        return 0
    fi

    # Check 1: Branch exists?
    if ! git rev-parse --verify "$branch_name" &>/dev/null; then
        if ! git rev-parse --verify "origin/$branch_name" &>/dev/null; then
            echo "NO_BRANCH"
            return 0
        fi
    fi

    # Fetch and checkout branch for checks
    git fetch origin "$branch_name" 2>/dev/null || true

    # Check 2: Has commits?
    local commit_count
    commit_count=$(git log --oneline "origin/main..origin/$branch_name" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$commit_count" -eq 0 ]; then
        echo "NO_COMMITS"
        return 0
    fi

    # Check 3: Secrets in diff?
    if git diff "origin/main..origin/$branch_name" 2>/dev/null | grep -qiE "(sk-[a-zA-Z0-9]{20,}|api_key\s*=|password\s*=|secret\s*=|\.env)"; then
        echo "SECRETS_DETECTED"
        return 0
    fi

    echo "PASS"
}

# === Get review model based on task model ===

get_review_model() {
    local task_json=$1

    # Extract model from task labels (model:opus, model:sonnet, model:haiku)
    local task_model
    task_model=$(echo "$task_json" | jq -r '.[0].labels[]? | select(startswith("model:")) | split(":")[1]' 2>/dev/null | head -1)

    # Tiered review: opus tasks → opus review, others → sonnet
    if [ "$task_model" = "opus" ]; then
        echo "opus"
    else
        echo "sonnet"
    fi
}

# === Route audit task to Architect ===

route_audit_to_architect() {
    local task_id=$1
    local task_json=$2

    # Extract task details
    local task_title task_description task_notes
    task_title=$(echo "$task_json" | jq -r '.[0].title // "Unknown"' 2>/dev/null)
    task_description=$(echo "$task_json" | jq -r '.[0].description // ""' 2>/dev/null)
    task_notes=$(echo "$task_json" | jq -r '.[0].notes // ""' 2>/dev/null)

    # Check if architect agent exists
    local agent_file=".claude/agents/architect.md"
    local agent_prompt
    if [ -f "$agent_file" ]; then
        agent_prompt=$(cat "$agent_file")
    else
        # Fallback minimal prompt
        agent_prompt="# Architect
You review audit findings and decide next steps."
    fi

    local full_prompt="$agent_prompt

---
MODE: audit_review
TASK_ID: $task_id
PROJECT_ROOT: $PROJECT_DIR

## AUDIT TASK
Title: $task_title

### Description
$task_description

### Findings (from executor)
$task_notes

## YOUR JOB
1. Read the audit findings above
2. Decide:
   - If findings show everything is OK → bd close $task_id --reason=\"Audit passed: <summary>\"
   - If findings show issues → create fix tasks with bd create, then bd close $task_id
   - If critical issues → create P0 tasks
3. Always close the audit task when done"

    local output_file="$LOGS_DIR/architect-audit-$task_id.log"
    local mapped_model
    mapped_model=$(map_model "opus")

    log "INFO" "Running Architect for audit review"

    set -o pipefail
    if printf '%s' "$full_prompt" | timeout_cmd "${REVIEW_TIMEOUT:-5m}" claude --print --model "$mapped_model" 2>&1 | strip_ansi | tee "$output_file" >/dev/null; then
        log "INFO" "Architect audit review completed for $task_id"
    else
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            log "WARN" "Architect audit review timeout for $task_id"
        else
            log "ERROR" "Architect audit review failed for $task_id (exit: $exit_code)"
        fi
    fi
    set +o pipefail

    # Check result
    local updated_json
    updated_json=$(bd_safe show "$task_id" --json 2>/dev/null || echo "[]")
    local task_status
    task_status=$(echo "$updated_json" | jq -r '.[0].status // "unknown"' 2>/dev/null || echo "unknown")

    if [ "$task_status" = "closed" ]; then
        log "SUCCESS" "AUDIT CLOSED: $task_id"
        bd_safe update "$task_id" --remove-label=needs-review --remove-label=executor --add-label=reviewed >/dev/null 2>&1 || true
    else
        # Architect didn't close - might have created tasks, clean up labels
        bd_safe update "$task_id" --remove-label=needs-review --remove-label=executor >/dev/null 2>&1 || true
        log "WARN" "AUDIT PENDING: $task_id - Architect may have created follow-up tasks"
    fi
}

# === Build context for Claude ===

build_review_context() {
    local task_id=$1
    local task_json=$2
    local branch_name="task/beads-$task_id"

    # Task details
    local task_title task_description task_notes done_when
    task_title=$(echo "$task_json" | jq -r '.[0].title // "Unknown"' 2>/dev/null)
    task_description=$(echo "$task_json" | jq -r '.[0].description // ""' 2>/dev/null)
    task_notes=$(echo "$task_json" | jq -r '.[0].notes // ""' 2>/dev/null)
    done_when=$(echo "$task_description" | grep -oE 'done_when:\s*[^\n]+' | sed 's/done_when:\s*//' || true)

    # Git data
    local commits diff diff_stat
    commits=$(git log --oneline "origin/main..origin/$branch_name" 2>/dev/null || echo "No commits")
    diff_stat=$(git diff --stat "origin/main..origin/$branch_name" 2>/dev/null | tail -5 || echo "No changes")
    diff=$(git diff "origin/main..origin/$branch_name" 2>/dev/null | head -500 || echo "No diff")

    # Executor logs (last 50 lines)
    local executor_log=""
    local executor_log_file="$LOGS_DIR/executor-$task_id.log"
    if [ -f "$executor_log_file" ]; then
        executor_log=$(tail -50 "$executor_log_file" 2>/dev/null || true)
    fi

    cat <<EOF
## Task: $task_title
ID: $task_id
Branch: $branch_name

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
$executor_log
\`\`\`
EOF
}

# === Process single review task ===

process_review() {
    local task_id=$1

    log "INFO" "Processing review for $task_id"

    # Get task details
    local task_json
    task_json=$(bd_safe show "$task_id" --json 2>/dev/null || echo "[]")

    # Validate task exists (race condition protection)
    local task_title
    task_title=$(echo "$task_json" | jq -r '.[0].title // empty' 2>/dev/null || true)

    if [ -z "$task_title" ]; then
        log "WARN" "Task $task_id not found or invalid (race condition?), skipping"
        return 0
    fi

    # === PRE-FLIGHT CHECKS ===
    local preflight_result
    preflight_result=$(preflight_check "$task_id" "$task_json")

    case "$preflight_result" in
        NO_BRANCH)
            log "WARN" "REJECT: $task_id - no branch found"
            bd_safe update "$task_id" --status=open --remove-label=needs-review --remove-label=executor \
                --notes="Review rejected: Branch task/beads-$task_id not found. Please push your changes."
            return 0
            ;;
        NO_COMMITS)
            log "WARN" "REJECT: $task_id - no commits in branch"
            bd_safe update "$task_id" --status=open --remove-label=needs-review --remove-label=executor \
                --notes="Review rejected: No commits found. Please implement the task."
            return 0
            ;;
        SECRETS_DETECTED)
            log "ERROR" "REJECT: $task_id - secrets detected in diff"
            bd_safe update "$task_id" --status=open --remove-label=needs-review --remove-label=executor \
                --notes="SECURITY: Potential secrets detected in diff. Remove sensitive data and resubmit."
            return 0
            ;;
        NO_FINDINGS)
            log "WARN" "REJECT: $task_id - audit task has no findings in notes"
            # Check retry count for escalation
            local audit_retry
            audit_retry=$(echo "$task_json" | jq -r '.[0].labels[]? | select(startswith("audit-retry:")) | split(":")[1]' 2>/dev/null | head -1)
            audit_retry=${audit_retry:-0}

            if [ "$audit_retry" -ge 2 ]; then
                # Escalate to Architect - auditor couldn't produce findings
                local task_title task_desc task_notes
                task_title=$(echo "$task_json" | jq -r '.[0].title // "Unknown"' 2>/dev/null)
                task_desc=$(echo "$task_json" | jq -r '.[0].description // ""' 2>/dev/null)
                task_notes=$(echo "$task_json" | jq -r '.[0].notes // ""' 2>/dev/null)

                log "WARN" "ESCALATE: $task_id - audit failed after 3 attempts, creating architect task"
                bd_safe create --title="Review failed audit: $task_title" --type=task --priority=1 \
                    --labels="model:opus,escalation" \
                    --description="## Context
Audit task $task_id failed to produce findings after 3 attempts (sonnet + opus).

## Original Task
**Title:** $task_title
**Description:** $task_desc

## Auditor Notes
$task_notes

## Required Action
1. Review why auditor couldn't complete this task
2. Either: reformulate the audit task, or close as not applicable
3. Close $task_id with appropriate reason" >/dev/null 2>&1 || true

                bd_safe update "$task_id" --status=open --remove-label=needs-review --remove-label=executor \
                    --add-label=blocked:escalated \
                    --notes="Escalated to Architect: auditor couldn't produce findings after 3 attempts."
            else
                # Determine current model and escalate one level up
                local current_model
                current_model=$(echo "$task_json" | jq -r '.[0].labels[]? | select(startswith("model:")) | split(":")[1]' 2>/dev/null | head -1)
                current_model=${current_model:-sonnet}

                local next_retry=$((audit_retry + 1))

                if [ "$current_model" = "haiku" ]; then
                    # haiku → sonnet
                    log "INFO" "RETRY: $task_id - haiku → sonnet (attempt $next_retry)"
                    bd_safe update "$task_id" --status=open --remove-label=needs-review --remove-label=executor \
                        --remove-label="audit-retry:$audit_retry" --remove-label=model:haiku \
                        --add-label=model:sonnet --add-label="audit-retry:$next_retry" \
                        --notes="Retry $next_retry: escalated haiku → sonnet. Findings required (min 50 chars)."
                elif [ "$current_model" = "sonnet" ]; then
                    # sonnet → opus
                    log "INFO" "RETRY: $task_id - sonnet → opus (attempt $next_retry)"
                    bd_safe update "$task_id" --status=open --remove-label=needs-review --remove-label=executor \
                        --remove-label="audit-retry:$audit_retry" --remove-label=model:sonnet \
                        --add-label=model:opus --add-label="audit-retry:$next_retry" \
                        --notes="Retry $next_retry: escalated sonnet → opus. Findings required (min 50 chars)."
                else
                    # opus → stay opus, just increment retry
                    log "INFO" "RETRY: $task_id - opus retry $next_retry"
                    bd_safe update "$task_id" --status=open --remove-label=needs-review --remove-label=executor \
                        --remove-label="audit-retry:$audit_retry" --add-label="audit-retry:$next_retry" \
                        --notes="Retry $next_retry: opus retry. Findings required (min 50 chars)."
                fi
            fi
            return 0
            ;;
        AUDIT_REVIEW)
            # Route audit task to Architect instead of code review
            log "INFO" "AUDIT: $task_id - routing to Architect for review"
            route_audit_to_architect "$task_id" "$task_json"
            return 0
            ;;
    esac

    log "INFO" "Pre-flight passed for $task_id"

    # Remember main SHA before Claude runs (to detect if merge happened)
    local main_ref main_before
    if git remote get-url origin &>/dev/null; then
        git fetch origin 2>/dev/null || true
        main_ref="origin/main"
    else
        main_ref="main"
    fi
    main_before=$(git rev-parse "$main_ref" 2>/dev/null || echo "unknown")

    # === BUILD CONTEXT ===
    local review_context
    review_context=$(build_review_context "$task_id" "$task_json")

    # === DETERMINE REVIEW MODEL ===
    local review_model
    review_model=$(get_review_model "$task_json")
    log "INFO" "Using $review_model for review (tiered)"

    # Check if senior-executor agent exists
    local agent_file=".claude/agents/senior-executor.md"
    local agent_prompt
    if [ -f "$agent_file" ]; then
        agent_prompt=$(cat "$agent_file")
    else
        agent_prompt="# Senior Executor
You are a senior developer doing code review.
Review the code, check for issues, and either approve or request changes.
If approved, merge and mark the task as complete with bd close."
    fi

    # Run senior executor (with tool use enabled)
    local output_file="$LOGS_DIR/senior-executor-$task_id.log"

    local full_prompt="$agent_prompt

---
TASK_ID: $task_id
PROJECT_ROOT: $PROJECT_DIR
ACTION: Review and merge if ready

## PRE-COMPUTED CONTEXT (no need to run git commands)
$review_context

## YOUR JOB
1. Review the diff above
2. Check if it matches done_when criteria
3. If good: checkout branch, merge to main, push, bd close
4. If bad: bd update --status=open --notes=\"reason\""

    # Use stdin to avoid issues with prompts starting with "---"
    # --print: non-interactive mode (required for pipe input)
    # Streaming: tee for real-time logs, strip_ansi removes terminal garbage
    local mapped_model
    mapped_model=$(map_model "$review_model")
    set -o pipefail
    if printf '%s' "$full_prompt" | timeout_cmd "$REVIEW_TIMEOUT" claude --print --model "$mapped_model" 2>&1 | strip_ansi | tee "$output_file" >/dev/null; then
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

    # Fetch to get latest main SHA
    if git remote get-url origin &>/dev/null; then
        git fetch origin 2>/dev/null || true
    fi
    local main_after
    main_after=$(git rev-parse "$main_ref" 2>/dev/null || echo "unknown")

    # Check result and log appropriately
    local updated_json
    updated_json=$(bd_safe show "$task_id" --json 2>/dev/null || echo "[]")
    local task_status
    task_status=$(echo "$updated_json" | jq -r '.[0].status // "unknown"' 2>/dev/null || echo "unknown")

    if [ "$task_status" = "closed" ]; then
        # Verify merge actually happened by checking if main changed
        if [ "$main_before" != "unknown" ] && [ "$main_before" = "$main_after" ]; then
            log "WARN" "Task $task_id closed but main unchanged, reopening"
            bd_safe update "$task_id" --status=open --remove-label=executor --notes="Auto-reopened: closed without merge to main"
        else
            log "SUCCESS" "APPROVED: $task_id (merged)"
            bd_safe update "$task_id" --remove-label=needs-review --remove-label=executor --add-label=reviewed >/dev/null 2>&1 || true
        fi
    elif [ "$task_status" = "open" ]; then
        # Task returned for rework - cleanup executor label
        bd_safe update "$task_id" --remove-label=executor >/dev/null 2>&1 || true
        # Extract reason from notes
        local notes
        notes=$(echo "$updated_json" | jq -r '.[0].notes // ""' 2>/dev/null | tail -1 | head -c 80)
        if [ -n "$notes" ]; then
            log "WARN" "RETURNED: $task_id - $notes"
        else
            log "WARN" "RETURNED: $task_id (no reason given)"
        fi
    else
        # Task still in_progress - reviewer didn't take action, retry review
        local review_retry
        review_retry=$(echo "$updated_json" | jq -r '.[0].labels[]? | select(startswith("review-retry:")) | split(":")[1]' 2>/dev/null | head -1)
        review_retry=${review_retry:-0}
        ((review_retry++))

        if [ "$review_retry" -ge 3 ]; then
            # Escalate model one level up after 3 failed attempts
            local current_model
            current_model=$(echo "$updated_json" | jq -r '.[0].labels[]? | select(startswith("model:")) | split(":")[1]' 2>/dev/null | head -1)
            current_model=${current_model:-sonnet}

            if [ "$current_model" = "haiku" ]; then
                log "WARN" "REVIEW ESCALATE: $task_id - haiku → sonnet after 3 attempts"
                bd_safe update "$task_id" \
                    --remove-label="review-retry:$((review_retry-1))" \
                    --remove-label="model:haiku" \
                    --add-label="model:sonnet" \
                    --notes="Review escalated haiku → sonnet after 3 failed attempts."
            elif [ "$current_model" = "sonnet" ]; then
                log "WARN" "REVIEW ESCALATE: $task_id - sonnet → opus after 3 attempts"
                bd_safe update "$task_id" \
                    --remove-label="review-retry:$((review_retry-1))" \
                    --remove-label="model:sonnet" \
                    --add-label="model:opus" \
                    --notes="Review escalated sonnet → opus after 3 failed attempts."
            else
                # Already opus - just reset retry counter
                log "WARN" "REVIEW RETRY: $task_id - opus, resetting retry counter"
                bd_safe update "$task_id" \
                    --remove-label="review-retry:$((review_retry-1))" \
                    --notes="Review retry reset (already opus)."
            fi
        else
            log "WARN" "REVIEW RETRY: $task_id - no action taken (attempt $review_retry/3)"
            bd_safe update "$task_id" --remove-label="review-retry:$((review_retry-1))" --add-label="review-retry:$review_retry" >/dev/null 2>&1 || \
            bd_safe update "$task_id" --add-label="review-retry:$review_retry" >/dev/null 2>&1
        fi
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
        bd_safe sync 2>/dev/null || true
        log "INFO" "Processed 1 review"
    fi
}

main "$@"
