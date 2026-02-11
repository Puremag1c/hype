#!/bin/bash
# core/scripts/common.sh
# Общие функции для всех скриптов hype

# Disable terminal color queries from beads (causes garbage escape sequences)
export NO_COLOR=1

# BD_TIMEOUT - timeout for bd commands (prevents hanging on daemon issues)
BD_TIMEOUT="${BD_TIMEOUT:-10s}"
BD_LOCK_FILE="${BD_LOCK_FILE:-/tmp/hype-bd.lock}"

# bd_safe - wrapper for bd commands with serialization and timeout
# Prevents daemon explosion from parallel bd calls overwhelming the socket
# Uses mkdir-based locking (works on macOS and Linux, no external deps)
bd_safe() {
    # Check for daemon explosion before any operation
    # If too many bd processes, kill all and restart fresh
    local daemon_count
    daemon_count=$(pgrep -x bd 2>/dev/null | wc -l | tr -d ' ')

    if [ "$daemon_count" -gt 30 ]; then
        >&2 echo "WARN: Beads daemon explosion detected ($daemon_count processes). Killing all and restarting."
        pkill -9 -x bd 2>/dev/null || true
        sleep 2
        # Restart daemon (will start fresh on next bd command automatically)
        bd daemon start --log-level warn >/dev/null 2>&1 || true
        sleep 1
    fi

    local lock_dir="/tmp/hype-bd.lock.d"
    local lock_timeout=30
    local waited=0

    # Try to acquire lock via mkdir (atomic operation)
    while ! mkdir "$lock_dir" 2>/dev/null; do
        # Check for stale lock (older than 60s = crashed process)
        if [ -d "$lock_dir" ]; then
            local lock_age
            # macOS: stat -f %m, Linux: stat -c %Y
            lock_age=$(( $(date +%s) - $(stat -f %m "$lock_dir" 2>/dev/null || stat -c %Y "$lock_dir" 2>/dev/null || echo 0) ))
            if [ "$lock_age" -gt 60 ]; then
                rmdir "$lock_dir" 2>/dev/null || true
                continue
            fi
        fi

        if [ $waited -ge $lock_timeout ]; then
            >&2 echo "WARN: bd lock timeout after ${lock_timeout}s, forcing unlock"
            rmdir "$lock_dir" 2>/dev/null || true
            continue
        fi

        sleep 0.5
        waited=$((waited + 1))
    done

    # Run command with timeout
    timeout_cmd "$BD_TIMEOUT" bd "$@"
    local exit_code=$?

    # Release lock
    rmdir "$lock_dir" 2>/dev/null || true

    if [ $exit_code -eq 124 ]; then
        >&2 echo "ERROR: bd command timeout: bd $*"
    fi

    return $exit_code
}
export -f bd_safe 2>/dev/null || true

# strip_ansi - removes ANSI escape sequences from input
# Handles: colors, cursor movement, OSC sequences
# Usage: echo "text" | strip_ansi
#        strip_ansi < file.log
strip_ansi() {
    sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' \
        -e 's/\x1b\][^\x07]*\x07//g' \
        -e 's/\x1b\][^\x1b]*\x1b\\//g' \
        -e 's/\x1b(B//g'
}
export -f strip_ansi 2>/dev/null || true

# retry_command - выполняет команду с retry
# Использование: retry_command RETRIES COMMAND [ARGS...]
# Возвращает: exit code последней попытки
retry_command() {
    local retries="$1"
    shift
    local attempt=1

    while [ $attempt -le $retries ]; do
        if "$@"; then
            return 0
        fi
        echo "  Attempt $attempt/$retries failed, retrying..." >&2
        attempt=$((attempt + 1))
        sleep 1
    done

    return 1
}
export -f retry_command 2>/dev/null || true

# create_minimal_project_context - fallback когда analyze-project.sh fails
# Создаёт минимальный PROJECT_CONTEXT.md с directory listing
create_minimal_project_context() {
    local project_root="${1:-.}"
    local output_file="$project_root/PROJECT_CONTEXT.md"

    cat > "$output_file" << 'EOF'
# Project Context

> Auto-generated fallback (analysis failed)
> Tech Writer will gather context from user

## Directory Structure

```
EOF
    ls -la "$project_root" 2>/dev/null | head -30 >> "$output_file"
    echo '```' >> "$output_file"
    echo "" >> "$output_file"
    echo "_Note: Full analysis was not available. Tech Writer will need to explore the project._" >> "$output_file"
}
export -f create_minimal_project_context 2>/dev/null || true

