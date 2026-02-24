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

# === Report functions ===

sanitize_doctor_report() {
    local file="$1"
    [[ -f "$file" ]] || return 1

    local tmp="${file}.tmp"
    # Replace HOME path with ~
    sed "s|$HOME|~|g" "$file" > "$tmp" && mv "$tmp" "$file"
    # Replace PROJECT_DIR with $PROJECT
    sed "s|$PROJECT_DIR|\$PROJECT|g" "$file" > "$tmp" && mv "$tmp" "$file"
    # Redact API keys (ANTHROPIC_API_KEY=..., OPENAI_API_KEY=..., etc.)
    sed 's/\([A-Z_]*API_KEY\)=[^ ]*/\1=[REDACTED]/g' "$file" > "$tmp" && mv "$tmp" "$file"
    # Redact sk-* keys
    sed 's/sk-[a-zA-Z0-9_-]\{20,\}/[REDACTED_KEY]/g' "$file" > "$tmp" && mv "$tmp" "$file"
    # Redact Bearer tokens
    sed 's/Bearer [a-zA-Z0-9_.-]\{10,\}/Bearer [REDACTED]/g' "$file" > "$tmp" && mv "$tmp" "$file"
}

check_gh_available() {
    command -v gh &>/dev/null || return 1
    gh auth status &>/dev/null || return 1
    return 0
}

find_latest_doctor_log() {
    local since_ts="$1"
    local latest=""
    while IFS= read -r f; do
        local file_ts
        if [[ "$(uname -s)" == "Darwin" ]]; then
            file_ts=$(stat -f '%m' "$f" 2>/dev/null) || continue
        else
            file_ts=$(stat -c '%Y' "$f" 2>/dev/null) || continue
        fi
        if [[ "$file_ts" -ge "$since_ts" ]]; then
            latest="$f"
            break
        fi
    done < <(ls -t "$CLAUDEV_DIR/logs"/doctor-*.md 2>/dev/null)
    [[ -n "$latest" ]] && echo "$latest"
}

save_report_output() {
    local source_file="$1"
    [[ -f "$source_file" ]] || return 1
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local dest="$CLAUDEV_DIR/logs/doctor-$timestamp.md"
    mkdir -p "$CLAUDEV_DIR/logs"
    cp "$source_file" "$dest"
    echo "$dest"
}

send_doctor_report() {
    local file="$1"
    [[ -f "$file" ]] || return 1

    # Extract title from "## Reported Symptom" section
    local title
    title=$(sed -n '/^## Reported Symptom/{n;/^$/d;p;q;}' "$file" 2>/dev/null)
    if [[ -z "$title" ]]; then
        title="Doctor report $(date +%Y-%m-%d)"
    fi
    # Truncate title to 100 chars
    title="${title:0:100}"

    local body
    body=$(cat "$file")

    # Ensure label exists (idempotent — no error if already present)
    gh label create "doctor-report" --repo "Puremag1c/hype" \
        --description "Auto-generated doctor diagnostic report" \
        --color "d4c5f9" 2>/dev/null || true

    gh issue create \
        --repo "Puremag1c/hype" \
        --label "doctor-report" \
        --title "$title" \
        --body "$body" 2>&1 || {
        log "ERROR" "Failed to send doctor report via gh"
        return 1
    }
}

# === Gather context ===

gather_context() {
    local context=""

    # HYPE version and script health
    context+="## HYPE Version\n"
    context+="\`\`\`\n"
    context+="Version: $(cat "$HYPE_HOME/VERSION" 2>/dev/null || cat "VERSION" 2>/dev/null || echo "unknown")\n"
    local missing_scripts=""
    for script in detect-phase.sh run-coders.sh run-analysts.sh run-seniors.sh run-merge-queue.sh; do
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
    context+="Senior slots:\n"
    context+=$(ls -la .hype-worktrees/senior-*.lock 2>/dev/null || echo "no active seniors")
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

    # Model for doctor (configurable, default opus)
    local doctor_model
    doctor_model=$(map_model "${MODEL_DOCTOR:-opus}")

    # Pre-approve safe read-only tools (matches SAFE list in doctor.md)
    # Modifications (bd update, bd close, rm, pkill) still require user confirmation
    local allowed_tools='Read,Glob,Grep'
    allowed_tools+=',Bash(bd list:*),Bash(bd show:*),Bash(bd stats:*)'
    allowed_tools+=',Bash(bd blocked:*),Bash(bd sync --status:*)'
    allowed_tools+=',Bash(bd dep cycles:*),Bash(bd daemon status:*)'
    allowed_tools+=',Bash(pgrep:*),Bash(ps:*),Bash(kill -0:*)'
    allowed_tools+=',Bash(git status:*),Bash(git worktree list:*),Bash(git branch:*)'
    allowed_tools+=',Bash(ls:*),Bash(cat:*),Bash(tail:*),Bash(head:*)'
    allowed_tools+=',Bash(./scripts/detect-phase.sh:*),Bash(mkdir -p .hype:*)'

    if [ "$REPORT_ONLY" = true ]; then
        log "INFO" "Report-only mode — non-interactive"
        # Non-interactive: capture output, save, sanitize, send
        printf '%s' "$prompt" | timeout_cmd 5m claude --model "$doctor_model" --print --allowedTools "$allowed_tools" 2>&1 | tee "$LOGS_DIR/doctor-report.log"

        local saved_file
        saved_file=$(save_report_output "$LOGS_DIR/doctor-report.log")
        if [[ -n "$saved_file" ]]; then
            sanitize_doctor_report "$saved_file"
            log "INFO" "Doctor report saved: $saved_file"
            if check_gh_available; then
                send_doctor_report "$saved_file"
                log "INFO" "Doctor report sent to GitHub"
            else
                log "WARN" "gh not available — report not sent"
            fi
        else
            log "WARN" "Failed to save doctor report"
        fi
    else
        # Interactive mode: track session start, then find agent's doctor-log
        local session_start
        session_start=$(date +%s)

        printf '%s' "$prompt" | claude --model "$doctor_model" --allowedTools "$allowed_tools"

        # Find doctor-log created by the agent during session
        local doctor_log
        doctor_log=$(find_latest_doctor_log "$session_start")
        if [[ -n "$doctor_log" ]]; then
            sanitize_doctor_report "$doctor_log"
            log "INFO" "Doctor log sanitized: $doctor_log"
            if check_gh_available; then
                printf '\n'
                read -r -p "Отправить doctor-report в GitHub? [y/n] " send_choice
                if [[ "$send_choice" =~ ^[Yy]$ ]]; then
                    send_doctor_report "$doctor_log"
                    log "INFO" "Doctor report sent to GitHub"
                fi
            fi
        else
            log "WARN" "No doctor-log found after session"
        fi
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
