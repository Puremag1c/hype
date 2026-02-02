#!/bin/bash
# core/scripts/hype.sh
# Главный управляющий модуль HYPE — координирует работу агентов.
#
# Использование:
#   ./scripts/hype.sh           # Интерактивно
#   ./scripts/hype.sh &         # В фоне
#   nohup ./scripts/hype.sh &   # Переживёт закрытие терминала

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

PROJECT_DIR=$(pwd)
CLAUDEV_DIR="$PROJECT_DIR/.hype"
LOGS_DIR="$PROJECT_DIR/logs"
LOCK_FILE="$CLAUDEV_DIR/hype.lock"
CONFIG_FILE="$CLAUDEV_DIR/config.sh"
HYPE_HOME="${HYPE_HOME:-$HOME/.hype}"

# === Lock file (single instance) ===

acquire_lock() {
    mkdir -p "$CLAUDEV_DIR"

    if ! (set -C; echo $$ > "$LOCK_FILE") 2>/dev/null; then
        OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "0")
        if kill -0 "$OLD_PID" 2>/dev/null; then
            echo "ERROR: HYPE already running (PID $OLD_PID)"
            exit 1
        else
            echo "Removing stale lock (PID $OLD_PID not found)"
            rm -f "$LOCK_FILE"
            if ! (set -C; echo $$ > "$LOCK_FILE") 2>/dev/null; then
                echo "ERROR: Failed to acquire lock (race condition?)"
                exit 1
            fi
        fi
    fi
}

# === Logging ===

mkdir -p "$LOGS_DIR"

log() {
    local level=$1
    local message=$2
    local color="" reset="\033[0m" gray="\033[90m"

    case "$level" in
        INFO|SUCCESS)  color="\033[32m" ;;
        WARN)          color="\033[33m" ;;
        ERROR|FATAL)   color="\033[31m" ;;
        START)         color="\033[36m" ;;
    esac

    printf "${gray}%s${reset} [HYPE] ${color}%s${reset}: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [HYPE] $level: $message" >> "$LOGS_DIR/hype.log"
}

# === Config validation ===

validate_config() {
    local errors=0

    # Validate integers
    validate_int() {
        local name=$1
        local value=$2
        if ! [[ "$value" =~ ^[0-9]+$ ]]; then
            log "FATAL" "Invalid $name in config.sh: must be integer, got '$value'"
            ((errors++))
        fi
    }

    # Validate booleans
    validate_bool() {
        local name=$1
        local value=$2
        if [[ "$value" != "true" && "$value" != "false" ]]; then
            log "FATAL" "Invalid $name in config.sh: must be true/false, got '$value'"
            ((errors++))
        fi
    }

    # Validate timeout format (Nm or Ns)
    validate_timeout() {
        local name=$1
        local value=$2
        if ! [[ "$value" =~ ^[0-9]+[ms]$ ]]; then
            log "FATAL" "Invalid $name in config.sh: must be Nm or Ns (e.g. 10m), got '$value'"
            ((errors++))
        fi
    }

    # Run validations
    validate_int "MAX_PARALLEL_EXECUTORS" "$MAX_PARALLEL_EXECUTORS"
    validate_int "RETRY_LIMIT" "$RETRY_LIMIT"
    validate_int "ITERATION_DELAY" "$ITERATION_DELAY"
    validate_int "CLEANUP_KEEP_DAYS" "$CLEANUP_KEEP_DAYS"

    validate_bool "CI_ENABLED" "$CI_ENABLED"
    validate_bool "CD_ENABLED" "$CD_ENABLED"
    validate_bool "LOG_TOKENS" "$LOG_TOKENS"
    validate_bool "CLEANUP_ENABLED" "$CLEANUP_ENABLED"
    validate_bool "DEBUG" "${DEBUG:-false}"

    validate_timeout "TASK_TIMEOUT" "$TASK_TIMEOUT"
    validate_timeout "USER_INPUT_TIMEOUT" "$USER_INPUT_TIMEOUT"

    if [ "$errors" -gt 0 ]; then
        log "FATAL" "Config validation failed ($errors errors). Fix .hype/config.sh"
        exit 1
    fi

    log "INFO" "Config loaded: MAX_PARALLEL=$MAX_PARALLEL_EXECUTORS, RETRY=$RETRY_LIMIT, DELAY=${ITERATION_DELAY}s"
}