# timeout_cmd - кроссплатформенный timeout (macOS + Linux)
# Использование: timeout_cmd DURATION COMMAND [ARGS...]
# Пример: timeout_cmd 5m claude -p "prompt"
timeout_cmd() {
    local duration="$1"
    shift

    # Use gtimeout on macOS (brew install coreutils)
    if command -v gtimeout &>/dev/null; then
        gtimeout "$duration" "$@"
        return $?
    fi

    # Use timeout on Linux
    if command -v timeout &>/dev/null; then
        timeout "$duration" "$@"
        return $?
    fi

    # Convert duration to seconds for fallback
    local seconds
    case "$duration" in
        *m) seconds=$((${duration%m} * 60)) ;;
        *s) seconds=${duration%s} ;;
        *h) seconds=$((${duration%h} * 3600)) ;;
        *) seconds=$duration ;;
    esac

    # Perl-based timeout (macOS native fallback)
    perl -e '
        my $timeout = shift @ARGV;
        my $pid = fork();
        if ($pid == 0) {
            exec @ARGV or die "exec failed: $!";
        }
        $SIG{ALRM} = sub { kill "TERM", $pid; exit 124; };
        alarm $timeout;
        waitpid $pid, 0;
        alarm 0;
        exit ($? >> 8);
    ' "$seconds" "$@"
}

# Экспортируем функцию для подоболочек
export -f timeout_cmd 2>/dev/null || true

# append_notes - добавляет к существующим notes вместо перезаписи
# Использование: append_notes TASK_ID "new note text"
# Сохраняет review feedback и другую важную информацию
append_notes() {
    local task_id="$1"
    local new_note="$2"
    local current_notes
    current_notes=$(bd_safe show "$task_id" --json 2>/dev/null | jq -r '.[0].notes // ""' 2>/dev/null || echo "")

    if [ -n "$current_notes" ]; then
        echo "$current_notes

---
$new_note"
    else
        echo "$new_note"
    fi
}
export -f append_notes 2>/dev/null || true

