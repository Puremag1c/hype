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
export HYPE_DIR="$CLAUDEV_DIR"  # v2.3.9: milestone functions use this for file-based milestones
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

    # Unified EXIT trap: handles both graceful shutdown and unexpected death
    # set -e / pipefail kills bypass SIGINT/SIGTERM traps but EXIT always fires
    trap '_hype_exit_handler' EXIT
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
    validate_int "MAX_PARALLEL_CODERS" "$MAX_PARALLEL_CODERS"
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

    log "INFO" "Config loaded: MAX_PARALLEL=$MAX_PARALLEL_CODERS, RETRY=$RETRY_LIMIT, DELAY=${ITERATION_DELAY}s"
}

ensure_hype_dir() {
    # Защита от удаления .hype/ coder'ами
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

# === Beads health check ===
# check_beads is defined in common.sh (Dolt embedded backend)

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
    local required_scripts=("detect-phase.sh" "run-coders.sh" "run-analysts.sh" "run-seniors.sh" "run-merge-queue.sh")
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
}

# Exit handler: dispatches to cleanup for signals, logs unexpected deaths
_hype_exit_handler() {
    local exit_code=$?
    if [ "$_hype_shutting_down" = true ]; then
        # Already in cleanup (from signal), just release lock
        rm -f "$LOCK_FILE" 2>/dev/null || true
        return
    fi
    if [ "$exit_code" -eq 0 ]; then
        rm -f "$LOCK_FILE" 2>/dev/null || true
    else
        log "ERROR" "HYPE exited unexpectedly (exit code $exit_code). Check logs."
        rm -f "$LOCK_FILE" 2>/dev/null || true
    fi
}
_hype_shutting_down=false

_hype_signal_handler() {
    _hype_shutting_down=true
    cleanup
    exit 0
}

trap _hype_signal_handler SIGINT SIGTERM

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

    # Tool restrictions: read everything, write only SPEC files
    local allowed_tools='Read,Glob,Grep,Write'
    allowed_tools+=',Bash(cat:*),Bash(grep:*),Bash(find:*),Bash(ls:*),Bash(head:*),Bash(tail:*)'
    allowed_tools+=',Bash(wc:*)'

    # Интерактивный режим: передаём содержимое промпта как системную инструкцию
    # Без --print, без timeout, без перенаправления в файл
    # "Начни" — trigger для первого сообщения (Claude Code ждёт user input)
    if claude --model "$model" --system-prompt "$full_prompt" --allowedTools "$allowed_tools" -- "Начни"; then
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

    # v2.3.10: single cache read for all trigger cleanups (was 5 separate bd_safe list calls)
    local bd_cache
    bd_cache=$(cat "$CLAUDEV_DIR/tick-cache.json" 2>/dev/null || echo "[]")

    for analyst in "${analysts[@]}"; do
        local trigger_title="run-analyst-$analyst"
        cleanup_stale_trigger "$trigger_title" "$bd_cache"
        bd_safe create --title="$trigger_title" --type=task --priority=1 --label=trigger >/dev/null 2>&1 || true
        log "INFO" "Created trigger: $trigger_title"
    done
}

# === Check and create done milestone after validating ===

check_and_create_done_milestone() {
    # Check if architect output contains PASSED
    local latest_log
    latest_log=$(ls -t "$LOGS_DIR"/architect-*.log 2>/dev/null | head -1)

    if [ -n "$latest_log" ] && grep -q "VALIDATING: PASSED" "$latest_log" 2>/dev/null; then
        # Safety: verify no open/in_progress tasks remain before marking DONE
        local remaining_tasks
        remaining_tasks=$(bd_safe query "(status=open OR status=in_progress) AND NOT label=trigger" --json --limit 0 2>/dev/null | \
            jq '[.[] | select((.labels // []) | any(test("^milestone:")) | not)] | length' 2>/dev/null || echo "0")

        if [ "$remaining_tasks" -gt 0 ]; then
            log "WARN" "VALIDATING passed but $remaining_tasks task(s) still open, deferring DONE milestone"
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
    # v2.3.9: read from tick-cache (written by detect-phase.sh this cycle)
    local bd_cache
    bd_cache=$(cat "$CLAUDEV_DIR/tick-cache.json" 2>/dev/null || echo "[]")

    # Find tasks with blocked:troubleshoot label
    local troubleshoot_ids
    troubleshoot_ids=$(echo "$bd_cache" | jq -r '.[] | select(.status != "closed") | select(.labels[]? == "blocked:troubleshoot") | .id' 2>/dev/null || true)

    if [ -z "$troubleshoot_ids" ]; then
        return 0
    fi

    local troubleshooter_file=".claude/agents/troubleshooter.md"
    if [ ! -f "$troubleshooter_file" ]; then
        log "WARN" "troubleshooter.md not found, skipping troubleshoot routing"
        return 0
    fi

    local troubleshooter_prompt
    troubleshooter_prompt=$(cat "$troubleshooter_file")

    for task_id in $troubleshoot_ids; do
        # v2.3.16: Fresh state check — tick-cache is stale after dispatch
        local fresh_json fresh_status has_coder_label
        fresh_json=$(bd_safe show "$task_id" --json 2>/dev/null || echo "[]")
        fresh_status=$(echo "$fresh_json" | jq -r '.[0].status // "unknown"' 2>/dev/null || echo "unknown")
        has_coder_label=$(echo "$fresh_json" | jq -r '[.[0].labels[]? | select(. == "coder")] | length' 2>/dev/null || echo "0")

        if [ "$fresh_status" = "closed" ]; then
            log "INFO" "Troubleshoot skip $task_id: already closed"
            continue
        fi
        # v2.3.19: Check coder label regardless of status (open+coder = coder claimed during review)
        if [ "$has_coder_label" != "0" ]; then
            log "INFO" "Troubleshoot skip $task_id: coder label present (status=$fresh_status)"
            continue
        fi

        log "INFO" "Routing $task_id to Troubleshooter..."

        local task_json
        task_json="$fresh_json"

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

        # Post-troubleshooter: reset reject:N if task was reformulated (fresh escalation ladder)
        local updated_json updated_status has_reformulated
        updated_json=$(bd_safe show "$task_id" --json 2>/dev/null || echo "[]")
        updated_status=$(echo "$updated_json" | jq -r '.[0].status // "unknown"' 2>/dev/null || echo "unknown")
        has_reformulated=$(echo "$updated_json" | jq -r '[.[0].labels[]? | select(. == "reformulated")] | length' 2>/dev/null || echo "0")

        if [ "$updated_status" = "open" ] && [ "$has_reformulated" != "0" ]; then
            set_counter_label "$task_id" "reject" 0 "$updated_json"
            log "INFO" "Reset reject:N for reformulated task $task_id (fresh escalation ladder)"
        fi
    done
}

