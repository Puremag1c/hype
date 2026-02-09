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

    # Ensure lock is released on ANY exit (not just SIGINT/SIGTERM)
    trap "rm -f '$LOCK_FILE'" EXIT
}

# === Logging ===

mkdir -p "$LOGS_DIR"

log() {
    local level=$1
    local message=$2
    local color="" reset="\033[0m" gray="\033[90m"
    # HYPE brand colors (neon pink gradient)
    local hype_colored="\033[38;2;255;0;102mH\033[38;2;255;51;153mY\033[38;2;255;102;204mP\033[38;2;204;255;0mE\033[0m"

    case "$level" in
        INFO|SUCCESS)  color="\033[32m" ;;
        WARN)          color="\033[33m" ;;
        ERROR|FATAL)   color="\033[31m" ;;
        START)         color="\033[36m" ;;
    esac

    printf "${gray}%s${reset} [${hype_colored}] ${color}%s${reset}: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message"
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
    validate_int "TASK_STALE_TIMEOUT" "${TASK_STALE_TIMEOUT:-600}"

    validate_bool "LOG_TOKENS" "$LOG_TOKENS"
    validate_bool "DEBUG" "${DEBUG:-false}"

    validate_timeout "TASK_TIMEOUT" "$TASK_TIMEOUT"

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
    # Timeout prevents hanging if daemon is frozen
    if timeout_cmd 5s bd sync --status &>/dev/null; then
        return 0
    fi

    log "WARN" "Beads daemon not responding, attempting restart..."

    local attempts=0
    while [ $attempts -lt 3 ]; do
        ((attempts++))

        # Restart daemon with timeout (requires workspace path)
        timeout_cmd 10s bd daemon restart . &>/dev/null || true
        sleep 2

        if timeout_cmd 5s bd sync --status &>/dev/null; then
            log "INFO" "Beads daemon recovered after $attempts attempt(s)"
            return 0
        fi
    done

    log "FATAL" "Beads daemon failed to recover after 3 attempts. Check: bd daemon status"
    exit 1
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
        echo '{"phase":"UNKNOWN","stats":{},"progress_pct":0,"in_progress_ids":[],"regression_count":0,"p0_bugs":0,"error":"detect-phase.sh not found"}'
        return
    fi

    # Use fixed file in .hype/ instead of mktemp (prevents temp file leak on crash/SIGKILL)
    # File is overwritten each call, useful for debugging, cleaned up by hype clear
    stderr_output="$CLAUDEV_DIR/detect-phase-stderr.tmp"
    : > "$stderr_output"

    # Capture both stdout and stderr
    # Pass DEBUG flag to detect-phase.sh via environment
    phase=$(CLAUDEV_DEBUG="${DEBUG:-false}" ./scripts/detect-phase.sh 2>"$stderr_output") || phase='{"phase":"UNKNOWN","stats":{},"progress_pct":0,"in_progress_ids":[],"regression_count":0,"p0_bugs":0,"error":"detect-phase.sh failed"}'

    # Log stderr to file only (NOT to stdout!) to avoid polluting $phase
    if [[ -s "$stderr_output" ]]; then
        while IFS= read -r line; do
            echo "$(date '+%Y-%m-%d %H:%M:%S') [HYPE] DEBUG: [detect-phase] $line" >> "$LOGS_DIR/hype.log"
        done < "$stderr_output"
    fi

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
    local timeout=${6:-"$TASK_TIMEOUT"}  # Optional custom timeout

    log "INFO" "Running agent: $agent_name (mode: $mode, model: $model, timeout: $timeout)"

    if [ ! -f "$agent_file" ]; then
        log "ERROR" "Agent file not found: $agent_file"
        return 1
    fi

    local agent_prompt
    agent_prompt=$(cat "$agent_file")

    local output_file="$LOGS_DIR/${agent_name}-$(date +%s).log"

    # Inject CHANGELOG context for architect agents (prevents reintroducing removed entities)
    local changelog_context=""
    if [[ "$agent_name" == "architect" ]]; then
        changelog_context=$(get_changelog_context 3)
    fi

    # Build full prompt with mode and context
    local full_prompt="$agent_prompt