ensure_hype_dir() {
    # Защита от удаления .hype/ executor'ами
    if [ ! -d "$CLAUDEV_DIR" ]; then
        log "WARN" ".hype/ directory missing, recreating..."
        mkdir -p "$CLAUDEV_DIR"
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        log "WARN" "Config file missing, restoring from template..."
        local template="$HYPE_HOME/templates/config.template.sh"
        if [ -f "$template" ]; then
            cp "$template" "$CONFIG_FILE"
            log "INFO" "Config restored from template"
        else
            log "FATAL" "Cannot restore config: template not found at $template"
            exit 1
        fi
    fi
}

load_config() {
    ensure_hype_dir

    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    validate_config
}

# === Beads daemon check ===

check_beads() {
    if ! bd sync --status &>/dev/null; then
        log "WARN" "Beads daemon not running, attempting restart..."
        if bd daemon start &>/dev/null; then
            sleep 1
            if bd sync --status &>/dev/null; then
                log "INFO" "Beads daemon restarted successfully"
                return 0
            fi
        fi
        log "FATAL" "Beads daemon not running and restart failed. Run: bd daemon start"
        exit 1
    fi
}

# === Symlinks health check ===

check_symlinks_health() {
    local errors=0

    # Check scripts/ symlink
    if [[ ! -L "scripts" ]]; then
        if [[ -d "scripts" ]]; then
            log "ERROR" "scripts/ is a directory, not a symlink. Run: hype init --force"
        else
            log "ERROR" "scripts/ symlink not found. Run: hype init"
        fi
        ((errors++))
    elif [[ ! -e "scripts" ]]; then
        log "ERROR" "scripts/ symlink is broken (target doesn't exist)"
        log "ERROR" "Expected: $HOME/.hype/core/scripts"
        ((errors++))
    fi

    # Check .claude/agents symlink
    if [[ ! -L ".claude/agents" ]]; then
        if [[ -d ".claude/agents" ]]; then
            log "ERROR" ".claude/agents is a directory, not a symlink. Run: hype init --force"
        else
            log "ERROR" ".claude/agents symlink not found. Run: hype init"
        fi
        ((errors++))
    elif [[ ! -e ".claude/agents" ]]; then
        log "ERROR" ".claude/agents symlink is broken (target doesn't exist)"
        ((errors++))
    fi

    # Check required scripts exist
    local required_scripts=("detect-phase.sh" "run-executors.sh" "run-analysts.sh")
    for script in "${required_scripts[@]}"; do
        if [[ ! -x "./scripts/$script" ]]; then
            log "ERROR" "Required script not found or not executable: scripts/$script"
            ((errors++))
        fi
    done

    if [[ "$errors" -gt 0 ]]; then
        log "FATAL" "Health check failed ($errors errors). Fix symlinks and try again."
        log "INFO" "Quick fix: rm -f scripts && ln -sf ~/.hype/core/scripts scripts"
        exit 1
    fi

    log "INFO" "Health check passed"
}

# === Graceful shutdown ===

cleanup() {
    log "INFO" "Shutting down gracefully..."

    # SIGTERM children
    pkill -P $$ -TERM 2>/dev/null || true
    sleep 5
    pkill -P $$ -KILL 2>/dev/null || true

    # Reset stale in_progress tasks (>5min old)
    local reset_count
    reset_count=$(reset_stale_tasks 300 "stale at shutdown")
    if [ "$reset_count" -gt 0 ]; then
        log "INFO" "Reset $reset_count stale task(s) at shutdown"
    fi

    rm -f "$LOCK_FILE"
    log "INFO" "Shutdown complete"
    exit 0
}

trap cleanup SIGINT SIGTERM

# === Detect phase ===

