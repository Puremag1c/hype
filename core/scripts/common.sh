#!/bin/bash
# core/scripts/common.sh
# Общие функции для всех скриптов hype

# Disable terminal color queries from beads (causes garbage escape sequences)
export NO_COLOR=1

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
    current_notes=$(bd show "$task_id" --json 2>/dev/null | jq -r '.[0].notes // ""' 2>/dev/null || echo "")

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
# По умолчанию: 600 секунд (10 минут)
# Пример: reset_stale_tasks 300 "shutdown"
# ВАЖНО: НЕ сбрасывает задачи с needs-review — они ждут ревью, не stale
reset_stale_tasks() {
    local stale_threshold="${1:-600}"
    local log_prefix="${2:-stale}"
    local reset_count=0

    for task_id in $(bd list --status=in_progress --json 2>/dev/null | jq -r '.[].id' 2>/dev/null || true); do
        # Skip tasks waiting for review - they're not stale, just queued
        local has_needs_review
        has_needs_review=$(bd show "$task_id" --json 2>/dev/null | jq -r '.[0].labels | index("needs-review") // empty' 2>/dev/null || echo "")
        if [ -n "$has_needs_review" ]; then
            continue
        fi

        local updated_at
        updated_at=$(bd show "$task_id" --json 2>/dev/null | jq -r '.[0].updated_at' 2>/dev/null || echo "")

        if [ -n "$updated_at" ]; then
            local task_epoch now_epoch age
            # Strip milliseconds and timezone for cross-platform parsing
            local clean_date="${updated_at%%.*}"
            clean_date="${clean_date%%+*}"
            clean_date="${clean_date%%Z*}"
            # macOS: date -j -f, Linux: date -d
            task_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$clean_date" +%s 2>/dev/null || date -d "$clean_date" +%s 2>/dev/null || echo "0")
            now_epoch=$(date +%s)
            age=$((now_epoch - task_epoch))

            if [ "$age" -gt "$stale_threshold" ]; then
                # Append to notes instead of overwriting (preserve review feedback)
                local updated_notes
                updated_notes=$(append_notes "$task_id" "Reset: $log_prefix (${age}s without update)")
                bd update "$task_id" --status=open --remove-label=executor --notes="$updated_notes" >/dev/null 2>&1 || true
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

    task_json=$(bd show "$task_id" --json 2>/dev/null || echo "[]")
    notes=$(echo "$task_json" | jq -r '.[0].notes // ""' 2>/dev/null || echo "")

    # Get all failure counts from labels
    retry_count=$(echo "$task_json" | jq -r '[.[0].labels[]? | select(startswith("retry:")) | split(":")[1] | tonumber] | max // 0' 2>/dev/null || echo "0")
    scope_count=$(echo "$task_json" | jq -r '[.[0].labels[]? | select(startswith("scope-violation:")) | split(":")[1] | tonumber] | max // 0' 2>/dev/null || echo "0")
    review_count=$(echo "$task_json" | jq -r '[.[0].labels[]? | select(startswith("review-retry:")) | split(":")[1] | tonumber] | max // 0' 2>/dev/null || echo "0")

    # Total failures = max of all counters
    total_failures=$((retry_count > scope_count ? retry_count : scope_count))
    total_failures=$((total_failures > review_count ? total_failures : review_count))

    # No failures = no context needed
    if [ "$total_failures" -eq 0 ] || [ -z "$notes" ]; then
        echo ""
        return 0
    fi

    # Build structured context with specific issue type
    local issue_type="general failure"
    if [ "$scope_count" -gt 0 ]; then
        issue_type="SCOPE VIOLATION ($scope_count times)"
    elif [ "$review_count" -gt 0 ]; then
        issue_type="review rejection ($review_count times)"
    elif [ "$retry_count" -gt 0 ]; then
        issue_type="execution failure ($retry_count times)"
    fi

    cat <<EOF
## Retry Context (attempt $((total_failures + 1)))

CRITICAL: This task has failed - $issue_type. DO NOT repeat the same approach.

Previous feedback:
$notes

Recommendations:
- If SCOPE VIOLATION: You edited files NOT in the 'files:' list. Work ONLY on listed files!
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

    task_json=$(bd show "$task_id" --json 2>/dev/null || echo "[]")
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

    # Create raw output file before starting tail
    : > "$raw_output"

    # Start progress extractor in background (shows tool calls in real-time)
    # tail -F retries if file is replaced, jq --unbuffered for immediate output
    (
        sleep 0.2
        tail -F "$raw_output" 2>/dev/null | \
        jq -r --unbuffered 'select(.type == "tool_use") | .name' 2>/dev/null | \
        while IFS= read -r tool_name; do
            printf '\033[90m%s\033[0m [%s] → \033[36m%s\033[0m\n' "$(date '+%H:%M:%S')" "$label" "$tool_name"
            printf '%s [%s] → %s\n' "$(date '+%H:%M:%S')" "$label" "$tool_name" >> "$logs_dir/hype.log"
        done
    ) &
    local progress_pid=$!

    # Run claude with stream-json output (in specified workdir)
    # Use env vars to safely pass workdir/model (avoids quote escaping issues)
    # Use PIPESTATUS to get timeout_cmd exit code (not tee's)
    printf '%s' "$prompt" | \
        CLAUDE_WORKDIR="$workdir" CLAUDE_MODEL="$model" \
        timeout_cmd "$timeout" bash -c 'cd "$CLAUDE_WORKDIR" && claude --print --verbose --permission-mode bypassPermissions --model "$CLAUDE_MODEL" --output-format stream-json' 2>&1 | \
        tee "$raw_output" >/dev/null
    local exit_code=${PIPESTATUS[1]}

    # Cleanup progress extractor
    kill $progress_pid 2>/dev/null || true
    wait $progress_pid 2>/dev/null || true

    # Convert stream-json to readable log (extract assistant text messages)
    jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' "$raw_output" 2>/dev/null > "$output_file" || cp "$raw_output" "$output_file"
    rm -f "$raw_output"

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

# is_audit_task - определяет audit-задачи (не требуют code changes)
# Использование: is_audit_task "$task_json"
# Возвращает: 0 если audit, 1 если code task
#
# Критерии audit задачи:
# 1. Title содержит: Verify, Audit, Check, Validate
# 2. Description содержит "AUDIT SCOPE"
# 3. Нет files: директивы И done_when указывает на анализ
is_audit_task() {
    local task_json=$1
    local title description

    title=$(echo "$task_json" | jq -r '.[0].title // ""' 2>/dev/null)
    description=$(echo "$task_json" | jq -r '.[0].description // ""' 2>/dev/null)

    # Check 1: Title contains audit keywords (Verify, Audit, Check, Validate)
    if echo "$title" | grep -qiE "(^|\[|\s)(Verify|Audit|Check|Validate)(\s|\]|$)"; then
        return 0  # true - is audit task
    fi

    # Check 2: Description contains "AUDIT SCOPE" marker
    if echo "$description" | grep -qi "AUDIT SCOPE"; then
        return 0  # true
    fi

    # Check 3: No files: directive AND done_when implies analysis (not code)
    if ! echo "$description" | grep -q "^files:"; then
        if echo "$description" | grep -qiE "done_when:.*(\bдокументир|\breport|\banalys|\baudit|\bverif)"; then
            return 0  # true
        fi
    fi

    return 1  # false - not audit task
}
export -f is_audit_task 2>/dev/null || true