# reset_stale_tasks - сбрасывает in_progress задачи старше threshold секунд
# Использование: reset_stale_tasks [THRESHOLD_SECONDS] [LOG_PREFIX]
# По умолчанию: TASK_STALE_TIMEOUT из config или 600 секунд (10 минут)
# Пример: reset_stale_tasks 300 "shutdown"
# ВАЖНО: НЕ сбрасывает задачи с needs-review — они ждут ревью, не stale
reset_stale_tasks() {
    local stale_threshold="${1:-${TASK_STALE_TIMEOUT:-600}}"
    local log_prefix="${2:-stale}"
    local reset_count=0

    # Single bd list call — filter in memory instead of N×bd show
    local all_tasks_json
    all_tasks_json=$(bd_safe list --status=in_progress --json --limit 0 2>/dev/null || echo "[]")

    # Filter: exclude protected labels (needs-review, reviewing, approved, regression, smoke, user-escalation)
    local candidate_ids
    candidate_ids=$(echo "$all_tasks_json" | jq -r '.[] |
        select(
            ((.labels // []) | index("needs-review") | not) and
            ((.labels // []) | index("reviewing") | not) and
            ((.labels // []) | index("approved") | not) and
            ((.labels // []) | index("trigger") | not) and
            ((.labels // []) | index("regression") | not) and
            ((.labels // []) | index("smoke") | not) and
            ((.labels // []) | index("user-escalation") | not)
        ) | .id' 2>/dev/null || true)

    local now_epoch
    now_epoch=$(date +%s)

    for task_id in $candidate_ids; do
        local updated_at
        updated_at=$(echo "$all_tasks_json" | jq -r ".[] | select(.id == \"$task_id\") | .updated_at // \"\"" 2>/dev/null)

        if [ -n "$updated_at" ]; then
            local task_epoch age
            # Strip milliseconds and timezone for cross-platform parsing
            local clean_date="${updated_at%%.*}"
            clean_date="${clean_date%%+*}"
            clean_date="${clean_date%%Z*}"
            # macOS: date -j -f, Linux: date -d, WSL fallback: python3
            task_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$clean_date" +%s 2>/dev/null || \
                         date -d "$clean_date" +%s 2>/dev/null || \
                         python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('$clean_date').timestamp()))" 2>/dev/null || \
                         echo "0")
            age=$((now_epoch - task_epoch))

            if [ "$age" -gt "$stale_threshold" ]; then
                # Append to notes instead of overwriting (preserve review feedback)
                local updated_notes
                updated_notes=$(append_notes "$task_id" "Reset: $log_prefix (${age}s without update)")
                bd_safe update "$task_id" --status=open --remove-label=executor --notes="$updated_notes" >/dev/null 2>&1 || true
                ((reset_count++)) || true
            fi
        fi
    done

    echo "$reset_count"
}
export -f reset_stale_tasks 2>/dev/null || true

# build_retry_context - формирует структурированный контекст для retry
# Использование: build_retry_context TASK_ID
# Возвращает: структурированный контекст или пустую строку
#
# Формат контекста:
#   ## Retry Context (attempt N)
#   Previous attempts:
#   - Attempt 1: <summary>
#   - Attempt 2: <summary>
#   Recommendation: <diagnosis>
build_retry_context() {
    local task_id="$1"
    local task_json notes retry_count scope_count review_count total_failures

    task_json=$(bd_safe show "$task_id" --json 2>/dev/null || echo "[]")
    notes=$(echo "$task_json" | jq -r '.[0].notes // ""' 2>/dev/null || echo "")

    # Get failure counts from labels (unified reject:N + legacy retry:N)
    retry_count=$(echo "$task_json" | jq -r '[.[0].labels[]? | select(startswith("retry:")) | split(":")[1] | tonumber] | max // 0' 2>/dev/null || echo "0")
    local reject_count
    reject_count=$(echo "$task_json" | jq -r '[.[0].labels[]? | select(startswith("reject:")) | split(":")[1] | tonumber] | max // 0' 2>/dev/null || echo "0")

    # Total failures = max of all counters
    total_failures=$((retry_count > reject_count ? retry_count : reject_count))

    # No failures = no context needed
    if [ "$total_failures" -eq 0 ] || [ -z "$notes" ]; then
        echo ""
        return 0
    fi

    # Build structured context with specific issue type
    local issue_type="general failure"
    if [ "$reject_count" -gt 0 ]; then
        issue_type="review rejection ($reject_count times)"
    elif [ "$retry_count" -gt 0 ]; then
        issue_type="execution failure ($retry_count times)"
    fi

    cat <<EOF
## Retry Context (attempt $((total_failures + 1)))

CRITICAL: This task has failed - $issue_type. DO NOT repeat the same approach.

Previous feedback:
$notes

Recommendations:
- If timeout: task may be too large, consider doing LESS
- If tests failing: fix the specific test, don't refactor
- If same error repeats: try a fundamentally different approach

EOF
}
export -f build_retry_context 2>/dev/null || true

# save_attempt_result - сохраняет результат попытки в notes
# Использование: save_attempt_result TASK_ID "result summary"
# Добавляет timestamp и номер попытки
save_attempt_result() {
    local task_id="$1"
    local result="$2"
    local task_json retry_count timestamp

    task_json=$(bd_safe show "$task_id" --json 2>/dev/null || echo "[]")
    retry_count=$(echo "$task_json" | jq -r '[.[0].labels[]? | select(startswith("retry:")) | split(":")[1] | tonumber] | max // 0' 2>/dev/null || echo "0")
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    local attempt_note="[Attempt $((retry_count + 1)) @ $timestamp] $result"
    local updated_notes
    updated_notes=$(append_notes "$task_id" "$attempt_note")

    echo "$updated_notes"
}
export -f save_attempt_result 2>/dev/null || true

# run_claude_with_progress - запускает claude с real-time progress logging
# Использование: run_claude_with_progress PROMPT MODEL TIMEOUT OUTPUT_FILE LABEL LOGS_DIR [WORKDIR]
# LABEL: короткий идентификатор для логов (например "EXEC 0", "ANALYST ux", "ARCH")
# WORKDIR: опциональная директория для запуска claude (для worktree isolation)
# Возвращает: exit code от claude
run_claude_with_progress() {
    local prompt="$1"
    local model="$2"
    local timeout="$3"
    local output_file="$4"
    local label="$5"
    local logs_dir="$6"
    local workdir="${7:-$(pwd)}"

    local raw_output="$output_file.stream"
    local running_marker="$raw_output.running"
    local tail_pid_file="$raw_output.tail.pid"
    local progress_pid=""

    # Cleanup function for trap - kills all related processes
    _cleanup_progress() {
        # Signal progress reader to stop gracefully
        rm -f "$running_marker" 2>/dev/null || true

        if [ -n "$progress_pid" ]; then
            # SIGTERM first (graceful)
            pkill -P "$progress_pid" 2>/dev/null || true
            kill "$progress_pid" 2>/dev/null || true

            # Kill tail by saved PID (more reliable than pkill -f)
            local tail_pid=""
            if [ -f "$tail_pid_file" ]; then
                tail_pid=$(cat "$tail_pid_file" 2>/dev/null)
                [ -n "$tail_pid" ] && kill "$tail_pid" 2>/dev/null || true
                rm -f "$tail_pid_file" 2>/dev/null || true
            fi

            # Grace period then SIGKILL (tail -F / jq ignore SIGTERM in pipeline)
            sleep 1
            pkill -9 -P "$progress_pid" 2>/dev/null || true
            kill -9 "$progress_pid" 2>/dev/null || true
            [ -n "$tail_pid" ] && kill -9 "$tail_pid" 2>/dev/null || true

            wait "$progress_pid" 2>/dev/null || true
        fi

        # Clean up stream file and markers
        rm -f "$raw_output" "$running_marker" "$tail_pid_file" 2>/dev/null || true
    }

    # Set trap for cleanup on exit/interrupt
    trap _cleanup_progress EXIT INT TERM

    # Create raw output file and running marker before starting tail
    : > "$raw_output"
    touch "$running_marker"

    # Start progress extractor in background
    # Uses running_marker to detect when to stop (avoids infinite tail -F)
    # Architecture: subshell -> tail -> jq -> while loop
    # tail PID saved for explicit cleanup since it doesn't exit on pipe close
    (
        trap 'exit 0' TERM INT
        sleep 0.2
        # Pipeline: tail watches file, jq extracts tool names, while loop prints
        # Save tail PID to file for cleanup (tail -F never exits on its own)
        {
            tail -F "$raw_output" 2>/dev/null &
            echo $! > "$tail_pid_file"
            wait $!
        } | \
        jq -r --unbuffered 'select(.type == "tool_use") | .name' 2>/dev/null | \
        while IFS= read -r tool_name; do
            # Exit if marker file removed (graceful shutdown signal)
            [ -f "$running_marker" ] || break
            printf '\033[90m%s\033[0m [%s] → \033[36m%s\033[0m\n' "$(date '+%H:%M:%S')" "$label" "$tool_name"
            printf '%s [%s] → %s\n' "$(date '+%H:%M:%S')" "$label" "$tool_name" >> "$logs_dir/hype.log"
        done
    ) &
    progress_pid=$!

    # Run claude with stream-json output (in specified workdir)
    # Use env vars to safely pass workdir/model (avoids quote escaping issues)
    # Use PIPESTATUS to get timeout_cmd exit code (not tee's)
    printf '%s' "$prompt" | \
        CLAUDE_WORKDIR="$workdir" CLAUDE_MODEL="$model" \
        timeout_cmd "$timeout" bash -c 'cd "$CLAUDE_WORKDIR" && claude --print --verbose --permission-mode bypassPermissions --model "$CLAUDE_MODEL" --output-format stream-json' 2>&1 | \
        tee "$raw_output" >/dev/null
    local exit_code=${PIPESTATUS[1]}

    # Signal progress reader to stop
    rm -f "$running_marker" 2>/dev/null || true

    # Cleanup progress extractor (explicit, trap handles abnormal exit)
    # SIGTERM first (graceful)
    pkill -P "$progress_pid" 2>/dev/null || true
    kill "$progress_pid" 2>/dev/null || true

    # Kill tail by saved PID
    local tail_pid=""
    if [ -f "$tail_pid_file" ]; then
        tail_pid=$(cat "$tail_pid_file" 2>/dev/null)
        [ -n "$tail_pid" ] && kill "$tail_pid" 2>/dev/null || true
        rm -f "$tail_pid_file" 2>/dev/null || true
    fi

    # Grace period then SIGKILL (tail -F / jq ignore SIGTERM in pipeline)
    sleep 1
    pkill -9 -P "$progress_pid" 2>/dev/null || true
    kill -9 "$progress_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && kill -9 "$tail_pid" 2>/dev/null || true

    wait "$progress_pid" 2>/dev/null || true

    # Convert stream-json to readable log (extract assistant text messages)
    if [ -f "$raw_output" ]; then
        jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' "$raw_output" 2>/dev/null > "$output_file" || cp "$raw_output" "$output_file" 2>/dev/null || true
    fi
    rm -f "$raw_output"

    # Clear trap before returning
    trap - EXIT INT TERM

    return $exit_code
}
export -f run_claude_with_progress 2>/dev/null || true

# map_model - маппит модель на ближайшую разрешённую
# Использование: map_model MODEL [ALLOWED_MODELS]
# Иерархия: opus > sonnet > haiku
# Стратегия: берём ближайшую более мощную (вверх по иерархии)
#
# Примеры:
#   map_model "haiku" "opus,sonnet"  → "sonnet" (ближайшая вверх)
#   map_model "opus" "sonnet,haiku"  → "sonnet" (ближайшая вниз)
#   map_model "sonnet" "opus"        → "opus"
map_model() {
    local requested="$1"
    local allowed="${2:-${ALLOWED_MODELS:-opus,sonnet,haiku}}"

    # Helper: проверить что модель в списке разрешённых
    _model_allowed() {
        case ",$allowed," in
            *",$1,"*) return 0 ;;
            *) return 1 ;;
        esac
    }

    # Если запрошенная модель разрешена — вернуть как есть
    if _model_allowed "$requested"; then
        echo "$requested"
        return 0
    fi

    # Иерархия: opus(0) > sonnet(1) > haiku(2)
    # Ищем ближайшую: сначала вверх по мощности, потом вниз
    case "$requested" in
        haiku)
            # Вверх: sonnet, opus
            if _model_allowed "sonnet"; then echo "sonnet"; return 0; fi
            if _model_allowed "opus"; then echo "opus"; return 0; fi
            ;;
        sonnet)
            # Вверх: opus. Вниз: haiku
            if _model_allowed "opus"; then echo "opus"; return 0; fi
            if _model_allowed "haiku"; then echo "haiku"; return 0; fi
            ;;
        opus)
            # Вниз: sonnet, haiku
            if _model_allowed "sonnet"; then echo "sonnet"; return 0; fi
            if _model_allowed "haiku"; then echo "haiku"; return 0; fi
            ;;
    esac

    # Fallback: первая из списка
    echo "$allowed" | cut -d',' -f1
}
export -f map_model 2>/dev/null || true

# get_changelog_context - извлекает последние N версий из CHANGELOG.md
# Использование: get_changelog_context [N] [CHANGELOG_PATH]
# По умолчанию: 3 версии, ./CHANGELOG.md
# Возвращает: текст с последними записями changelog + ссылку на файл
get_changelog_context() {
    local count="${1:-3}"
    local changelog="${2:-CHANGELOG.md}"

    if [ ! -f "$changelog" ]; then
        echo ""
        return 0
    fi

    # Extract last N version blocks (each starts with "## [")
    local result
    result=$(awk -v n="$count" '
        /^## \[/ { block_num++; if (block_num > n) exit }
        block_num >= 1 { print }
    ' "$changelog")

    if [ -z "$result" ]; then
        echo ""
        return 0
    fi

    cat <<EOF
## Recent Changes (from CHANGELOG.md)

IMPORTANT: Review this history before making architectural decisions.
If something was removed or changed recently, do NOT reintroduce it.
Full history: $changelog

$result
EOF
}
export -f get_changelog_context 2>/dev/null || true

# calculate_backoff_delay - adaptive delay based on daemon health
# If daemon is slow (>2s), doubles current delay (max 60s)
# If daemon is healthy, restores base delay
# Usage: calculate_backoff_delay current_delay health_elapsed base_delay
calculate_backoff_delay() {
    local current_delay=$1
    local health_elapsed=$2
    local base_delay=$3

    if [ "$health_elapsed" -gt 2 ]; then
        local new_delay=$((current_delay * 2))
        [ "$new_delay" -gt 60 ] && new_delay=60
        echo "$new_delay"
    else
        echo "$base_delay"
    fi
}
export -f calculate_backoff_delay 2>/dev/null || true

# is_audit_task - определяет audit-задачи (не требуют code changes)
# Использование: is_audit_task "$task_json"
# Возвращает: 0 если audit, 1 если code task
#
# ВАЖНО: Explicit opt-in только. Ложные audit опаснее ложных code tasks
# (audit без commits → reviewer застревает).
#
# Критерии audit задачи (ТОЛЬКО явные маркеры):
# 1. Label "audit"
# 2. Description содержит "AUDIT SCOPE"
is_audit_task() {
    local task_json=$1
    local description labels

    description=$(echo "$task_json" | jq -r '.[0].description // ""' 2>/dev/null)
    labels=$(echo "$task_json" | jq -r '.[0].labels[]?' 2>/dev/null || true)

    # Check 1: Explicit label "audit"
    if echo "$labels" | grep -q "^audit$"; then
        return 0  # true - is audit task
    fi

    # Check 2: Description contains "AUDIT SCOPE" marker
    if echo "$description" | grep -qi "AUDIT SCOPE"; then
        return 0  # true
    fi

    # Default: code task (safe fallback - false audit is worse than false code)
    return 1
}
export -f is_audit_task 2>/dev/null || true

# =============================================================================
# Label Management Helpers
# =============================================================================
# Prevent duplicate labels by removing all labels of a type before adding new one.
# Critical for model escalation and counter management.

# clean_model_label - atomically switch model label
# Usage: clean_model_label TASK_ID NEW_MODEL
# Removes all model:* labels, adds model:NEW_MODEL
clean_model_label() {
    local task_id="$1"
    local new_model="$2"
    local task_json old_labels

    task_json=$(bd_safe show "$task_id" --json 2>/dev/null || echo "[]")
    old_labels=$(echo "$task_json" | jq -r '.[0].labels[]? | select(startswith("model:"))' 2>/dev/null || true)

    for label in $old_labels; do
        bd_safe update "$task_id" --remove-label="$label" >/dev/null 2>&1 || true
    done

    bd_safe update "$task_id" --add-label="model:$new_model" >/dev/null 2>&1 || true
}
export -f clean_model_label 2>/dev/null || true

# set_counter_label - atomically set a counter label (removes old values)
# Usage: set_counter_label TASK_ID PREFIX VALUE
# Example: set_counter_label "task-123" "reject" "2"
# Removes all reject:* labels, adds reject:2
set_counter_label() {
    local task_id="$1"
    local prefix="$2"
    local value="$3"
    local task_json old_labels

    task_json=$(bd_safe show "$task_id" --json 2>/dev/null || echo "[]")
    old_labels=$(echo "$task_json" | jq -r ".[0].labels[]? | select(startswith(\"$prefix:\"))" 2>/dev/null || true)

    for label in $old_labels; do
        bd_safe update "$task_id" --remove-label="$label" >/dev/null 2>&1 || true
    done

    bd_safe update "$task_id" --add-label="$prefix:$value" >/dev/null 2>&1 || true
}
export -f set_counter_label 2>/dev/null || true

# get_counter_value - read current counter value from task JSON
# Usage: get_counter_value "$task_json" "reject"
# Returns: integer (0 if no counter found)
get_counter_value() {
    local task_json="$1"
    local prefix="$2"
    echo "$task_json" | jq -r "[.[0].labels[]? | select(startswith(\"$prefix:\")) | split(\":\")[1] | tonumber] | max // 0" 2>/dev/null || echo "0"
}
export -f get_counter_value 2>/dev/null || true

# =============================================================================
# Review Label Utilities (v2.2)
# =============================================================================
# Atomic label transitions for the parallel review pipeline.
# Labels: needs-review → reviewing → approved (or back to needs-review on reject)

# claim_for_review - atomically claim a task for review
# Usage: claim_for_review TASK_ID
# Transitions: needs-review → reviewing
claim_for_review() {
    local task_id="$1"
    bd_safe update "$task_id" --remove-label=needs-review --add-label=reviewing >/dev/null 2>&1
}
export -f claim_for_review 2>/dev/null || true

# approve_task - mark a reviewed task as approved (ready for merge)
# Usage: approve_task TASK_ID
# Transitions: reviewing → approved
approve_task() {
    local task_id="$1"
    bd_safe update "$task_id" --remove-label=reviewing --add-label=approved >/dev/null 2>&1
}
export -f approve_task 2>/dev/null || true

# reject_from_review - return a task to the review queue after rejection
# Usage: reject_from_review TASK_ID
# Transitions: reviewing → needs-review (task reopened for re-work by executor)
reject_from_review() {
    local task_id="$1"
    bd_safe update "$task_id" --remove-label=reviewing --add-label=needs-review --status=open --remove-label=executor >/dev/null 2>&1
}
export -f reject_from_review 2>/dev/null || true

# try_claim_for_review - atomically claim a task for review using lock file
# Usage: try_claim_for_review TASK_ID WORKTREES_DIR
# Returns: 0 if claimed, 1 if already claimed by another reviewer
# Lock: mkdir WORKTREES_DIR/review-TASK_ID.lock (atomic on all filesystems)
try_claim_for_review() {
    local task_id="$1"
    local worktrees_dir="$2"
    local lock_dir="$worktrees_dir/review-$task_id.lock"

    # Atomic mkdir — fails if another reviewer already claimed
    if ! mkdir "$lock_dir" 2>/dev/null; then
        return 1
    fi

    # Lock acquired — transition labels
    if ! claim_for_review "$task_id"; then
        # bd update failed — release lock
        rmdir "$lock_dir" 2>/dev/null || true
        return 1
    fi

    return 0
}
export -f try_claim_for_review 2>/dev/null || true

# release_review_lock - release a review claim lock
# Usage: release_review_lock TASK_ID WORKTREES_DIR
release_review_lock() {
    local task_id="$1"
    local worktrees_dir="$2"
    rmdir "$worktrees_dir/review-$task_id.lock" 2>/dev/null || true
}
export -f release_review_lock 2>/dev/null || true

# =============================================================================
# Trigger Cleanup
# =============================================================================

# cleanup_stale_trigger - close any existing open/in_progress triggers with given title
# Usage: cleanup_stale_trigger "run-smoke-review"
# Prevents zombie triggers from previous runs blocking phase detection.
cleanup_stale_trigger() {
    local trigger_title="$1"
    local old_ids
    old_ids=$(bd_safe list --json --limit 0 2>/dev/null | \
        jq -r ".[] | select(.title == \"$trigger_title\") | .id" 2>/dev/null || true)
    for old_id in $old_ids; do
        >&2 echo "WARN: Closing stale trigger $trigger_title ($old_id)"
        bd_safe close "$old_id" --reason="Stale trigger cleanup (new run)" >/dev/null 2>&1 || true
    done
}
export -f cleanup_stale_trigger 2>/dev/null || true

# =============================================================================
# Milestone Management Functions
# =============================================================================
# Milestones are marker tasks with labels like "milestone:planning-done"
# They track phase completion and are stored as closed tasks in beads.
#
# IMPORTANT: All functions use --limit 0 to handle projects with >50 tasks.
# =============================================================================

# has_milestone - проверяет существование milestone
# Использование: has_milestone "milestone:planning-done"
# Возвращает: 0 (true) если milestone существует, 1 (false) если нет
# NOTE: Ищет во ВСЕХ задачах (не только closed) — milestone существует = фаза завершена
has_milestone() {
    local label="$1"
    local found
    found=$(bd_safe list --json --limit 0 --all 2>/dev/null | \
        jq -r ".[] | select(.labels[]? == \"$label\") | .id" 2>/dev/null | head -1)
    [ -n "$found" ]
}
export -f has_milestone 2>/dev/null || true

# ensure_milestone - создаёт milestone если не существует (идемпотентно)
# Использование: ensure_milestone "milestone:planning-done" "Planning complete"
# Создаёт task с label, закрывает, синхронизирует и проверяет visibility.
# v1.9.6: Added sync + verify to prevent phase detection race condition.
ensure_milestone() {
    local label="$1"
    local title="$2"

    if has_milestone "$label"; then
        return 0
    fi

    # Create and immediately close
    local new_id
    new_id=$(bd_safe create --title="$title" --type=task --labels="$label" 2>&1 | \
        grep -oE '[A-Za-z]+-[a-z0-9]+' | head -1)
    if [ -n "$new_id" ]; then
        bd_safe close "$new_id" --reason="Phase milestone" >/dev/null 2>&1 || true
    fi

    # Force sync to flush writes and invalidate daemon cache
    bd_safe sync --force >/dev/null 2>&1 || true
    sleep 1  # Give daemon time to reload

    # Verify milestone is visible (retry up to 10 times with sync between attempts)
    # Prevents race condition where next cycle's bd list doesn't see the milestone
    local attempts=0
    while [ $attempts -lt 10 ]; do
        if has_milestone "$label"; then
            return 0
        fi
        ((attempts++))
        bd_safe sync --force >/dev/null 2>&1 || true
        sleep 1
    done

    # Milestone not visible after retries — log warning but don't fail
    # Next cycle will retry ensure_milestone anyway
    >&2 echo "WARN: Milestone $label created but not visible after 10s"
    return 1
}
export -f ensure_milestone 2>/dev/null || true

# delete_milestone - удаляет milestone task полностью
# Использование: delete_milestone "milestone:planning-done"
# Удаляет ВСЕ tasks с данным label (на случай дубликатов).
# NOTE: Ищет во ВСЕХ задачах (не только closed) — milestone может застрять в open при ошибке bd close
delete_milestone() {
    local label="$1"
    local task_ids
    task_ids=$(bd_safe list --json --limit 0 2>/dev/null | \
        jq -r ".[] | select(.labels[]? == \"$label\") | .id" 2>/dev/null || true)

    if [ -n "$task_ids" ]; then
        for task_id in $task_ids; do
            bd_safe delete "$task_id" >/dev/null 2>&1 || true
        done
    fi
}
export -f delete_milestone 2>/dev/null || true

# delete_all_milestones - удаляет все milestone tasks
# Использование: delete_all_milestones
# Используется при начале новой итерации (INIT phase).
# NOTE: Ищет во ВСЕХ задачах (не только closed) — milestones могут застрять в open
delete_all_milestones() {
    local task_ids
    task_ids=$(bd_safe list --json --limit 0 2>/dev/null | \
        jq -r '.[] | select(.labels[]? | test("^milestone:")) | .id' 2>/dev/null || true)

    local count=0
    if [ -n "$task_ids" ]; then
        for task_id in $task_ids; do
            bd_safe delete "$task_id" >/dev/null 2>&1 || true
            ((count++)) || true
        done
    fi
    echo "$count"
}
export -f delete_all_milestones 2>/dev/null || true

# =============================================================================
# Cleanup Functions
# =============================================================================

# cleanup_iteration - полная очистка после завершения итерации
# Использование: cleanup_iteration [LOGS_DIR] [PROJECT_DIR]
# Делает:
#   1. bd sync (backup в issues.jsonl)
#   2. Удаляет логи
#   3. Очищает beads tasks
#   4. Удаляет milestones
#   5. Очищает worktrees
#   6. Архивирует SPEC.md
cleanup_iteration() {
    local logs_dir="${1:-logs}"
    local project_dir="${2:-.}"

    # Check for in_progress tasks
    local in_progress_count
    local in_progress_tasks
    in_progress_tasks=$(bd_safe list --status=in_progress --json --limit 0 2>/dev/null || echo "[]")
    in_progress_count=$(echo "$in_progress_tasks" | jq 'length')

    if [[ "$in_progress_count" -gt 0 ]]; then
        echo ""
        echo "⚠️  WARNING: Found $in_progress_count task(s) in progress:"
        echo "$in_progress_tasks" | jq -r '.[] | "   - \(.id): \(.title)"'
        echo ""
        read -p "Are you sure you want to cleanup? (y/N): " confirm1
        if [[ "$confirm1" != "y" && "$confirm1" != "Y" ]]; then
            echo "Cleanup aborted."
            return 1
        fi
        read -p "This will destroy active work. Continue? (y/N): " confirm2
        if [[ "$confirm2" != "y" && "$confirm2" != "Y" ]]; then
            echo "Cleanup aborted."
            return 1
        fi
    fi

    # Preview what will be deleted
    echo ""
    echo "The following will be cleaned up:"

    # Logs
    local log_count
    log_count=$(find "$logs_dir" -name "*.log" 2>/dev/null | wc -l | tr -d ' ')
    [ "$log_count" -gt 0 ] && echo "  • $log_count log file(s) in $logs_dir/"

    # Beads tasks
    local task_count
    task_count=$(bd_safe list --json --limit 0 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
    [ "$task_count" -gt 0 ] && echo "  • $task_count beads task(s)"

    # Milestones
    local milestone_count
    milestone_count=$(bd_safe list --status=closed --json --limit 0 2>/dev/null | jq '[.[] | select(.labels[]? | test("^milestone:"))] | length' 2>/dev/null || echo 0)
    [ "$milestone_count" -gt 0 ] && echo "  • $milestone_count milestone(s)"

    # Worktrees
    if [ -d "$project_dir/.hype-worktrees" ]; then
        local worktree_count
        worktree_count=$(find "$project_dir/.hype-worktrees" -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        worktree_count=$((worktree_count - 1))  # exclude parent dir
        [ "$worktree_count" -gt 0 ] && echo "  • $worktree_count worktree(s) in .hype-worktrees/"
    fi

    # Stashes (clear ALL stashes for clean iteration)
    local stash_count
    stash_count=$(git stash list 2>/dev/null | wc -l | tr -d ' ')
    [ "$stash_count" -gt 0 ] && echo "  • $stash_count git stash(es)"

    # SPEC.md
    [ -f "$project_dir/SPEC.md" ] && echo "  • SPEC.md → SPEC.prev.md (archived)"

    echo ""
    echo "Starting cleanup..."

    # 1. Sync beads (backup to issues.jsonl)
    echo "  → Syncing beads..."
    bd_safe sync 2>/dev/null || true

    # 2. Delete logs
    echo "  → Deleting logs..."
    rm -f "$logs_dir"/*.log 2>/dev/null || true
    rm -rf "$logs_dir"/archive 2>/dev/null || true

    # 3. Clean beads tasks (close open tasks first, then cleanup)
    echo "  → Cleaning beads tasks..."
    # Close all open/in_progress tasks first (bd admin cleanup only deletes closed)
    local open_ids
    open_ids=$(bd_safe list --json --limit 0 2>/dev/null | jq -r '.[] | select(.status == "open" or .status == "in_progress") | .id' 2>/dev/null || true)
    for task_id in $open_ids; do
        bd_safe close "$task_id" --reason="Closed by hype clear" 2>/dev/null || true
    done
    # Run cleanup and show result (was silently failing before)
    bd_safe admin cleanup --force || true

    # 4. Delete all milestones (using function from this file)
    echo "  → Deleting milestones..."
    local deleted_count
    deleted_count=$(delete_all_milestones)
    [ "$deleted_count" -gt 0 ] && echo "    Deleted $deleted_count milestone(s)"

    # 5. Clean git stash and worktrees
    echo "  → Cleaning stashes and worktrees..."
    # Clear ALL stashes (hype clear = full cleanup for new iteration)
    local stash_count
    stash_count=$(git stash list 2>/dev/null | wc -l | tr -d ' ')
    if [ "$stash_count" -gt 0 ]; then
        git stash clear 2>/dev/null || true
        echo "    Cleared $stash_count stash(es)"
    fi
    rm -rf "$project_dir/.hype-worktrees" 2>/dev/null || true
    git worktree prune 2>/dev/null || true

    # 6. Archive SPEC.md
    if [ -f "$project_dir/SPEC.md" ]; then
        echo "  → Archiving SPEC.md → SPEC.prev.md..."
        mv "$project_dir/SPEC.md" "$project_dir/SPEC.prev.md"
    fi

    # 7. Create needs-spec marker for next iteration
    touch "$project_dir/.hype/needs-spec" 2>/dev/null || true

    echo "Cleanup complete!"
}
export -f cleanup_iteration 2>/dev/null || true