detect_phase() {
    local phase
    local stderr_output

    # Check if detect-phase.sh exists and is executable
    if [[ ! -x "./scripts/detect-phase.sh" ]]; then
        # Log to stderr to avoid polluting phase output
        >&2 echo "ERROR: detect-phase.sh not found or not executable at ./scripts/detect-phase.sh"
        echo "UNKNOWN"
        return
    fi

    # Capture both stdout and stderr
    # Pass DEBUG flag to detect-phase.sh via environment
    stderr_output=$(mktemp)
    phase=$(CLAUDEV_DEBUG="${DEBUG:-false}" ./scripts/detect-phase.sh 2>"$stderr_output") || phase="UNKNOWN"

    # Log stderr to file only (NOT to stdout!) to avoid polluting $phase
    if [[ -s "$stderr_output" ]]; then
        while IFS= read -r line; do
            echo "$(date '+%Y-%m-%d %H:%M:%S') [HYPE] DEBUG: [detect-phase] $line" >> "$LOGS_DIR/hype.log"
        done < "$stderr_output"
    fi
    rm -f "$stderr_output"

    echo "$phase"
}

# === Run agent interactively (for user dialogue) ===

run_interactive_agent() {
    local agent_name=$1
    local agent_file=$2
    local model=${3:-"opus"}

    log "INFO" "Starting INTERACTIVE agent: $agent_name (user dialogue required)"

    if [ ! -f "$agent_file" ]; then
        log "ERROR" "Agent file not found: $agent_file"
        return 1
    fi

    # Read agent prompt from file
    local agent_prompt
    agent_prompt=$(cat "$agent_file")

    # Build full prompt via heredoc (safe for quotes in agent_prompt)
    local full_prompt
    full_prompt=$(cat <<EOF
$agent_prompt

---
PROJECT_ROOT: $PROJECT_DIR
EOF
)

    # Интерактивный режим: передаём содержимое промпта как системную инструкцию
    # Без --print, без timeout, без перенаправления в файл
    # "Начни" — trigger для первого сообщения (Claude Code ждёт user input)
    if claude --model "$model" --system-prompt "$full_prompt" "Начни"; then
        log "INFO" "Interactive agent $agent_name completed"
        return 0
    else
        log "WARN" "Interactive agent $agent_name exited with error"
        return 1
    fi
}

# === Run agent with MODE parameter (with tool use) ===

run_agent_with_mode() {
    local agent_name=$1
    local agent_file=$2
    local model=$3
    local mode=$4
    local extra_context=${5:-""}

    log "INFO" "Running agent: $agent_name (mode: $mode, model: $model)"

    if [ ! -f "$agent_file" ]; then
        log "ERROR" "Agent file not found: $agent_file"
        return 1
    fi

    local agent_prompt
    agent_prompt=$(cat "$agent_file")

    local output_file="$LOGS_DIR/${agent_name}-$(date +%s).log"

    # Run with tool use enabled (NO --print flag!)
    # Claude Code can execute bd, git, and other commands
    local full_prompt="$agent_prompt

---
MODE: $mode
PROJECT_ROOT: $PROJECT_DIR
$extra_context"

    # Use stdin to avoid issues with prompts starting with "---"
    if printf '%s' "$full_prompt" | timeout_cmd "$TASK_TIMEOUT" claude --model "$model" > "$output_file" 2>&1; then
        log "INFO" "Agent $agent_name completed (mode: $mode)"
        return 0
    else
        log "WARN" "Agent $agent_name failed or timed out (mode: $mode)"
        return 1
    fi
}

# === Create analyst trigger tasks ===

create_analyst_triggers() {
    local analysts=("ux" "security" "ops" "reliability" "architecture")

    for analyst in "${analysts[@]}"; do
        local trigger_title="run-analyst-$analyst"
        if ! bd list --json 2>/dev/null | jq -e ".[] | select(.title == \"$trigger_title\")" > /dev/null 2>&1; then
            bd create --title="$trigger_title" --type=task --priority=1 >/dev/null 2>&1 || true
            log "INFO" "Created trigger: $trigger_title"
        fi
    done
}

# === Check and create done milestone after final_review ===

