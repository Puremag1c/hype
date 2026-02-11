#!/bin/bash
# core/scripts/doctor.sh
# Entry point для Doctor агента — интерактивная диагностика HYPE.
#
# Использование:
#   hype doctor          # Интерактивная диагностика
#   hype doctor --report # Только создать doctor-log (non-interactive)
#
# Doctor собирает контекст о состоянии системы и запускает Claude
# для диагностики проблем. Результат — doctor-log для архитектора.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

PROJECT_DIR=$(pwd)
CLAUDEV_DIR="$PROJECT_DIR/.hype"
LOGS_DIR="$PROJECT_DIR/logs"
HYPE_HOME="${HYPE_HOME:-$HOME/.hype}"

# Parse arguments
REPORT_ONLY=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --report)
            REPORT_ONLY=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# === Logging ===

mkdir -p "$LOGS_DIR"

log() {
    local level=$1
    local message=$2
    local color="" reset="\033[0m" gray="\033[90m"
    # HYPE brand colors (neon pink gradient)
    local hype_colored="\033[38;2;255;0;102mH\033[38;2;255;51;153mY\033[38;2;255;102;204mP\033[38;2;204;255;0mE\033[0m"

    case "$level" in
        INFO)    color="\033[32m" ;;
        WARN)    color="\033[33m" ;;
        ERROR)   color="\033[31m" ;;
        DOCTOR)  color="\033[35m" ;;  # magenta for doctor
    esac

    printf "${gray}%s${reset} [${hype_colored} DOCTOR] ${color}%s${reset}: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [HYPE DOCTOR] $level: $message" >> "$LOGS_DIR/hype.log"
}

# === Gather context ===