# === Check for problems and consult Manager ===
# Manager is called ONLY for problem resolution, not for phase coordination

check_problems_and_consult_manager() {
    # First: route troubleshoot tasks to dedicated Troubleshooter agent
    check_and_route_troubleshoot

    # v2.3.9: read from tick-cache (written by detect-phase.sh this cycle)
    local bd_cache
    bd_cache=$(cat "$CLAUDEV_DIR/tick-cache.json" 2>/dev/null || echo "[]")

    # Count blocked tasks EXCLUDING troubleshoot (handled above)
    local blocked_count
    blocked_count=$(echo "$bd_cache" | jq '[.[] | select(.status != "closed") | select(.labels[]? | startswith("blocked:")) | select(.labels[]? == "blocked:troubleshoot" | not)] | length' 2>/dev/null || echo "0")

    # Count tasks at retry limit (from cache)
    local retry_limit_count
    retry_limit_count=$(echo "$bd_cache" | jq "[.[] | select(.status != \"closed\") | select(.labels[]? | test(\"^retry:[$RETRY_LIMIT-9]\"))] | length" 2>/dev/null || echo "0")

    # If problems exist, consult Manager (pass cache)
    if [ "$blocked_count" -gt 0 ] || [ "$retry_limit_count" -gt 0 ]; then
        log "WARN" "Problems detected: blocked=$blocked_count, retry_limit=$retry_limit_count"
        call_manager_for_problems "$blocked_count" "$retry_limit_count" "$bd_cache"
    fi
}

# === Resolve problems (bash-based, replaces LLM manager agent) ===

call_manager_for_problems() {
    local blocked=$1
    local retry_limit=$2
    local bd_cache=${3:-"[]"}  # Cached bd list (v1.9.0+)

    log "INFO" "Resolving problems: blocked=$blocked, retry_limit=$retry_limit"

    local resolved=0 escalated=0 closed=0

    # --- Handle blocked tasks ---
    local blocked_ids
    blocked_ids=$(echo "$bd_cache" | jq -r '.[] | select(.status != "closed") | select(.labels[]? | startswith("blocked:")) | .id' 2>/dev/null || echo "")

    for task_id in $blocked_ids; do
        local labels
        labels=$(echo "$bd_cache" | jq -r --arg id "$task_id" '.[] | select(.id == $id) | (.labels // [])[]' 2>/dev/null || echo "")

        if echo "$labels" | grep -q "^blocked:dependency$"; then
            # Check if dependency is closed
            local dep_id
            dep_id=$(bd_safe show "$task_id" --json 2>/dev/null | jq -r '.[0].blocked_by[0] // empty' 2>/dev/null || echo "")
            if [ -n "$dep_id" ]; then
                local dep_status
                dep_status=$(bd_safe show "$dep_id" --json 2>/dev/null | jq -r '.[0].status // empty' 2>/dev/null || echo "")
                if [ "$dep_status" = "closed" ]; then
                    bd_safe update "$task_id" --status=open --remove-label=blocked:dependency --notes="Unblocked: dependency $dep_id closed" 2>/dev/null || true
                    log "INFO" "Manager: unblocked $task_id (dependency $dep_id closed)"
                    ((resolved++))
                fi
            fi
        elif echo "$labels" | grep -q "^blocked:conflict$"; then
            bd_safe create --title="Resolve conflict for $task_id" --type=task --priority=0 --labels=model:opus,escalation 2>/dev/null || true
            bd_safe update "$task_id" --notes="Escalated to Architect for conflict resolution" 2>/dev/null || true
            log "INFO" "Manager: escalated $task_id (conflict → architect)"
            ((escalated++))
        elif echo "$labels" | grep -q "^blocked:missing-info$"; then
            bd_safe create --title="Clarify requirements for $task_id" --type=task --priority=1 --labels=model:opus 2>/dev/null || true
            log "INFO" "Manager: created clarification task for $task_id"
            ((escalated++))
        elif echo "$labels" | grep -q "^blocked:escalation-limit$"; then
            bd_safe update "$task_id" --remove-label=blocked:escalation-limit --add-label=blocked:troubleshoot \
                --notes="Manager: routed to Troubleshooter for persistent failure" 2>/dev/null || true
            log "INFO" "Manager: routed $task_id to troubleshooter"
            ((escalated++))
        fi
    done

    # --- Handle retry limit tasks ---
    local retry_ids
    retry_ids=$(echo "$bd_cache" | jq -r ".[] | select(.status != \"closed\") | select(.labels[]? | test(\"^retry:[$RETRY_LIMIT-9]\")) | .id" 2>/dev/null || echo "")

    for task_id in $retry_ids; do
        local task_labels
        task_labels=$(echo "$bd_cache" | jq -r --arg id "$task_id" '.[] | select(.id == $id) | (.labels // [])[]' 2>/dev/null || echo "")

        if echo "$task_labels" | grep -q "model:opus"; then
            # Already Opus and still failing → close
            bd_safe close "$task_id" --reason="Unresolvable after multiple attempts with Opus" 2>/dev/null || true
            log "INFO" "Manager: closed $task_id (Opus retry limit exceeded)"
            ((closed++))
        else
            # Escalate to Opus
            bd_safe update "$task_id" --status=open --set-labels=model:opus --notes="Reassigned to Opus after retry limit" 2>/dev/null || true
            log "INFO" "Manager: escalated $task_id to Opus"
            ((escalated++))
        fi
    done

    log "INFO" "Manager: resolved=$resolved, escalated=$escalated, closed=$closed"
}