check_and_create_done_milestone() {
    # Check if architect output contains PASSED
    local latest_log
    latest_log=$(ls -t "$LOGS_DIR"/architect-*.log 2>/dev/null | head -1)

    if [ -n "$latest_log" ] && grep -q "FINAL_REVIEW: PASSED" "$latest_log" 2>/dev/null; then
        log "INFO" "Final review passed, creating project-done milestone"
        bd create --title="Project complete" --type=task --labels=milestone:project-done >/dev/null 2>&1 || true
        local milestone_id
        milestone_id=$(bd list --json 2>/dev/null | jq -r '.[] | select(.labels[]? == "milestone:project-done") | .id' | head -1)
        if [ -n "$milestone_id" ]; then
            bd close "$milestone_id" --reason="Final review passed" >/dev/null 2>&1 || true
        fi

        # Create marker for next iteration
        # Tech Writer will see this and ask what to do next
        touch "$PROJECT_ROOT/.hype/needs-spec"
        log "INFO" "Created needs-spec marker for next iteration"

        # Cleanup after successful iteration
        # --older-than 1 preserves tasks closed less than 1 day ago
        # so the fresh milestone:project-done survives
        log "INFO" "Running cleanup after successful iteration..."
        bd admin cleanup --older-than 1 --force 2>/dev/null || true
        bd doctor --fix 2>/dev/null || true
        log "INFO" "Cleanup complete"
    fi
}

# === Check for problems and consult Manager ===
# Manager is called ONLY for problem resolution, not for phase coordination

check_problems_and_consult_manager() {
    # Count blocked tasks
    local blocked_count
    blocked_count=$(bd list --json 2>/dev/null | jq '[.[] | select(.labels[]? | startswith("blocked:"))] | length' 2>/dev/null || echo "0")

    # Count tasks at retry limit
    local retry_limit_count
    retry_limit_count=$(bd list --json 2>/dev/null | jq "[.[] | select(.labels[]? | test(\"^retry:[$RETRY_LIMIT-9]\"))] | length" 2>/dev/null || echo "0")

    # If problems exist, consult Manager
    if [ "$blocked_count" -gt 0 ] || [ "$retry_limit_count" -gt 0 ]; then
        log "WARN" "Problems detected: blocked=$blocked_count, retry_limit=$retry_limit_count"
        call_manager_for_problems "$blocked_count" "$retry_limit_count"
    fi
}

# === Call Manager for problem resolution ===

call_manager_for_problems() {
    local blocked=$1
    local retry_limit=$2

    local manager_file=".claude/agents/manager.md"
    if [ ! -f "$manager_file" ]; then
        log "WARN" "manager.md not found, skipping problem resolution"
        return 0
    fi

    log "INFO" "Consulting Manager for problem resolution..."

    local manager_prompt
    manager_prompt=$(cat "$manager_file")

    # Get problem details
    local blocked_tasks
    blocked_tasks=$(bd list --json 2>/dev/null | jq -r '.[] | select(.labels[]? | startswith("blocked:")) | "\(.id): \(.title)"' 2>/dev/null || echo "none")

    local retry_tasks
    retry_tasks=$(bd list --json 2>/dev/null | jq -r ".[] | select(.labels[]? | test(\"^retry:[$RETRY_LIMIT-9]\")) | \"\(.id): \(.title)\"" 2>/dev/null || echo "none")

    local output_file="$LOGS_DIR/manager-problems-$(date +%s).log"

    # Manager with tool use — resolves problems autonomously
    local full_prompt="$manager_prompt

---
PROBLEM_RESOLUTION_MODE: true
PROJECT_ROOT: $PROJECT_DIR

BLOCKED_TASKS ($blocked):
$blocked_tasks

RETRY_LIMIT_TASKS ($retry_limit):
$retry_tasks

Разреши проблемы автономно:
1. Для blocked — проверь зависимости, разблокируй если dependency closed
2. Для retry limit — эскалируй к Architect (создай задачу) или закрой как невозможную"

    # Use stdin to avoid issues with prompts starting with "---"
    printf '%s' "$full_prompt" | timeout_cmd "$TASK_TIMEOUT" claude --model sonnet > "$output_file" 2>&1 || true

    log "INFO" "Manager problem resolution complete (see $output_file)"
}

# === Stale tasks check ===
# Reset in_progress tasks older than 10 minutes (executor likely crashed)

check_stale_tasks() {
    local reset_count
    reset_count=$(reset_stale_tasks 600 "stale in_progress")
    if [ "$reset_count" -gt 0 ]; then
        log "INFO" "Reset $reset_count stale task(s)"
    fi
}