---
MODE: $mode
PROJECT_ROOT: $PROJECT_DIR
${changelog_context:+
$changelog_context
}$extra_context"

    # Map agent name to short label for progress logging
    local label
    case "$agent_name" in
        architect) label="ARCH" ;;
        manager)   label="MGR" ;;
        *)         label=$(echo "$agent_name" | tr '[:lower:]' '[:upper:]' | cut -c1-4) ;;
    esac

    # Run with real-time progress logging
    if run_claude_with_progress "$full_prompt" "$model" "$timeout" "$output_file" "$label" "$LOGS_DIR"; then
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
        if ! bd_safe list --json 2>/dev/null | jq -e ".[] | select(.title == \"$trigger_title\")" > /dev/null 2>&1; then
            bd_safe create --title="$trigger_title" --type=task --priority=1 --label=trigger >/dev/null 2>&1 || true
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
        # Safety: verify no open/in_progress tasks remain before marking DONE
        local remaining_tasks
        remaining_tasks=$(bd_safe list --json --limit 0 2>/dev/null | \
            jq '[.[] | select(.status == "open" or .status == "in_progress") |
                select((.labels // []) | any(test("^milestone:")) | not) |
                select((.labels // []) | index("trigger") | not)] | length' 2>/dev/null || echo "0")

        if [ "$remaining_tasks" -gt 0 ]; then
            log "WARN" "FINAL_REVIEW passed but $remaining_tasks task(s) still open, deferring DONE milestone"
            return 0
        fi

        log "INFO" "Final review passed, creating project-done milestone"
        ensure_milestone "milestone:project-done" "Project complete"

        # Note: cleanup moved to interactive prompt at DONE phase (or 'hype clear' command)
        # User chooses when to cleanup — preserves logs for review
    fi
}

# === Route blocked:troubleshoot tasks to Architect Troubleshooter ===

check_and_route_troubleshoot() {
    local bd_cache
    bd_cache=$(bd_safe list --json 2>/dev/null || echo "[]")

    # Find tasks with blocked:troubleshoot label
    local troubleshoot_ids
    troubleshoot_ids=$(echo "$bd_cache" | jq -r '.[] | select(.labels[]? == "blocked:troubleshoot") | .id' 2>/dev/null || true)

    if [ -z "$troubleshoot_ids" ]; then
        return 0
    fi

    local troubleshooter_file=".claude/agents/architect-troubleshooter.md"
    if [ ! -f "$troubleshooter_file" ]; then
        log "WARN" "architect-troubleshooter.md not found, skipping troubleshoot routing"
        return 0
    fi

    local troubleshooter_prompt
    troubleshooter_prompt=$(cat "$troubleshooter_file")

    for task_id in $troubleshoot_ids; do
        log "INFO" "Routing $task_id to Troubleshooter..."

        local task_json
        task_json=$(bd_safe show "$task_id" --json 2>/dev/null || echo "[]")

        local output_file="$LOGS_DIR/troubleshooter-$task_id.log"
        local full_prompt="$troubleshooter_prompt

---
TASK_ID: $task_id
TASK: $task_json
PROJECT_ROOT: $PROJECT_DIR"

        local ts_model
        ts_model=$(map_model "${MODEL_ARCHITECT:-opus}")
        printf '%s' "$full_prompt" | timeout_cmd "${REVIEW_TIMEOUT:-5m}" claude --print --model "$ts_model" > "$output_file" 2>&1 || true

        log "INFO" "Troubleshooter completed for $task_id (see $output_file)"
    done
}

# === Check for problems and consult Manager ===
# Manager is called ONLY for problem resolution, not for phase coordination

check_problems_and_consult_manager() {
    # First: route troubleshoot tasks to dedicated Troubleshooter agent
    check_and_route_troubleshoot

    # Cache bd list once (v1.9.0 optimization - was 4 calls, now 1)
    local bd_cache
    bd_cache=$(bd_safe list --json 2>/dev/null || echo "[]")

    # Count blocked tasks EXCLUDING troubleshoot (handled above)
    local blocked_count
    blocked_count=$(echo "$bd_cache" | jq '[.[] | select(.labels[]? | startswith("blocked:")) | select(.labels[]? == "blocked:troubleshoot" | not)] | length' 2>/dev/null || echo "0")

    # Count tasks at retry limit (from cache)
    local retry_limit_count
    retry_limit_count=$(echo "$bd_cache" | jq "[.[] | select(.labels[]? | test(\"^retry:[$RETRY_LIMIT-9]\"))] | length" 2>/dev/null || echo "0")

    # If problems exist, consult Manager (pass cache)
    if [ "$blocked_count" -gt 0 ] || [ "$retry_limit_count" -gt 0 ]; then
        log "WARN" "Problems detected: blocked=$blocked_count, retry_limit=$retry_limit_count"
        call_manager_for_problems "$blocked_count" "$retry_limit_count" "$bd_cache"
    fi
}

# === Call Manager for problem resolution ===

call_manager_for_problems() {
    local blocked=$1
    local retry_limit=$2
    local bd_cache=${3:-"[]"}  # Cached bd list (v1.9.0+)

    local manager_file=".claude/agents/manager.md"
    if [ ! -f "$manager_file" ]; then
        log "WARN" "manager.md not found, skipping problem resolution"
        return 0
    fi

    log "INFO" "Consulting Manager for problem resolution..."

    local manager_prompt
    manager_prompt=$(cat "$manager_file")

    # Get problem details from cache (no extra bd calls)
    local blocked_tasks
    blocked_tasks=$(echo "$bd_cache" | jq -r '.[] | select(.labels[]? | startswith("blocked:")) | "\(.id): \(.title)"' 2>/dev/null || echo "none")

    local retry_tasks
    retry_tasks=$(echo "$bd_cache" | jq -r ".[] | select(.labels[]? | test(\"^retry:[$RETRY_LIMIT-9]\")) | \"\(.id): \(.title)\"" 2>/dev/null || echo "none")

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
    local mgr_model
    mgr_model=$(map_model "${MODEL_MANAGER:-sonnet}")
    printf '%s' "$full_prompt" | timeout_cmd "$TASK_TIMEOUT" claude --model "$mgr_model" > "$output_file" 2>&1 || true

    log "INFO" "Manager problem resolution complete (see $output_file)"
}

# === Stale tasks check ===
# Reset in_progress tasks older than 10 minutes (executor likely crashed)

check_stale_tasks() {
    local reset_count
    # Use TASK_STALE_TIMEOUT from config (default 600s = 10 minutes)
    reset_count=$(reset_stale_tasks "${TASK_STALE_TIMEOUT:-600}" "stale in_progress")
    if [ "$reset_count" -gt 0 ]; then
        log "INFO" "Reset $reset_count stale task(s)"
    fi
}

# === Stale worktrees cleanup ===
# Remove worktrees older than 15 minutes (executor crashed or orphaned)

cleanup_stale_worktrees() {
    local worktrees_dir="$PROJECT_DIR/.hype-worktrees"
    local stale_threshold="${WORKTREE_STALE_TIMEOUT:-900}"  # default 15 minutes
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
    total=$(bd_safe list --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
    closed=$(bd_safe list --status=closed --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
    blocked=$(bd_safe list --json 2>/dev/null | jq '[.[] | select(.labels[]? | startswith("blocked:"))] | length' 2>/dev/null || echo "0")

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
    blocked_details=$(bd_safe list --json 2>/dev/null | jq -r '.[] | select(.labels[]? | startswith("blocked:")) | "- `\(.id)`: \(.title)"' 2>/dev/null || echo "- none")

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
    local phase_json=${2:-"{}"}  # JSON с метаданными (v1.9.0+)

    # Reset blocked cycles counter if we're not in BLOCKED_CYCLES
    if [ "$phase" != "BLOCKED_CYCLES" ]; then
        rm -f "$CLAUDEV_DIR/blocked_cycles_count"
    fi

    case $phase in
        INIT)
            # Check draft TTL first
            check_draft_ttl

            # Deep analysis for large existing projects (before Tech Writer)
            # Only runs once per project (marker: .hype/deep-analyzed)
            if [ -f "$PROJECT_DIR/PROJECT_CONTEXT.md" ] && [ ! -f "$CLAUDEV_DIR/deep-analyzed" ]; then
                # Source needs_deep_analysis function from deep-analyze.sh
                source "$HYPE_HOME/core/scripts/deep-analyze.sh" 2>/dev/null || true

                if type needs_deep_analysis &>/dev/null && needs_deep_analysis; then
                    log "INFO" "INIT: Large project detected, running deep analysis..."
                    if "$HYPE_HOME/core/scripts/deep-analyze.sh" --force; then
                        touch "$CLAUDEV_DIR/deep-analyzed"
                        log "INFO" "Deep analysis complete — enriched PROJECT_CONTEXT.md"
                    else
                        log "WARN" "Deep analysis failed, continuing with basic context"
                    fi
                fi
            fi

            # Tech Writer creates SPEC.md (INTERACTIVE - needs user dialogue)
            if [ -f ".claude/agents/tech-writer.md" ]; then
                log "INFO" "INIT: Starting Tech Writer (interactive)..."
                local tw_model
                tw_model=$(map_model "${MODEL_TECH_WRITER:-opus}")
                if ! run_interactive_agent "tech-writer" ".claude/agents/tech-writer.md" "$tw_model"; then
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
            if [ -f "$PROJECT_DIR/SPEC.md" ]; then
                # Remove needs-spec marker
                if [ -f "$PROJECT_DIR/.hype/needs-spec" ]; then
                    rm -f "$PROJECT_DIR/.hype/needs-spec"
                    log "INFO" "Removed needs-spec marker"
                fi

                # Remove ALL milestone tasks (new iteration = clean slate)
                local deleted_count
                deleted_count=$(delete_all_milestones)
                if [ "$deleted_count" -gt 0 ]; then
                    log "INFO" "Removed $deleted_count milestone(s) (new iteration started)"
                fi
            fi
            ;;

        PLANNING)
            # Architect creates plan from SPEC.md
            log "INFO" "PLANNING: Starting Architect to create plan..."
            local arch_model
            arch_model=$(map_model "${MODEL_ARCHITECT:-opus}")
            local spec_content
            spec_content=$(cat SPEC.md 2>/dev/null || echo "SPEC.md not found")
            run_agent_with_mode "architect" ".claude/agents/architect-planner.md" "$arch_model" "create_plan" "SPEC:
$spec_content" "${PLANNING_TIMEOUT:-15m}"

            # Ensure milestone exists (architect may forget step 7)
            local task_count
            task_count=$(bd_safe list --json --limit 0 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
            if [ "$task_count" -gt 0 ]; then
                if ! has_milestone "milestone:planning-done"; then
                    log "INFO" "Creating planning-done milestone (architect skipped step 7)"
                    ensure_milestone "milestone:planning-done" "Planning complete"
                fi
            fi
            ;;

        HELPERS)
            # Create trigger tasks for analysts (if not exist), then run them
            log "INFO" "HELPERS: Creating analyst triggers and running analysts..."
            create_analyst_triggers
            ./scripts/run-analysts.sh

            # Check if all analysts done and create milestone (single source of truth)
            # Must check BOTH open AND in_progress to prevent race condition:
            # If trigger is in_progress during check, milestone would be created prematurely
            local pending_triggers
            pending_triggers=$(bd_safe list --json --limit 0 2>/dev/null | \
                jq '[.[] | select(.status == "open" or .status == "in_progress") | select(.title | startswith("run-analyst-"))] | length' 2>/dev/null || echo "0")
            if [ "$pending_triggers" -eq 0 ]; then
                if ! has_milestone "milestone:analysts-done"; then
                    log "INFO" "All analysts done, creating milestone"
                    ensure_milestone "milestone:analysts-done" "Analysts complete"
                fi
            fi
            ;;

        PLAN_REVIEW)
            # Architect reviews additions from Analysts
            log "INFO" "PLAN_REVIEW: Starting Architect to review plan..."
            local arch_model
            arch_model=$(map_model "${MODEL_ARCHITECT:-opus}")
            # Create trigger task if not exists
            if ! bd_safe list --json 2>/dev/null | jq -e '.[] | select(.title == "run-plan-review")' > /dev/null 2>&1; then
                bd_safe create --title="run-plan-review" --type=task --priority=0 --label=trigger >/dev/null 2>&1 || true
            fi
            run_agent_with_mode "architect" ".claude/agents/architect-reviewer.md" "$arch_model" "plan_review" "" "${PLAN_REVIEW_TIMEOUT:-10m}"
            ;;

        USER_REVIEW)
            # Tasks escalated to user — generate non-technical report and stop daemon
            log "INFO" "USER_REVIEW: Tasks require human decision, generating report..."

            local user_tasks
            user_tasks=$(bd_safe list --status=open --json 2>/dev/null | \
                jq -r '.[] | select((.labels // []) | index("user-escalation")) | "\(.id): \(.title)\n  Notes: \(.notes // "none")"' 2>/dev/null || echo "")

            # Run tech-writer-review agent if available
            local tw_review_file=".claude/agents/tech-writer-review.md"
            if [ -f "$tw_review_file" ]; then
                local tw_prompt
                tw_prompt=$(cat "$tw_review_file")
                local output_file="$LOGS_DIR/user-review-$(date +%s).log"
                local tw_model
                tw_model=$(map_model "${MODEL_TECH_WRITER:-sonnet}")

                local full_prompt="$tw_prompt

---
MODE: user_review
PROJECT_ROOT: $PROJECT_DIR

TASKS REQUIRING USER DECISION:
$user_tasks"

                printf '%s' "$full_prompt" | timeout_cmd "${REVIEW_TIMEOUT:-5m}" claude --print --model "$tw_model" > "$output_file" 2>&1 || true
                log "INFO" "User review report generated (see $output_file)"
            fi

            # Stop daemon loop — user must act
            log "WARN" "USER_REVIEW: Daemon stopping. Resolve user-escalation tasks manually, then restart."
            log "WARN" "Tasks needing attention:"
            echo "$user_tasks" | while IFS= read -r line; do
                [ -n "$line" ] && log "WARN" "  $line"
            done
            return 0
            ;;

        SMOKE_REVIEW)
            # Architect triages ALL smoke test findings before executors can grab them
            log "INFO" "SMOKE_REVIEW: Processing smoke test findings..."

            local arch_model
            arch_model=$(map_model "${MODEL_ARCHITECT:-opus}")

            # Create trigger task if not exists
            if ! bd_safe list --json 2>/dev/null | jq -e '.[] | select(.title == "run-smoke-review")' > /dev/null 2>&1; then
                bd_safe create --title="run-smoke-review" --type=task --priority=0 --label=trigger >/dev/null 2>&1 || true
            fi

            # Collect ALL tasks needing triage (smoke label OR regression label)
            local smoke_tasks regression_tasks triage_prompt
            smoke_tasks=$(bd_safe list --status=open --json 2>/dev/null | jq -r '.[] | select((.labels // []) | any(. == "smoke" or . == "regression")) | "\(.id): \(.title) [labels: \(.labels | join(", "))]"' 2>/dev/null || echo "")
            triage_prompt="
SMOKE TEST FINDINGS TO TRIAGE:
$smoke_tasks

For each task:
1. bd show <id> --json — read details
2. If has 'regression' label: this bug was fixed before but returned. Apply regression decision tree.
3. If only 'smoke' label: this is a NEW finding. Decide:
   a) Related to project scope → KEEP: set appropriate model (--add-label=model:haiku|sonnet|opus), remove smoke label
   b) Unrelated to scope → CLOSE: bd close <id> --reason='Out of scope for current iteration'
   c) Needs to be split → CREATE subtasks, close original, remove smoke label