# === Stale tasks check ===
# Reset in_progress tasks older than 10 minutes (coder likely crashed)

check_stale_tasks() {
    local in_progress_cache="${1:-}"
    local reset_count
    # Use TASK_STALE_TIMEOUT from config (default 600s = 10 minutes)
    reset_count=$(reset_stale_tasks "${TASK_STALE_TIMEOUT:-600}" "stale in_progress" "$in_progress_cache")
    if [ "$reset_count" -gt 0 ]; then
        log "INFO" "Reset $reset_count stale task(s)"
    fi
}

# === Self-healing: stuck tasks without needs-review ===
# Coder completed but fallback bd_safe update failed (e.g. beads sync contention)
# Task stays in_progress without coder or needs-review labels — stuck forever
# Fix: add needs-review if stuck > 2 minutes

heal_stuck_tasks() {
    local threshold=120  # 2 minutes
    local now
    now=$(date +%s)

    # Accept optional pre-fetched JSON to avoid redundant bd list
    local in_progress_json="${1:-}"
    if [ -z "$in_progress_json" ]; then
        in_progress_json=$(bd_safe list --status=in_progress --json --limit 0 2>/dev/null || echo "[]")
    fi

    local stuck_ids
    stuck_ids=$(echo "$in_progress_json" | jq -r '.[] | select(
        ((.labels // []) | index("coder") | not) and
        ((.labels // []) | index("needs-review") | not) and
        ((.labels // []) | index("trigger") | not) and
        ((.labels // []) | index("reviewing") | not) and
        ((.labels // []) | index("approved") | not) and
        ((.labels // []) | any(test("^blocked:")) | not)
    ) | .id' 2>/dev/null || true)

    for task_id in $stuck_ids; do
        local updated_at task_age
        updated_at=$(echo "$in_progress_json" | jq -r ".[] | select(.id == \"$task_id\") | .updated_at // \"\"" 2>/dev/null)

        if [ -z "$updated_at" ]; then
            continue
        fi

        # Parse ISO timestamp to epoch (cross-platform)
        local task_epoch
        task_epoch=$(parse_utc_epoch "$updated_at")
        task_age=$((now - task_epoch))

        if [ "$task_age" -gt "$threshold" ]; then
            log "WARN" "HEAL: $task_id stuck in_progress without coder/needs-review for ${task_age}s, adding needs-review"
            bd_safe update "$task_id" --add-label=needs-review >/dev/null 2>&1 || true
        fi
    done

    # v2.3.18: Heal coder+needs-review deadlock
    # When coder agent adds needs-review but safety net fails to remove coder label,
    # task becomes invisible to both coder pipeline and review pipeline.
    local deadlock_ids
    deadlock_ids=$(echo "$in_progress_json" | jq -r '.[] | select(
        ((.labels // []) | index("coder")) and
        ((.labels // []) | index("needs-review"))
    ) | .id' 2>/dev/null || true)

    for task_id in $deadlock_ids; do
        log "WARN" "HEAL: $task_id has coder+needs-review deadlock, removing coder label"
        bd_safe update "$task_id" --remove-label=coder >/dev/null 2>&1 || true
    done

    # v2.2: Heal tasks stuck in reviewing (reviewer crashed, >3 min)
    local reviewing_threshold=180
    local reviewing_ids
    reviewing_ids=$(echo "$in_progress_json" | jq -r '.[] | select(
        ((.labels // []) | index("reviewing"))
    ) | .id' 2>/dev/null || true)

    for task_id in $reviewing_ids; do
        local updated_at task_age
        updated_at=$(echo "$in_progress_json" | jq -r ".[] | select(.id == \"$task_id\") | .updated_at // \"\"" 2>/dev/null)
        [ -z "$updated_at" ] && continue

        local task_epoch
        task_epoch=$(parse_utc_epoch "$updated_at")
        task_age=$((now - task_epoch))

        if [ "$task_age" -gt "$reviewing_threshold" ]; then
            # Check if a reviewer lock exists (reviewer still running)
            if [ ! -d "$PROJECT_DIR/.hype-worktrees/review-$task_id.lock" ]; then
                log "WARN" "HEAL: $task_id stuck in reviewing for ${task_age}s without active reviewer, returning to queue"
                bd_safe update "$task_id" --remove-label=reviewing --add-label=needs-review >/dev/null 2>&1 || true
            fi
        fi
    done

    # v2.2: Warn/recover tasks stuck in approved (merge queue not running)
    local approved_warn_threshold=300   # 5 min: warn
    local approved_recover_threshold=600  # 10 min: recover
    local approved_ids
    approved_ids=$(echo "$in_progress_json" | jq -r '.[] | select(
        ((.labels // []) | index("approved"))
    ) | .id' 2>/dev/null || true)

    for task_id in $approved_ids; do
        local updated_at task_age
        updated_at=$(echo "$in_progress_json" | jq -r ".[] | select(.id == \"$task_id\") | .updated_at // \"\"" 2>/dev/null)
        [ -z "$updated_at" ] && continue

        local task_epoch
        task_epoch=$(parse_utc_epoch "$updated_at")
        task_age=$((now - task_epoch))

        if [ "$task_age" -gt "$approved_recover_threshold" ]; then
            # Recovery: return to coder for rebase/retry
            log "WARN" "HEAL: $task_id approved but not merged for ${task_age}s — returning to coder"
            local task_json_heal
            task_json_heal=$(bd_safe show "$task_id" --json 2>/dev/null || echo "[]")
            local reject_count
            reject_count=$(get_counter_value "$task_json_heal" "reject")
            ((reject_count++))
            set_counter_label "$task_id" "reject" "$reject_count" "$task_json_heal"
            bd_safe update "$task_id" --status=open --remove-label=approved \
                --notes="Approved but not merged for ${task_age}s. Merge queue may be stuck. Rebase and retry. (reject:$reject_count)" >/dev/null 2>&1 || true
            if [ "$reject_count" -ge 4 ]; then
                bd_safe update "$task_id" --add-label=blocked:troubleshoot \
                    --notes="Merge stuck after $reject_count attempts. Escalated." >/dev/null 2>&1 || true
                log "WARN" "TROUBLESHOOT: $task_id - merge stuck (reject:$reject_count)"
            fi
        elif [ "$task_age" -gt "$approved_warn_threshold" ]; then
            log "WARN" "HEAL: $task_id approved but not merged for ${task_age}s — merge queue may be stuck"
        fi
    done
}

# === Stale worktrees cleanup ===
# Remove worktrees older than 15 minutes (coder crashed or orphaned)

cleanup_stale_worktrees() {
    local worktrees_dir="$PROJECT_DIR/.hype-worktrees"
    local stale_threshold="${WORKTREE_STALE_TIMEOUT:-900}"  # default 15 minutes
    local cleanup_count=0

    if [ ! -d "$worktrees_dir" ]; then
        return 0
    fi

    local now
    now=$(date +%s)

    for worktree in "$worktrees_dir"/coder-*; do
        if [ ! -d "$worktree" ]; then
            continue
        fi

        # Get worktree modification time (cross-platform)
        local mtime
        mtime=$(stat -f %m "$worktree" 2>/dev/null || stat -c %Y "$worktree" 2>/dev/null || echo "0")
        local age=$((now - mtime))

        if [ "$age" -gt "$stale_threshold" ]; then
            local slot
            slot=$(basename "$worktree" | sed 's/coder-//')
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

    # v2.3.9: read from tick-cache (written by detect-phase.sh this cycle, includes --all)
    local total closed blocked
    total=$(jq 'length' "$CLAUDEV_DIR/tick-cache.json" 2>/dev/null || echo "0")
    closed=$(jq '[.[] | select(.status == "closed")] | length' "$CLAUDEV_DIR/tick-cache.json" 2>/dev/null || echo "0")
    blocked=$(jq '[.[] | select(.status != "closed") | select(.labels[]? | startswith("blocked:"))] | length' "$CLAUDEV_DIR/tick-cache.json" 2>/dev/null || echo "0")

    # Count agent runs from logs
    local manager_runs architect_runs coder_runs analyst_runs senior_runs
    manager_runs=$(grep -c "\[HYPE\].*Manager" "$LOGS_DIR/hype.log" 2>/dev/null || echo "0")
    architect_runs=$(grep -c "Running agent: architect" "$LOGS_DIR/hype.log" 2>/dev/null || echo "0")
    coder_runs=$(grep -c "Starting coder for" "$LOGS_DIR/hype.log" 2>/dev/null || echo "0")
    analyst_runs=$(grep -c "Starting analyst-" "$LOGS_DIR/hype.log" 2>/dev/null || echo "0")
    senior_runs=$(grep -c "Processing review for" "$LOGS_DIR/hype.log" 2>/dev/null || echo "0")

    # Estimate tokens (rough: count chars in agent logs / 4)
    local total_chars estimated_tokens
    total_chars=$(find "$LOGS_DIR" -name "*.log" -newer "$CLAUDEV_DIR/iteration_start.txt" -exec wc -c {} + 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")
    estimated_tokens=$((total_chars / 4))

    # Get blocked tasks details
    local blocked_details
    # v2.3.9: read from tick-cache
    blocked_details=$(jq -r '.[] | select(.status != "closed") | select(.labels[]? | startswith("blocked:")) | "- `\(.id)`: \(.title)"' "$CLAUDEV_DIR/tick-cache.json" 2>/dev/null || echo "- none")

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
| Executors | $coder_runs |
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
        PREPARING)
            # Check draft TTL first
            check_draft_ttl

            # Deep analysis for large existing projects (before Manager)
            # Only runs once per project (marker: .hype/deep-analyzed)
            if [ -f "$PROJECT_DIR/PROJECT_CONTEXT.md" ] && [ ! -f "$CLAUDEV_DIR/deep-analyzed" ]; then
                # Source needs_deep_analysis function from deep-analyze.sh
                source "$HYPE_HOME/core/scripts/deep-analyze.sh" 2>/dev/null || true

                if type needs_deep_analysis &>/dev/null && needs_deep_analysis; then
                    log "INFO" "PREPARING: Large project detected, running deep analysis..."
                    if "$HYPE_HOME/core/scripts/deep-analyze.sh" --force; then
                        touch "$CLAUDEV_DIR/deep-analyzed"
                        log "INFO" "Deep analysis complete — enriched PROJECT_CONTEXT.md"
                    else
                        log "WARN" "Deep analysis failed, continuing with basic context"
                    fi
                fi
            fi

            # Manager creates SPEC.md (INTERACTIVE - needs user dialogue)
            if [ -f ".claude/agents/manager.md" ]; then
                log "INFO" "PREPARING: Starting Manager (interactive)..."
                local tw_model
                tw_model=$(map_model "${MODEL_MANAGER:-opus}")
                if ! run_interactive_agent "manager" ".claude/agents/manager.md" "$tw_model"; then
                    log "WARN" "Manager exited with error. Check SPEC.draft.md for progress."
                    if [ -f "$PROJECT_DIR/SPEC.draft.md" ]; then
                        log "INFO" "Draft exists — will continue from draft next cycle"
                    else
                        log "WARN" "No draft saved — will start fresh next cycle"
                    fi
                fi
            else
                log "WARN" "manager.md not found, skipping PREPARING"
            fi

            # Clean up after PREPARING phase if SPEC.md was created
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
            run_agent_with_mode "architect" ".claude/agents/architect.md" "$arch_model" "create_plan" "SPEC:
$spec_content" "${PLANNING_TIMEOUT:-15m}" || log "WARN" "Architect failed in PLANNING (will retry next cycle)"

            # Ensure milestone exists (architect may forget step 7)
            local task_count
            # Fresh bd call needed: architect just ran and may have created tasks
            task_count=$(bd_safe list --json --limit 0 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
            if [ "$task_count" -gt 0 ]; then
                if ! has_milestone "milestone:planning-done"; then
                    log "INFO" "Creating planning-done milestone (architect skipped step 7)"
                    ensure_milestone "milestone:planning-done" "Planning complete"
                fi
            fi
            ;;

        ANALYZE)
            # Create trigger tasks for analysts (if not exist), then run them
            log "INFO" "ANALYZE: Creating analyst triggers and running analysts..."
            create_analyst_triggers
            ./scripts/run-analysts.sh || log "ERROR" "run-analysts.sh failed (exit $?)"

            # Check if all analysts done and create milestone (single source of truth)
            # Must check BOTH open AND in_progress to prevent race condition:
            # If trigger is in_progress during check, milestone would be created prematurely
            local pending_triggers
            # Fresh bd call needed: analysts just ran and may have closed triggers
            pending_triggers=$(bd_safe query "(status=open OR status=in_progress) AND title=run-analyst-" --json --limit 0 2>/dev/null | \
                jq 'length' 2>/dev/null || echo "0")

            # v2.4.5: Recovery — run-analysts.sh finished (all 5 processes exited),
            # but some triggers stayed open due to bd_safe close failure under contention.
            # Force-close orphan triggers (no parallel contention now, bd_safe should work).
            if [ "$pending_triggers" -gt 0 ]; then
                log "WARN" "ANALYZE: $pending_triggers triggers still open after analysts finished, force-closing"
                local orphan_ids
                orphan_ids=$(bd_safe query "(status=open OR status=in_progress) AND title=run-analyst-" --json --limit 0 2>/dev/null | \
                    jq -r '.[].id' 2>/dev/null || true)
                for oid in $orphan_ids; do
                    bd_safe close "$oid" --reason="Force cleanup: analysts finished" >/dev/null 2>&1 || true
                done
                sleep 1
                # Re-check
                pending_triggers=$(bd_safe query "(status=open OR status=in_progress) AND title=run-analyst-" --json --limit 0 2>/dev/null | \
                    jq 'length' 2>/dev/null || echo "0")
            fi

            if [ "$pending_triggers" -eq 0 ]; then
                if ! has_milestone "milestone:analysts-done"; then
                    log "INFO" "All analysts done, creating milestone"
                    ensure_milestone "milestone:analysts-done" "Analysts complete"
                fi
            else
                log "ERROR" "ANALYZE: $pending_triggers triggers still open after force-close — will retry next cycle"
            fi
            ;;

        THINKING)
            # Architect reviews additions from Analysts
            log "INFO" "THINKING: Starting Architect to review plan..."
            local arch_model
            arch_model=$(map_model "${MODEL_ARCHITECT:-opus}")
            # Close stale triggers from previous runs, create fresh
            # v2.3.10: pass tick-cache to avoid bd_safe list call
            local bd_cache
            bd_cache=$(cat "$CLAUDEV_DIR/tick-cache.json" 2>/dev/null || echo "[]")
            cleanup_stale_trigger "run-plan-review" "$bd_cache"
            bd_safe create --title="run-plan-review" --type=task --priority=0 --label=trigger >/dev/null 2>&1 || true
            run_agent_with_mode "architect" ".claude/agents/plan-reviewer.md" "$arch_model" "plan_review" "" "${THINKING_TIMEOUT:-10m}" || log "WARN" "Plan-reviewer failed in THINKING (will retry next cycle)"
            ;;

        CONSULTATION)
            # Tasks escalated to user — generate non-technical report and stop loop
            log "INFO" "CONSULTATION: Tasks require human decision, generating report..."

            local user_tasks
            # v2.3.9: read from tick-cache (written by detect-phase.sh this cycle)
            user_tasks=$(jq -r '.[] | select(.status == "open") | select((.labels // []) | index("user-escalation")) | "\(.id): \(.title)\n  Notes: \(.notes // "none")"' "$CLAUDEV_DIR/tick-cache.json" 2>/dev/null || echo "")

            # Run manager-review agent if available
            local tw_review_file=".claude/agents/manager-review.md"
            if [ -f "$tw_review_file" ]; then
                local tw_prompt
                tw_prompt=$(cat "$tw_review_file")
                local output_file="$LOGS_DIR/user-review-$(date +%s).log"
                local tw_model
                tw_model=$(map_model "${MODEL_MANAGER:-sonnet}")

                local full_prompt="$tw_prompt

---
MODE: user_review
PROJECT_ROOT: $PROJECT_DIR

TASKS REQUIRING USER DECISION:
$user_tasks"

                printf '%s' "$full_prompt" | timeout_cmd "${REVIEW_TIMEOUT:-5m}" claude --print --model "$tw_model" > "$output_file" 2>&1 || true
                log "INFO" "User review report generated (see $output_file)"
            fi

            # Stop main loop — user must act
            log "WARN" "CONSULTATION: Stopping. Resolve user-escalation tasks manually, then restart."
            log "WARN" "Tasks needing attention:"
            echo "$user_tasks" | while IFS= read -r line; do
                [ -n "$line" ] && log "WARN" "  $line"
            done
            return 0
            ;;

        REFLEXING)
            # Clean stale testers PID file (v2.3.5)
            # Testers are done when we reach REFLEXING. If PID file persists
            # through CODING and TESTING re-enters, STATE 3 would treat
            # the dead PID as "testers just finished" — skipping actual test launch.
            rm -f "$CLAUDEV_DIR/run-testers.pid"

            # Architect triages ALL smoke test findings before coders can grab them
            log "INFO" "REFLEXING: Processing smoke test findings..."

            local arch_model
            arch_model=$(map_model "${MODEL_ARCHITECT:-opus}")

            # Close stale triggers from previous runs, create fresh
            # v2.3.10: pass tick-cache to avoid bd_safe list call
            local bd_cache
            bd_cache=$(cat "$CLAUDEV_DIR/tick-cache.json" 2>/dev/null || echo "[]")
            cleanup_stale_trigger "run-smoke-review" "$bd_cache"
            bd_safe create --title="run-smoke-review" --type=task --priority=0 --label=trigger >/dev/null 2>&1 || true

            # Collect ALL tasks needing triage (smoke label OR regression label)
            local smoke_tasks regression_tasks triage_prompt
            # v2.3.9: read from tick-cache (written by detect-phase.sh this cycle)
            smoke_tasks=$(jq -r '.[] | select(.status == "open") | select((.labels // []) | any(. == "smoke" or . == "regression")) | "\(.id): \(.title) [labels: \(.labels | join(", "))]"' "$CLAUDEV_DIR/tick-cache.json" 2>/dev/null || echo "")
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

            run_agent_with_mode "architect" ".claude/agents/qa.md" "$arch_model" "reflexing" "$triage_prompt" "${REFLEXING_TIMEOUT:-10m}" || log "WARN" "Architect failed in REFLEXING (will retry next cycle)"

            # v2.3.14: Safety net — force-remove smoke/regression labels architect missed
            # Without this, leftover labels trigger another REFLEXING (2x Opus waste)
            local remaining_smoke_ids
            remaining_smoke_ids=$(jq -r '.[] | select(.status == "open") | select((.labels // []) | any(. == "smoke" or . == "regression")) | .id' "$CLAUDEV_DIR/tick-cache.json" 2>/dev/null || echo "")
            if [ -n "$remaining_smoke_ids" ]; then
                log "WARN" "REFLEXING: Cleaning up leftover smoke labels (safety net)"
                for sid in $remaining_smoke_ids; do
                    bd_safe update "$sid" --remove-label=smoke --remove-label=regression >/dev/null 2>&1 || true
                done
            fi
            ;;

        CODING)
            # v2.3.21: Clean stale testers PID file (covers TESTING→IMPL→TESTING path)
            rm -f "$CLAUDEV_DIR/run-testers.pid"

            # Streaming: launch coders + seniors + merge queue (all non-blocking)
            # Note: regression tasks are handled in REFLEXING phase before reaching here
            log "INFO" "CODING: Streaming cycle..."

            ./scripts/run-coders.sh || log "ERROR" "run-coders.sh failed (exit $?)"

            # v2.3.9: reviewers + merge queue read from tick-cache.json (written by detect-phase.sh)
            # No extra bd call needed — tick-cache has all in_progress tasks
            HYPE_IN_PROGRESS_CACHE="$in_progress_cache" ./scripts/run-seniors.sh || log "ERROR" "run-seniors.sh failed (exit $?)"
            HYPE_IN_PROGRESS_CACHE="$in_progress_cache" ./scripts/run-merge-queue.sh || log "ERROR" "run-merge-queue.sh failed (exit $?)"
            ;;

        TESTING)
            # Non-blocking: launch testers in background, HYPE keeps ticking
            # This ensures check_beads runs every cycle even during long smoke tests
            local testers_pid_file="$CLAUDEV_DIR/run-testers.pid"
            local testers_pid=""
            [ -f "$testers_pid_file" ] && testers_pid=$(cat "$testers_pid_file" 2>/dev/null)

            if [ -n "$testers_pid" ] && kill -0 "$testers_pid" 2>/dev/null; then
                # STATE 1: Testers running — wait
                log "INFO" "TESTING: testers running (PID $testers_pid)"

            elif [ ! -f "$testers_pid_file" ]; then
                # STATE 2: Never launched (no PID file) — start testers
                log "INFO" "TESTING: launching testers..."
                ./scripts/run-testers.sh &
                echo $! > "$testers_pid_file"
                log "INFO" "TESTING: testers launched (PID $!)"

            else
                # STATE 3: PID file exists but process dead — testers finished (or crashed)
                rm -f "$testers_pid_file"

                # Check for orphaned triggers (crash case — re-launch)
                local tester_triggers
                # v2.3.9: read from tick-cache (written by detect-phase.sh this cycle)
                tester_triggers=$(jq '[.[] | select(.status == "open" or .status == "in_progress") | select(.title | startswith("run-tester-"))] | length' "$CLAUDEV_DIR/tick-cache.json" 2>/dev/null || echo "0")

                if [ "$tester_triggers" -gt 0 ]; then
                    log "WARN" "TESTING: orphaned tester triggers ($tester_triggers), re-launching..."
                    ./scripts/run-testers.sh &
                    echo $! > "$testers_pid_file"
                    log "INFO" "TESTING: testers re-launched (PID $!)"
                else
                    # Testers done — check results
                    local pending_tasks
                    # v2.3.9: read from tick-cache (written by detect-phase.sh this cycle)
                    pending_tasks=$(jq '[.[] | select(.status == "open" or .status == "in_progress") | select((.labels // []) | index("trigger") | not)] | length' "$CLAUDEV_DIR/tick-cache.json" 2>/dev/null || echo "0")

                    if [ "$pending_tasks" -gt 0 ]; then
                        log "WARN" "TESTING: $pending_tasks pending task(s) found"
                    else
                        log "INFO" "TESTING: All tests passed - creating milestone"
                        ensure_milestone "milestone:testing-done" "Smoke test complete"
                    fi
                fi
            fi
            ;;

        VALIDATING)
            # Architect does final review and versioning
            # Retry up to RETRY_LIMIT times on failure/timeout
            local arch_model validating_attempt=0 validating_success=false
            arch_model=$(map_model "${MODEL_ARCHITECT:-opus}")

            while [ $validating_attempt -lt "${RETRY_LIMIT:-3}" ]; do
                ((validating_attempt++)) || true
                log "INFO" "VALIDATING: Starting Architect (attempt $validating_attempt/${RETRY_LIMIT:-3})..."

                if run_agent_with_mode "architect" ".claude/agents/qa.md" "$arch_model" "validating" "" "${VALIDATING_TIMEOUT:-15m}"; then
                    # Check if architect actually completed (wrote PASSED)
                    local latest_log
                    latest_log=$(ls -t "$LOGS_DIR"/architect-*.log 2>/dev/null | head -1)
                    if [ -n "$latest_log" ] && grep -q "VALIDATING: PASSED" "$latest_log" 2>/dev/null; then
                        # Defense: check if architect also created tasks (contradicts PASSED)
                        local new_open_count
                        new_open_count=$(bd_safe query "status=open AND NOT label=trigger" --json --limit 0 2>/dev/null | \
                            jq 'length' 2>/dev/null || echo "0")
                        if [ "$new_open_count" -gt 0 ]; then
                            log "WARN" "VALIDATING: PASSED but $new_open_count new task(s) created — treating as NEEDS_FIXES"
                            delete_milestone "milestone:testing-done"
                            break
                        fi
                        validating_success=true
                        break
                    fi
                    # Agent ran but didn't write PASSED - might have created tasks
                    local open_count
                    open_count=$(bd_safe count --status=open 2>/dev/null || echo "0")
                    if [ "$open_count" -gt 0 ]; then
                        log "INFO" "VALIDATING: Architect created $open_count task(s), returning to CODING"
                        # Invalidate testing-done milestone — need to re-test after fix
                        delete_milestone "milestone:testing-done"
                        log "INFO" "Invalidated testing-done milestone (will re-run smoke test)"
                        break
                    fi
                    log "WARN" "VALIDATING: Architect didn't complete review, retrying..."
                else
                    log "WARN" "VALIDATING: Architect failed/timed out (attempt $validating_attempt)"
                fi

                # Brief pause before retry
                sleep 5
            done

            # Create validating-done milestone on success → transitions to REPORTING
            if [ "$validating_success" = true ]; then
                ensure_milestone "milestone:validating-done" "Validation passed"
            fi

            # Safety: if still no PASSED and no new tasks after all retries, create blocker
            if [ "$validating_success" = false ]; then
                local latest_log open_count
                latest_log=$(ls -t "$LOGS_DIR"/architect-*.log 2>/dev/null | head -1)
                open_count=$(bd_safe count --status=open 2>/dev/null || echo "0")

                if [ "$open_count" -eq 0 ] && { [ -z "$latest_log" ] || ! grep -q "VALIDATING: PASSED" "$latest_log" 2>/dev/null; }; then
                    log "WARN" "VALIDATING incomplete after $validating_attempt attempts, creating blocker"
                    bd_safe create --title="VALIDATING incomplete - check logs" \
                        --type=bug --priority=0 \
                        --description="Architect did not complete VALIDATING after $validating_attempt attempts. Manual intervention required." >/dev/null 2>&1 || true
                fi
            fi
            ;;

        REPORTING)
            # Completion agent: version bump, CHANGELOG, SPEC_REPORT, commit+push
            log "INFO" "REPORTING: Running completion agent..."

            local bd_cache
            bd_cache=$(cat "$CLAUDEV_DIR/tick-cache.json" 2>/dev/null || echo "[]")
            cleanup_stale_trigger "run-completion" "$bd_cache"
            local completion_trigger
            completion_trigger=$(bd_safe create --title="run-completion" --type=task --priority=0 --label=trigger 2>&1 | grep -oE '[A-Za-z]+-[a-z0-9]+' | head -1)

            if [ -n "$completion_trigger" ]; then
                local completion_model
                completion_model=$(map_model "${MODEL_COMPLETION:-opus}")

                local completion_prompt="TRIGGER_TASK: $completion_trigger"
                if run_agent_with_mode "completion" ".claude/agents/completion.md" "$completion_model" "" "$completion_prompt" "${COMPLETION_TIMEOUT:-10m}"; then
                    log "INFO" "Completion agent completed"
                else
                    log "WARN" "Completion agent failed/timed out, closing trigger"
                    bd_safe close "$completion_trigger" --reason="Completion timeout" >/dev/null 2>&1 || true
                fi
            fi

            check_and_create_done_milestone
            ;;

        DONE)
            log "INFO" "Project phase: DONE"
            return 0
            ;;

        BLOCKED_CYCLES)
            log "ERROR" "Dependency cycles detected! Cannot proceed to CODING."

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
            # v2.3.9: read from tick-cache (written by detect-phase.sh this cycle)
            if ! jq -e '.[] | select(.title == "Fix dependency cycles")' "$CLAUDEV_DIR/tick-cache.json" > /dev/null 2>&1; then
                bd_safe create --title="Fix dependency cycles" --type=task --priority=0 \
                    --description="bd dep cycles detected circular dependencies. Fix before CODING can proceed.

Run: bd dep cycles
Then: bd dep remove <task> <dep> for one edge in each cycle" \
                    >/dev/null 2>&1 || true
            fi

            # Run Architect to fix cycles
            local cycles_output base_branch_val cycles_context
            cycles_output=$(bd_safe dep cycles 2>&1 || true)
            base_branch_val=$(get_base_branch)
            cycles_context="BASE_BRANCH: $base_branch_val
CYCLES:
$cycles_output"
            log "INFO" "Running Architect to fix cycles..."
            run_agent_with_mode "architect" ".claude/agents/ops.md" "sonnet" "fix_cycles" "$cycles_context" || log "WARN" "Ops failed in BLOCKED_CYCLES (will retry next cycle)"
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

    # Check coder logs (WORK)
    for log_file in "$LOGS_DIR"/coder-*.log; do
        [ -f "$log_file" ] || continue
        local task_id size mtime age status
        task_id=$(basename "$log_file" .log | sed 's/coder-//')

        # Skip if task is not in_progress (using cached list, no bd show)
        is_in_progress "$task_id" || continue

        size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo "0")
        mtime=$(stat -f%m "$log_file" 2>/dev/null || stat -c%Y "$log_file" 2>/dev/null || echo "0")
        age=$((now - mtime))

        # Only show if file was modified in last 10 minutes (active coder)
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

    # Check senior logs (REVIEW)
    for log_file in "$LOGS_DIR"/senior-*.log; do
        [ -f "$log_file" ] || continue
        local task_id size mtime age status
        task_id=$(basename "$log_file" .log | sed 's/senior-//')

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
            active_items="${active_items}REVIEW:$task_id(${size_kb}KB,$status) "
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

    # Check other agent logs (manager, architect, completion)
    for agent in manager architect completion; do
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

    # Clean up stale state from previous sessions (crash recovery)
    rm -f "$CLAUDEV_DIR/run-testers.pid"

    # Startup hardening: DB compaction
    compact_beads_if_large 10

    # Close orphaned triggers from previous sessions
    local stale_triggers
    stale_triggers=$(bd_safe query "label=trigger" --json --limit 0 2>/dev/null | \
        jq -r '.[].id' 2>/dev/null || true)
    for stale_id in $stale_triggers; do
        log "WARN" "Closing orphaned trigger $stale_id from previous session"
        bd_safe close "$stale_id" --reason="Orphaned trigger (HYPE startup cleanup)" >/dev/null 2>&1 || true
    done

    local cycle=0
    local max_cycles="${MAX_CYCLES:-1000}"
    local current_delay="${ITERATION_DELAY:-10}"
    local base_delay="${ITERATION_DELAY:-10}"
    local beads_fail_streak=0

    while [ $cycle -lt "$max_cycles" ]; do
        ((cycle++))

        # 1. Check beads backend with adaptive backoff
        # If backend is slow, increase delay to reduce load instead of hammering it
        local health_start health_end health_elapsed
        health_start=$(date +%s)
        if ! check_beads; then
            ((beads_fail_streak++)) || true
            if [ "$beads_fail_streak" -ge 5 ]; then
                log "ERROR" "Beads backend failed $beads_fail_streak cycles in a row. Try: bd doctor"
            else
                log "WARN" "Beads backend not recovered (streak $beads_fail_streak/5), retrying in 60s..."
            fi
            sleep 60
            continue
        fi
        beads_fail_streak=0
        health_end=$(date +%s)
        health_elapsed=$((health_end - health_start))

        local prev_delay="$current_delay"
        current_delay=$(calculate_backoff_delay "$current_delay" "$health_elapsed" "$base_delay")
        if [ "$current_delay" -ne "$prev_delay" ] && [ "$current_delay" -gt "$base_delay" ]; then
            log "WARN" "bd backend slow (${health_elapsed}s), backing off to ${current_delay}s delay"
        fi

        # 2. Load config (allows hot reload)
        load_config
        base_delay="${ITERATION_DELAY:-10}"

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

        # 4. Heal stuck tasks BEFORE dispatch — reviewers see healed tasks in same cycle
        # v2.3.9: extract in_progress from tick-cache (written by detect-phase.sh), no extra bd call
        local in_progress_cache
        in_progress_cache=$(jq -c '[.[] | select(.status == "in_progress")]' "$CLAUDEV_DIR/tick-cache.json" 2>/dev/null || echo "[]")
        heal_stuck_tasks "$in_progress_cache"

        # 5. Dispatch phase-specific actions
        dispatch_phase "$phase" "$phase_json"

        # 6. Check for completion
        if [ "$phase" = "DONE" ]; then
            log "INFO" "=========================================="
            log "INFO" "PROJECT COMPLETE"
            log "INFO" "=========================================="

            # Show completion report (SPEC_REPORT.prev.md) or fall back to architect log
            local project_dir
            project_dir=$(pwd)
            if [ -f "$project_dir/SPEC_REPORT.prev.md" ]; then
                echo ""
                echo "=== ITERATION REPORT ==="
                cat "$project_dir/SPEC_REPORT.prev.md"
                echo "========================"
                echo ""
            else
                local validating_log
                validating_log=$(ls -t "$LOGS_DIR"/architect-*.log 2>/dev/null | head -1)
                if [ -n "$validating_log" ] && [ -f "$validating_log" ]; then
                    echo ""
                    echo "=== FINAL REVIEW REPORT ==="
                    tail -50 "$validating_log" | grep -v "^$" | head -40
                    echo "==========================="
                    echo ""
                fi
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

        # 7. Auto-close completed features and epics
        # v2.3.10: skip if no open features/epics (saves 2-3 bd calls per cycle)
        local has_parents
        has_parents=$(jq '[.[] | select(.status == "open") | select(.issue_type == "feature" or .issue_type == "epic")] | length' "$CLAUDEV_DIR/tick-cache.json" 2>/dev/null || echo "1")
        if [ "$has_parents" -gt 0 ]; then
            ./scripts/close-completed-parents.sh 2>/dev/null || true
        fi

        # 8. Reset stale tasks (uses pre-dispatch cache — 600s threshold makes this safe)
        check_stale_tasks "$in_progress_cache"

        # 9. Cleanup stale worktrees (orphaned from crashed coders)
        cleanup_stale_worktrees

        # 10. Pause before next iteration (adaptive delay)
        log "INFO" "Pause ${current_delay}s..."
        sleep "$current_delay"
    done

    log "WARN" "Max cycles reached ($max_cycles)"
    rm -f "$LOCK_FILE"
    exit 1
}

main "$@"