# === Stale worktrees cleanup ===
# Remove worktrees older than 15 minutes (executor crashed or orphaned)

cleanup_stale_worktrees() {
    local worktrees_dir="$PROJECT_DIR/.hype-worktrees"
    local stale_threshold=900  # 15 minutes in seconds
    local cleanup_count=0

    if [ ! -d "$worktrees_dir" ]; then
        return 0
    fi

    local now
    now=$(date +%s)

    for worktree in "$worktrees_dir"/executor-*; do
        if [ ! -d "$worktree" ]; then
            continue
        fi

        # Get worktree modification time (cross-platform)
        local mtime
        mtime=$(stat -f %m "$worktree" 2>/dev/null || stat -c %Y "$worktree" 2>/dev/null || echo "0")
        local age=$((now - mtime))

        if [ "$age" -gt "$stale_threshold" ]; then
            local slot
            slot=$(basename "$worktree" | sed 's/executor-//')
            log "INFO" "Removing stale worktree: $worktree (age: ${age}s)"
            git worktree remove --force "$worktree" 2>/dev/null || rm -rf "$worktree"
            ((cleanup_count++)) || true
        fi
    done

    # Prune detached worktrees from git
    git worktree prune 2>/dev/null || true

    if [ "$cleanup_count" -gt 0 ]; then
        log "INFO" "Cleaned up $cleanup_count stale worktree(s)"
    fi
}

# === Draft TTL check (24h) ===
# If draft is older than 24h, archive it and start fresh

check_draft_ttl() {
    local draft_file="$PROJECT_DIR/SPEC.draft.md"
    local ttl_seconds=86400  # 24 hours

    if [ ! -f "$draft_file" ]; then
        return 0
    fi

    # Get file modification time (cross-platform)
    local draft_mtime
    draft_mtime=$(stat -f %m "$draft_file" 2>/dev/null || stat -c %Y "$draft_file" 2>/dev/null || echo "0")
    local now
    now=$(date +%s)
    local age=$((now - draft_mtime))

    if [ "$age" -gt "$ttl_seconds" ]; then
        log "INFO" "Draft is ${age}s old (>24h), archiving and starting fresh"
        mv "$draft_file" "$PROJECT_DIR/SPEC.draft.$(date +%Y%m%d).old"
        return 1  # Signal to start fresh
    else
        log "INFO" "Draft is ${age}s old (<24h), continuing from draft"
        return 0  # Signal to continue from draft
    fi
}

# === Generate iteration stats ===