4. ALWAYS remove 'smoke' label after processing. ALWAYS remove 'regression' label after processing."

            run_agent_with_mode "architect" ".claude/agents/architect-qa.md" "$arch_model" "smoke_review" "$triage_prompt" "${SMOKE_REVIEW_TIMEOUT:-10m}"
            ;;

        IMPLEMENTATION)
            # Streaming: launch executors (non-blocking) + process one review
            # Note: regression tasks are handled in SMOKE_REVIEW phase before reaching here
            log "INFO" "IMPLEMENTATION: Streaming cycle..."

            ./scripts/run-executors.sh
            ./scripts/run-senior-executor.sh
            ;;

        SMOKE_TEST)
            # Run parallel testers to verify product works
            log "INFO" "SMOKE_TEST: Running parallel testers..."
            ./scripts/run-testers.sh

            # Check results - milestone created only if ALL tasks are closed
            # Must check BOTH open AND in_progress to prevent race condition
            local pending_tasks
            pending_tasks=$(bd_safe list --json --limit 0 2>/dev/null | \
                jq '[.[] | select(.status == "open" or .status == "in_progress")] | length' 2>/dev/null || echo "0")

            if [ "$pending_tasks" -gt 0 ]; then
                # Testers created tasks (bugs, regressions)
                # detect-phase.sh will route to SMOKE_REVIEW (if regression) or IMPLEMENTATION
                log "WARN" "SMOKE_TEST: $pending_tasks pending task(s) found"
            else
                # All tasks closed - create milestone
                log "INFO" "SMOKE_TEST: All tests passed - creating milestone"
                ensure_milestone "milestone:smoke-test-done" "Smoke test complete"
            fi
            ;;

        FINAL_REVIEW)
            # Architect does final review and versioning
            # Retry up to RETRY_LIMIT times on failure/timeout
            local arch_model final_review_attempt=0 final_review_success=false
            arch_model=$(map_model "${MODEL_ARCHITECT:-opus}")

            while [ $final_review_attempt -lt "${RETRY_LIMIT:-3}" ]; do
                ((final_review_attempt++)) || true
                log "INFO" "FINAL_REVIEW: Starting Architect (attempt $final_review_attempt/${RETRY_LIMIT:-3})..."

                if run_agent_with_mode "architect" ".claude/agents/architect-qa.md" "$arch_model" "final_review" "" "${FINAL_REVIEW_TIMEOUT:-15m}"; then
                    # Check if architect actually completed (wrote PASSED)
                    local latest_log
                    latest_log=$(ls -t "$LOGS_DIR"/architect-*.log 2>/dev/null | head -1)
                    if [ -n "$latest_log" ] && grep -q "FINAL_REVIEW: PASSED" "$latest_log" 2>/dev/null; then
                        final_review_success=true
                        break
                    fi
                    # Agent ran but didn't write PASSED - might have created tasks
                    local open_count
                    open_count=$(bd_safe list --status=open --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
                    if [ "$open_count" -gt 0 ]; then
                        log "INFO" "FINAL_REVIEW: Architect created $open_count task(s), returning to IMPLEMENTATION"
                        # Invalidate smoke-test-done milestone — need to re-test after fix
                        delete_milestone "milestone:smoke-test-done"
                        log "INFO" "Invalidated smoke-test-done milestone (will re-run smoke test)"
                        break
                    fi
                    log "WARN" "FINAL_REVIEW: Architect didn't complete review, retrying..."
                else
                    log "WARN" "FINAL_REVIEW: Architect failed/timed out (attempt $final_review_attempt)"
                fi

                # Brief pause before retry
                sleep 5
            done

            # Run versioner after successful final review
            if [ "$final_review_success" = true ]; then
                log "INFO" "FINAL_REVIEW passed, running versioner..."

                # Create trigger task for versioner
                local versioner_trigger
                versioner_trigger=$(bd_safe create --title="run-versioning" --type=task --priority=0 --label=trigger 2>&1 | grep -oE '[A-Za-z]+-[a-z0-9]+' | head -1)

                if [ -n "$versioner_trigger" ]; then
                    local versioner_model
                    versioner_model=$(map_model "${MODEL_VERSIONER:-haiku}")

                    # Run versioner with trigger task context
                    local versioner_prompt="TRIGGER_TASK: $versioner_trigger"
                    if run_agent_with_mode "versioner" ".claude/agents/versioner.md" "$versioner_model" "" "$versioner_prompt" "${VERSIONER_TIMEOUT:-5m}"; then
                        log "INFO" "Versioner completed"
                    else
                        log "WARN" "Versioner failed/timed out, closing trigger"
                        bd_safe close "$versioner_trigger" --reason="Versioner timeout" >/dev/null 2>&1 || true
                    fi
                fi
            fi

            # Check if architect created project-done milestone
            check_and_create_done_milestone

            # Safety: if still no PASSED and no new tasks after all retries, create blocker
            if [ "$final_review_success" = false ]; then
                local latest_log open_count
                latest_log=$(ls -t "$LOGS_DIR"/architect-*.log 2>/dev/null | head -1)
                open_count=$(bd_safe list --status=open --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")

                if [ "$open_count" -eq 0 ] && { [ -z "$latest_log" ] || ! grep -q "FINAL_REVIEW: PASSED" "$latest_log" 2>/dev/null; }; then
                    log "WARN" "FINAL_REVIEW incomplete after $final_review_attempt attempts, creating blocker"
                    bd_safe create --title="FINAL_REVIEW incomplete - check logs" \
                        --type=bug --priority=0 \
                        --description="Architect did not complete FINAL_REVIEW after $final_review_attempt attempts. Manual intervention required." >/dev/null 2>&1 || true
                fi
            fi
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
            if ! bd_safe list --json 2>/dev/null | jq -e '.[] | select(.title == "Fix dependency cycles")' > /dev/null 2>&1; then
                bd_safe create --title="Fix dependency cycles" --type=task --priority=0 \
                    --description="bd dep cycles detected circular dependencies. Fix before IMPLEMENTATION can proceed.

Run: bd dep cycles
Then: bd dep remove <task> <dep> for one edge in each cycle" \
                    >/dev/null 2>&1 || true
            fi

            # Run Architect to fix cycles
            local cycles_output
            cycles_output=$(bd_safe dep cycles 2>&1 || true)
            log "INFO" "Running Architect to fix cycles..."
            run_agent_with_mode "architect" ".claude/agents/architect-ops.md" "sonnet" "fix_cycles" "CYCLES:
$cycles_output"
            ;;

        *)
            log "WARN" "Unknown phase: $phase"
            ;;
    esac

    # After phase actions, check for problems and call Manager if needed
    check_problems_and_consult_manager
}