gather_context() {
    local context=""

    # HYPE version and script health
    context+="## HYPE Version\n"
    context+="\`\`\`\n"
    context+="Version: $(cat "$HYPE_HOME/VERSION" 2>/dev/null || cat "VERSION" 2>/dev/null || echo "unknown")\n"
    local missing_scripts=""
    for script in detect-phase.sh run-executors.sh run-analysts.sh run-reviewers.sh run-merge-queue.sh; do
        if [[ ! -x "./scripts/$script" ]] && [[ ! -x "$SCRIPT_DIR/$script" ]]; then
            missing_scripts+="MISSING: $script\n"
        fi
    done
    if [ -n "$missing_scripts" ]; then
        context+="CRITICAL — Missing scripts:\n$missing_scripts"
    else
        context+="All required scripts present\n"
    fi
    context+="\`\`\`\n\n"

    # Beads status
    context+="## Beads Status\n"
    context+="\`\`\`\n"
    context+=$(bd_safe sync --status 2>&1 || echo "DAEMON_ERROR: bd sync timeout")
    context+="\n\n"
    context+=$(bd_safe stats 2>&1 || echo "bd stats failed")
    context+="\n\`\`\`\n\n"

    # In-progress tasks
    context+="## In-Progress Tasks\n"
    context+="\`\`\`\n"
    context+=$(bd_safe list --status=in_progress --json --limit 0 2>/dev/null | jq -r '.[] | "\(.id): \(.title) (updated: \(.updated_at))"' 2>/dev/null || echo "none")
    context+="\n\`\`\`\n\n"

    # Blocked tasks
    context+="## Blocked Tasks\n"
    context+="\`\`\`\n"
    context+=$(bd_safe blocked 2>&1 || echo "none")
    context+="\n\`\`\`\n\n"

    # Current phase
    context+="## Current Phase\n"
    context+="\`\`\`\n"
    context+=$(./scripts/detect-phase.sh 2>&1 || echo "detect-phase.sh failed")
    context+="\n\`\`\`\n\n"

    # Running processes
    context+="## Running Processes\n"
    context+="\`\`\`\n"
    context+=$(pgrep -fl "claude|hype" 2>/dev/null || echo "no claude/hype processes")
    context+="\n\`\`\`\n\n"

    # Git status
    context+="## Git Status\n"
    context+="\`\`\`\n"
    context+=$(git status --short 2>/dev/null || echo "not a git repo")
    context+="\n"
    context+="Worktrees:\n"
    context+=$(git worktree list 2>/dev/null || echo "none")
    context+="\n"
    context+="Locks:\n"
    context+=$(ls -la .git/*.lock 2>/dev/null || echo "no locks")
    context+="\n\`\`\`\n\n"

    # HYPE markers
    context+="## HYPE Markers\n"
    context+="\`\`\`\n"
    context+="hype.lock: $(ls -la "$CLAUDEV_DIR/hype.lock" 2>/dev/null || echo "not present")\n"
    context+="needs-spec: $(ls -la "$CLAUDEV_DIR/needs-spec" 2>/dev/null || echo "not present")\n"
    context+="force-phase: $(cat "$CLAUDEV_DIR/force-phase" 2>/dev/null || echo "not present")\n"
    context+="\`\`\`\n\n"

    # Worktrees directory
    context+="## Executor Worktrees\n"
    context+="\`\`\`\n"
    context+=$(ls -la .hype-worktrees/ 2>/dev/null || echo "no worktrees directory")
    context+="\n\`\`\`\n\n"

    # v2.2: Reviewer slots and review pipeline state
    context+="## Review Pipeline (v2.2)\n"
    context+="\`\`\`\n"
    context+="Reviewer slots:\n"
    context+=$(ls -la .hype-worktrees/reviewer-*.lock 2>/dev/null || echo "no active reviewers")
    context+="\n"
    context+="Review locks:\n"
    context+=$(ls -la .hype-worktrees/review-*.lock 2>/dev/null || echo "no review locks")
    context+="\n\n"
    context+="Reviewing tasks:\n"
    context+=$(bd_safe list --status=in_progress --json --limit 0 2>/dev/null | jq -r '.[] | select((.labels // []) | index("reviewing")) | "\(.id): \(.title) (updated: \(.updated_at))"' 2>/dev/null || echo "none")
    context+="\n\n"
    context+="Approved tasks:\n"
    context+=$(bd_safe list --status=in_progress --json --limit 0 2>/dev/null | jq -r '.[] | select((.labels // []) | index("approved")) | "\(.id): \(.title) (updated: \(.updated_at))"' 2>/dev/null || echo "none")
    context+="\n\n"
    context+="Trigger tasks (should be closed or excluded):\n"
    context+=$(bd_safe list --json --limit 0 2>/dev/null | jq -r '.[] | select((.labels // []) | index("trigger")) | "\(.id): \(.title) [status: \(.status)]"' 2>/dev/null || echo "none")
    context+="\n\n"
    context+="Tasks with secrets-warning:\n"
    context+=$(bd_safe list --json --limit 0 2>/dev/null | jq -r '.[] | select((.labels // []) | index("secrets-warning")) | "\(.id): \(.title)"' 2>/dev/null || echo "none")
    context+="\n\`\`\`\n\n"

    # Recent logs
    context+="## Recent Logs (last 30 lines)\n"
    context+="\`\`\`\n"
    context+=$(tail -30 "$LOGS_DIR/hype.log" 2>/dev/null || echo "no hype.log")
    context+="\n\`\`\`\n\n"

    echo -e "$context"
}

# === Load knowledge base ===

load_knowledge() {
    local knowledge=""

    # Architecture docs
    if [ -f "$HYPE_HOME/docs/architecture.md" ]; then
        knowledge+="# HYPE Architecture\n\n"
        knowledge+=$(cat "$HYPE_HOME/docs/architecture.md")
        knowledge+="\n\n"
    elif [ -f "docs/architecture.md" ]; then
        knowledge+="# HYPE Architecture\n\n"
        knowledge+=$(cat "docs/architecture.md")
        knowledge+="\n\n"
    fi

    # Troubleshooting docs
    if [ -f "$HYPE_HOME/docs/troubleshooting.md" ]; then
        knowledge+="# Troubleshooting Guide\n\n"
        knowledge+=$(cat "$HYPE_HOME/docs/troubleshooting.md")
        knowledge+="\n\n"
    elif [ -f "docs/troubleshooting.md" ]; then
        knowledge+="# Troubleshooting Guide\n\n"
        knowledge+=$(cat "docs/troubleshooting.md")
        knowledge+="\n\n"
    fi

    echo -e "$knowledge"
}

# === Build prompt ===

build_prompt() {
    local agent_prompt context knowledge

    # Read agent prompt
    local agent_file="$HYPE_HOME/core/agents/doctor.md"
    if [ ! -f "$agent_file" ]; then
        agent_file=".claude/agents/doctor.md"
    fi

    if [ ! -f "$agent_file" ]; then
        log "ERROR" "Doctor agent file not found"
        exit 1
    fi

    agent_prompt=$(cat "$agent_file")
    context=$(gather_context)
    knowledge=$(load_knowledge)

    cat << EOF
$agent_prompt

---
# Current System State

PROJECT_ROOT: $PROJECT_DIR
REPORT_ONLY: $REPORT_ONLY

$context

---
# Knowledge Base

$knowledge
EOF
}

# === Run doctor ===

run_doctor() {
    local prompt
    prompt=$(build_prompt)

    log "DOCTOR" "Starting diagnostic session..."

    # Model for doctor (configurable, default sonnet)
    local doctor_model
    doctor_model=$(map_model "${MODEL_DOCTOR:-opus}")

    if [ "$REPORT_ONLY" = true ]; then
        log "INFO" "Report-only mode — non-interactive"
        # Non-interactive: just collect data and create doctor-log
        printf '%s' "$prompt" | timeout_cmd 5m claude --model "$doctor_model" --print 2>&1 | tee "$LOGS_DIR/doctor-report.log"
    else
        # Interactive mode
        printf '%s' "$prompt" | claude --model "$doctor_model"
    fi

    log "DOCTOR" "Diagnostic session ended"
}

# === Main ===

main() {
    # Ensure directories exist
    mkdir -p "$CLAUDEV_DIR/logs"

    # Check claude CLI
    if ! command -v claude &>/dev/null; then
        log "ERROR" "Claude CLI not found. Install: npm install -g @anthropic/claude-code"
        exit 1
    fi

    # Check beads
    if ! command -v bd &>/dev/null; then
        log "ERROR" "Beads (bd) not found"
        exit 1
    fi

    log "INFO" "=========================================="
    log "INFO" "HYPE DOCTOR"
    log "INFO" "Project: $PROJECT_DIR"
    log "INFO" "=========================================="

    # Ensure bd daemon is alive before gathering context
    # check_beads (from common.sh) handles soft restart + hard kill recovery
    # Without this, gather_context spends 60-70s on timeouts with empty results
    if ! check_beads; then
        log "ERROR" "Beads daemon unrecoverable — Doctor will run with limited data"
    fi

    run_doctor
}

main "$@"