generate_iteration_stats() {
    local timestamp=$1
    local version=${2:-"unknown"}
    local stats_dir="$PROJECT_DIR/stats"
    mkdir -p "$stats_dir"

    local stats_file="$stats_dir/iteration-$timestamp.md"

    # Get iteration start time (stored as epoch for cross-platform compatibility)
    local start_epoch end_epoch
    start_epoch=$(cat "$CLAUDEV_DIR/iteration_start.txt" 2>/dev/null || echo "0")
    end_epoch=$(date +%s)

    # Convert epoch to readable format (cross-platform)
    local start_time end_time
    start_time=$(date -r "$start_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$start_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
    end_time=$(date '+%Y-%m-%d %H:%M:%S')

    # Calculate duration
    local duration="unknown"
    if [ "$start_epoch" -gt 0 ]; then
        local dur_seconds=$((end_epoch - start_epoch))
        local dur_hours=$((dur_seconds / 3600))
        local dur_minutes=$(( (dur_seconds % 3600) / 60 ))
        duration="${dur_hours}h ${dur_minutes}m"
    fi

    # Get task stats from beads
    local total closed blocked
    total=$(bd list --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
    closed=$(bd list --status=closed --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
    blocked=$(bd list --json 2>/dev/null | jq '[.[] | select(.labels[]? | startswith("blocked:"))] | length' 2>/dev/null || echo "0")

    # Count agent runs from logs
    local manager_runs architect_runs executor_runs analyst_runs senior_runs
    manager_runs=$(grep -c "\[HYPE\].*Manager" "$LOGS_DIR/hype.log" 2>/dev/null || echo "0")
    architect_runs=$(grep -c "Running agent: architect" "$LOGS_DIR/hype.log" 2>/dev/null || echo "0")
    executor_runs=$(grep -c "Starting executor for" "$LOGS_DIR/hype.log" 2>/dev/null || echo "0")
    analyst_runs=$(grep -c "Starting analyst-" "$LOGS_DIR/hype.log" 2>/dev/null || echo "0")
    senior_runs=$(grep -c "Processing review for" "$LOGS_DIR/hype.log" 2>/dev/null || echo "0")

    # Estimate tokens (rough: count chars in agent logs / 4)
    local total_chars estimated_tokens
    total_chars=$(find "$LOGS_DIR" -name "*.log" -newer "$CLAUDEV_DIR/iteration_start.txt" -exec wc -c {} + 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")
    estimated_tokens=$((total_chars / 4))

    # Get blocked tasks details
    local blocked_details
    blocked_details=$(bd list --json 2>/dev/null | jq -r '.[] | select(.labels[]? | startswith("blocked:")) | "- `\(.id)`: \(.title)"' 2>/dev/null || echo "- none")

    # Generate report
    cat > "$stats_file" << EOF
# Iteration Report

**Started:** $start_time
**Completed:** $end_time
**Duration:** $duration

## Tasks
- Total created: $total
- Completed: $closed
- Blocked: $blocked

## Agents Activity
| Agent | Runs |
|-------|------|
| Manager | $manager_runs |
| Architect | $architect_runs |
| Executors | $executor_runs |
| Analysts | $analyst_runs |
| Senior Executor | $senior_runs |

**Estimated tokens:** ~$estimated_tokens (based on log size)

## Blocked Tasks
$blocked_details

---
*Generated by Hype v$version*
EOF

    log "INFO" "Stats generated: $stats_file"
}

# === Phase dispatcher ===
# HYPE DIRECTLY calls scripts/agents by phase.
# Manager is called ONLY for problem resolution (blocked, retry limit, escalations).

dispatch_phase() {
    local phase=$1

    # Reset blocked cycles counter if we're not in BLOCKED_CYCLES
    if [ "$phase" != "BLOCKED_CYCLES" ]; then
        rm -f "$CLAUDEV_DIR/blocked_cycles_count"
    fi

    case $phase in
        INIT)
            # Check draft TTL first
            check_draft_ttl

            # Tech Writer creates SPEC.md (INTERACTIVE - needs user dialogue)
            if [ -f ".claude/agents/tech-writer.md" ]; then
                log "INFO" "INIT: Starting Tech Writer (interactive)..."
                if ! run_interactive_agent "tech-writer" ".claude/agents/tech-writer.md" "opus"; then
                    log "WARN" "Tech Writer exited with error. Check SPEC.draft.md for progress."
                    if [ -f "$PROJECT_DIR/SPEC.draft.md" ]; then
                        log "INFO" "Draft exists — will continue from draft next cycle"
                    else
                        log "WARN" "No draft saved — will start fresh next cycle"
                    fi
                fi
            else
                log "WARN" "tech-writer.md not found, skipping INIT"
            fi

            # Clean up after INIT phase if SPEC.md was created
            if [ -f "$PROJECT_ROOT/SPEC.md" ]; then
                # Remove needs-spec marker
                if [ -f "$PROJECT_ROOT/.hype/needs-spec" ]; then
                    rm -f "$PROJECT_ROOT/.hype/needs-spec"
                    log "INFO" "Removed needs-spec marker"
                fi

                # Remove milestone:project-done (it served its purpose)
                local done_milestone_id
                done_milestone_id=$(bd list --status=closed --json 2>/dev/null | jq -r '.[] | select(.labels[]? == "milestone:project-done") | .id' | head -1)
                if [ -n "$done_milestone_id" ]; then
                    bd delete "$done_milestone_id" >/dev/null 2>&1 || true
                    log "INFO" "Removed project-done milestone (new iteration started)"
                fi
            fi
            ;;

        PLANNING)
            # Architect creates plan from SPEC.md
            log "INFO" "PLANNING: Starting Architect to create plan..."
            local spec_content
            spec_content=$(cat SPEC.md 2>/dev/null || echo "SPEC.md not found")
            run_agent_with_mode "architect" ".claude/agents/architect.md" "opus" "create_plan" "SPEC:
$spec_content"

            # Ensure milestone exists (architect may forget step 7)
            local task_count milestone_exists
            task_count=$(bd list --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
            milestone_exists=$(bd list --status=closed --json 2>/dev/null | jq '[.[] | select(.labels[]? == "milestone:planning-done")] | length' 2>/dev/null || echo "0")

            if [ "$task_count" -gt 0 ] && [ "$milestone_exists" -eq 0 ]; then
                log "INFO" "Creating planning-done milestone (architect skipped step 7)"
                local milestone_id
                # Extract issue ID from "Created issue: ProjectName-xxxx" output
                milestone_id=$(bd create --title="Planning complete" --type=task --labels=milestone:planning-done 2>/dev/null | grep -oE '[A-Za-z]+-[a-z0-9]+' | head -1)
                if [ -n "$milestone_id" ]; then
                    bd close "$milestone_id" >/dev/null 2>&1 || true
                fi
            fi
            ;;

        HELPERS)
            # Create trigger tasks for analysts (if not exist), then run them
            log "INFO" "HELPERS: Creating analyst triggers and running analysts..."
            create_analyst_triggers
            ./scripts/run-analysts.sh

            # Check if all analysts done and create milestone (single source of truth)
            local open_triggers
            open_triggers=$(bd list --status=open --json 2>/dev/null | jq '[.[] | select(.title | startswith("run-analyst-"))] | length' 2>/dev/null || echo "0")
            if [ "$open_triggers" -eq 0 ]; then
                if ! bd list --json 2>/dev/null | jq -e '.[] | select(.labels[]? == "milestone:analysts-done")' > /dev/null 2>&1; then
                    log "INFO" "All analysts done, creating milestone"
                    bd create --title="Analysts complete" --type=task --labels=milestone:analysts-done >/dev/null 2>&1 || true
                    local milestone_id
                    milestone_id=$(bd list --json 2>/dev/null | jq -r '.[] | select(.labels[]? == "milestone:analysts-done") | .id' | head -1)
                    [ -n "$milestone_id" ] && bd close "$milestone_id" >/dev/null 2>&1 || true
                fi
            fi
            ;;

        PLAN_REVIEW)
            # Architect reviews additions from Analysts
            log "INFO" "PLAN_REVIEW: Starting Architect to review plan..."
            # Create trigger task if not exists
            if ! bd list --json 2>/dev/null | jq -e '.[] | select(.title == "run-plan-review")' > /dev/null 2>&1; then
                bd create --title="run-plan-review" --type=task --priority=0 >/dev/null 2>&1 || true
            fi
            run_agent_with_mode "architect" ".claude/agents/architect.md" "opus" "plan_review" ""
            ;;

        IMPLEMENTATION)
            # Streaming: launch executors (non-blocking) + process one review
            log "INFO" "IMPLEMENTATION: Streaming cycle..."
            ./scripts/run-executors.sh
            ./scripts/run-senior-executor.sh
            ;;

        FINAL_REVIEW)
            # Architect does final review and versioning
            log "INFO" "FINAL_REVIEW: Starting Architect for final review..."
            run_agent_with_mode "architect" ".claude/agents/architect.md" "opus" "final_review" ""
            # Check if architect created project-done milestone
            check_and_create_done_milestone
            ;;

        DONE)
            log "INFO" "Project phase: DONE"
            return 0
            ;;

        BLOCKED_CYCLES)
            log "ERROR" "Dependency cycles detected! Cannot proceed to IMPLEMENTATION."

            # Track consecutive blocked cycles for escalation
            local blocked_count_file="$CLAUDEV_DIR/blocked_cycles_count"
            local blocked_count=0
            if [ -f "$blocked_count_file" ]; then
                blocked_count=$(cat "$blocked_count_file" 2>/dev/null || echo "0")
            fi
            ((blocked_count++)) || true
            echo "$blocked_count" > "$blocked_count_file"

            # Escalation: after 3 consecutive failures, stop
            if [ "$blocked_count" -ge 3 ]; then
                log "FATAL" "BLOCKED_CYCLES escalation: $blocked_count consecutive failures. Manual intervention required."
                log "INFO" "Run: bd dep cycles"
                log "INFO" "Then: bd dep remove <task> <dep> for each cycle"
                rm -f "$LOCK_FILE"
                exit 1
            fi

            log "INFO" "Attempt $blocked_count/3 to fix cycles..."

            # Create P0 task for Architect (if not exists)
            if ! bd list --json 2>/dev/null | jq -e '.[] | select(.title == "Fix dependency cycles")' > /dev/null 2>&1; then
                bd create --title="Fix dependency cycles" --type=task --priority=0 \
                    --description="bd dep cycles detected circular dependencies. Fix before IMPLEMENTATION can proceed.