# === Active work monitoring ===
# Shows which agents are actively working (log files growing)

show_active_work() {
    local phase_json=${1:-"{}"}
    local now active_items=""
    now=$(date +%s)
    local stale_threshold=60  # seconds without activity = stale

    # Extract in_progress_ids from phase_json (v1.9.0 optimization - no bd show calls)
    local in_progress_ids
    in_progress_ids=$(echo "$phase_json" | jq -c '.in_progress_ids // []' 2>/dev/null || echo "[]")

    # Helper: check if task_id is in in_progress_ids
    is_in_progress() {
        local tid="$1"
        echo "$in_progress_ids" | jq -e "index(\"$tid\")" >/dev/null 2>&1
    }

    # Check executor logs (WORK)
    for log_file in "$LOGS_DIR"/executor-*.log; do
        [ -f "$log_file" ] || continue
        local task_id size mtime age status
        task_id=$(basename "$log_file" .log | sed 's/executor-//')

        # Skip if task is not in_progress (using cached list, no bd show)
        is_in_progress "$task_id" || continue

        size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo "0")
        mtime=$(stat -f%m "$log_file" 2>/dev/null || stat -c%Y "$log_file" 2>/dev/null || echo "0")
        age=$((now - mtime))

        # Only show if file was modified in last 10 minutes (active executor)
        if [ "$age" -lt 600 ]; then
            if [ "$age" -lt "$stale_threshold" ]; then
                status="active"
            else
                status="stale ${age}s"
            fi
            local size_kb=$((size / 1024))
            active_items="${active_items}WORK:$task_id(${size_kb}KB,$status) "
        fi
    done

    # Check senior-executor logs (CHECK)
    for log_file in "$LOGS_DIR"/senior-executor-*.log; do
        [ -f "$log_file" ] || continue
        local task_id size mtime age status
        task_id=$(basename "$log_file" .log | sed 's/senior-executor-//')

        # Skip if task is not in_progress (using cached list, no bd show)
        is_in_progress "$task_id" || continue

        size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo "0")
        mtime=$(stat -f%m "$log_file" 2>/dev/null || stat -c%Y "$log_file" 2>/dev/null || echo "0")
        age=$((now - mtime))

        if [ "$age" -lt 600 ]; then
            if [ "$age" -lt "$stale_threshold" ]; then
                status="active"
            else
                status="stale ${age}s"
            fi
            local size_kb=$((size / 1024))
            active_items="${active_items}CHECK:$task_id(${size_kb}KB,$status) "
        fi
    done

    # Check analyst logs (ANALYZE)
    for analyst in ux security ops reliability architecture; do
        local log_file="$LOGS_DIR/analyst-$analyst.log"
        [ -f "$log_file" ] || continue
        local size mtime age status
        size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo "0")
        mtime=$(stat -f%m "$log_file" 2>/dev/null || stat -c%Y "$log_file" 2>/dev/null || echo "0")
        age=$((now - mtime))

        if [ "$age" -lt 600 ]; then
            if [ "$age" -lt "$stale_threshold" ]; then
                status="active"
            else
                status="stale ${age}s"
            fi
            local size_kb=$((size / 1024))
            active_items="${active_items}ANALYZE:$analyst(${size_kb}KB,$status) "
        fi
    done

    # Check other agent logs (tech-writer, architect, manager)
    for agent in tech-writer architect manager; do
        local log_file="$LOGS_DIR/$agent.log"
        [ -f "$log_file" ] || continue
        local size mtime age status
        size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo "0")
        mtime=$(stat -f%m "$log_file" 2>/dev/null || stat -c%Y "$log_file" 2>/dev/null || echo "0")
        age=$((now - mtime))

        if [ "$age" -lt 600 ]; then
            if [ "$age" -lt "$stale_threshold" ]; then
                status="active"
            else
                status="stale ${age}s"
            fi
            local size_kb=$((size / 1024))
            active_items="${active_items}${agent^^}(${size_kb}KB,$status) "
        fi
    done

    # Log if there's active work
    if [ -n "$active_items" ]; then
        log "INFO" "Active: $active_items"
    fi
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

        # 3. Detect current phase (returns JSON with all metadata)
        local phase_json phase
        phase_json=$(detect_phase)
        phase=$(echo "$phase_json" | jq -r '.phase' 2>/dev/null || echo "UNKNOWN")

        # Visual separation between cycles (terminal + file)
        echo ""
        echo "" >> "$LOGS_DIR/hype.log"

        # Progress from phase_json (no extra bd calls needed)
        local closed_tasks total_tasks progress_pct
        closed_tasks=$(echo "$phase_json" | jq -r '.stats.closed // 0' 2>/dev/null || echo "0")
        total_tasks=$(echo "$phase_json" | jq -r '.stats.total // 0' 2>/dev/null || echo "0")
        progress_pct=$(echo "$phase_json" | jq -r '.progress_pct // 0' 2>/dev/null || echo "0")

        # Build progress bar (20 chars wide)
        local bar_width=20
        local filled=$((progress_pct * bar_width / 100))
        local empty=$((bar_width - filled))
        local bar=""
        for ((i=0; i<filled; i++)); do bar+="█"; done
        for ((i=0; i<empty; i++)); do bar+="░"; done

        log "INFO" "--- Cycle $cycle | Phase: $phase | [$bar] $closed_tasks/$total_tasks ($progress_pct%) ---"

        # Show active work (agents with growing log files)
        show_active_work "$phase_json"

        # 4. Dispatch phase-specific actions
        dispatch_phase "$phase" "$phase_json"

        # 5. Check for completion
        if [ "$phase" = "DONE" ]; then
            log "INFO" "=========================================="
            log "INFO" "PROJECT COMPLETE"
            log "INFO" "=========================================="

            # Show architect's final review report
            local final_review_log
            final_review_log=$(ls -t "$LOGS_DIR"/architect-*.log 2>/dev/null | head -1)
            if [ -n "$final_review_log" ] && [ -f "$final_review_log" ]; then
                echo ""
                echo "=== FINAL REVIEW REPORT ==="
                # Show last 50 lines of architect log (contains summary)
                tail -50 "$final_review_log" | grep -v "^$" | head -40
                echo "==========================="
                echo ""
            fi

            # Generate iteration stats
            local timestamp
            timestamp=$(date +%Y%m%d-%H%M%S)
            generate_iteration_stats "$timestamp" "$version"

            # Archive hype.log only (other logs kept for user review)
            mkdir -p "$LOGS_DIR/archive"
            mv "$LOGS_DIR/hype.log" "$LOGS_DIR/archive/iteration-$timestamp.log" 2>/dev/null || true

            ./scripts/notify.sh "Project complete" "All tasks done" 2>/dev/null || true

            # Ask user about cleanup (interactive only)
            echo ""
            echo "Run cleanup? This will:"
            echo "  - Delete all logs"
            echo "  - Clear beads tasks (backup in issues.jsonl)"
            echo "  - Archive SPEC.md → SPEC.prev.md"
            echo ""
            read -p "Cleanup now? (y/N) " -n 1 -r
            echo ""

            if [[ $REPLY =~ ^[Yy]$ ]]; then
                cleanup_iteration "$LOGS_DIR" "$PROJECT_DIR"
                log "SUCCESS" "Cleanup complete"
            else
                log "INFO" "Skipped cleanup. Run 'hype clear' later if needed."
            fi

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