Run: bd dep cycles
Then: bd dep remove <task> <dep> for one edge in each cycle" \
                    >/dev/null 2>&1 || true
            fi

            # Run Architect to fix cycles
            local cycles_output
            cycles_output=$(bd dep cycles 2>&1 || true)
            log "INFO" "Running Architect to fix cycles..."
            run_agent_with_mode "architect" ".claude/agents/architect.md" "opus" "fix_cycles" "CYCLES:
$cycles_output"
            ;;

        *)
            log "WARN" "Unknown phase: $phase"
            ;;
    esac

    # After phase actions, check for problems and call Manager if needed
    check_problems_and_consult_manager
}

# === Main loop ===

main() {
    acquire_lock

    # Health check: claude CLI
    if ! command -v claude &>/dev/null; then
        log "FATAL" "Claude CLI not found. Install: npm install -g @anthropic/claude-code"
        exit 1
    fi

    # Health check: symlinks and required files
    check_symlinks_health

    # Find VERSION relative to this script (works with symlinks)
    local script_real_path hype_root version
    script_real_path=$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")
    hype_root=$(dirname "$(dirname "$(dirname "$script_real_path")")")
    version=$(cat "$hype_root/VERSION" 2>/dev/null || echo "unknown")

    log "INFO" "=========================================="
    log "INFO" "HYPE STARTED (PID $$)"
    log "INFO" "Version: $version"
    log "INFO" "Project: $PROJECT_DIR"
    log "INFO" "=========================================="

    # Record iteration start time (epoch for cross-platform compatibility)
    date +%s > "$CLAUDEV_DIR/iteration_start.txt"

    local cycle=0
    local max_cycles="${MAX_CYCLES:-1000}"

    while [ $cycle -lt "$max_cycles" ]; do
        ((cycle++))

        # 1. Check beads daemon (every iteration, fast ~10-50ms)
        check_beads

        # 2. Load config (allows hot reload)
        load_config

        # 3. Detect current phase
        local phase
        phase=$(detect_phase)

        # Visual separation between cycles (terminal + file)
        echo ""
        echo "" >> "$LOGS_DIR/hype.log"
        log "INFO" "--- Cycle $cycle | Phase: $phase ---"

        # 4. Dispatch phase-specific actions
        dispatch_phase "$phase"

        # 5. Check for completion
        if [ "$phase" = "DONE" ]; then
            log "INFO" "=========================================="
            log "INFO" "PROJECT COMPLETE"
            log "INFO" "=========================================="

            # Generate iteration stats
            local timestamp
            timestamp=$(date +%Y%m%d-%H%M%S)
            generate_iteration_stats "$timestamp" "$version"

            # Archive logs
            mkdir -p "$LOGS_DIR/archive"
            mv "$LOGS_DIR/hype.log" "$LOGS_DIR/archive/iteration-$timestamp.log" 2>/dev/null || true

            ./scripts/notify.sh "Project complete" "All tasks done" 2>/dev/null || true
            rm -f "$LOCK_FILE"
            exit 0
        fi

        # 6. Auto-close completed features and epics
        ./scripts/close-completed-parents.sh 2>/dev/null || true

        # 7. Reset stale in_progress tasks (executor crashed without timeout)
        check_stale_tasks

        # 8. Cleanup stale worktrees (orphaned from crashed executors)
        cleanup_stale_worktrees

        # 9. Pause before next iteration
        log "INFO" "Pause ${ITERATION_DELAY}s..."
        sleep "$ITERATION_DELAY"
    done

    log "WARN" "Max cycles reached ($max_cycles)"
    rm -f "$LOCK_FILE"
    exit 1
}

main "$@"
