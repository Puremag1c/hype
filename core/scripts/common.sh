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
# По умолчанию: TASK_STALE_TIMEOUT из config или 600 секунд (10 минут)
# Пример: reset_stale_tasks 300 "shutdown"
# ВАЖНО: НЕ сбрасывает задачи с needs-review — они ждут ревью, не stale
reset_stale_tasks() {
    local stale_threshold="${1:-${TASK_STALE_TIMEOUT:-600}}"
    local log_prefix="${2:-stale}"
    local reset_count=0

    for task_id in $(bd list --status=in_progress --json 2>/dev/null | jq -r '.[].id' 2>/dev/null || true); do
        # Skip tasks waiting for review - they're not stale, just queued
        local has_needs_review
        has_needs_review=$(bd show "$task_id" --json 2>/dev/null | jq -r '.[0].labels | index("needs-review") // empty' 2>/dev/null || echo "")
        if [ -n "$has_needs_review" ]; then
            continue
        fi

        # Skip regression tasks - they're waiting for Architect smoke_review
        local has_regression
        has_regression=$(bd show "$task_id" --json 2>/dev/null | jq -r '.[0].labels | index("regression") // empty' 2>/dev/null || echo "")
        if [ -n "$has_regression" ]; then
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
            # macOS: date -j -f, Linux: date -d, WSL fallback: python3
            task_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$clean_date" +%s 2>/dev/null || \
                         date -d "$clean_date" +%s 2>/dev/null || \
                         python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('$clean_date').timestamp()))" 2>/dev/null || \
                         echo "0")
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
    review_count=$(echo "$task_json" | jq -r '[.[0].labels[]? | select(startswith("review-retry:")) | split(":")[1] | tonumber] | max // 0' 2>/dev/null || echo "0")

    # Total failures = max of all counters
    total_failures=$((retry_count > review_count ? retry_count : review_count))

    # No failures = no context needed
    if [ "$total_failures" -eq 0 ] || [ -z "$notes" ]; then
        echo ""
        return 0
    fi

    # Build structured context with specific issue type
    local issue_type="general failure"
    if [ "$review_count" -gt 0 ]; then
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
    found=$(bd list --json --limit 0 --all 2>/dev/null | \
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
    new_id=$(bd create --title="$title" --type=task --labels="$label" 2>&1 | \
        grep -oE '[A-Za-z]+-[a-z0-9]+' | head -1)
    if [ -n "$new_id" ]; then
        bd close "$new_id" --reason="Phase milestone" >/dev/null 2>&1 || true
    fi

    # Force sync to flush writes and invalidate daemon cache
    bd sync --force >/dev/null 2>&1 || true
    sleep 1  # Give daemon time to reload

    # Verify milestone is visible (retry up to 10 times with sync between attempts)
    # Prevents race condition where next cycle's bd list doesn't see the milestone
    local attempts=0
    while [ $attempts -lt 10 ]; do
        if has_milestone "$label"; then
            return 0
        fi
        ((attempts++))
        bd sync --force >/dev/null 2>&1 || true
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
    task_ids=$(bd list --json --limit 0 2>/dev/null | \
        jq -r ".[] | select(.labels[]? == \"$label\") | .id" 2>/dev/null || true)

    if [ -n "$task_ids" ]; then
        for task_id in $task_ids; do
            bd delete "$task_id" >/dev/null 2>&1 || true
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
    task_ids=$(bd list --json --limit 0 2>/dev/null | \
        jq -r '.[] | select(.labels[]? | test("^milestone:")) | .id' 2>/dev/null || true)

    local count=0
    if [ -n "$task_ids" ]; then
        for task_id in $task_ids; do
            bd delete "$task_id" >/dev/null 2>&1 || true
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
    in_progress_tasks=$(bd list --status=in_progress --json 2>/dev/null || echo "[]")
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
    task_count=$(bd list --json --limit 0 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
    [ "$task_count" -gt 0 ] && echo "  • $task_count beads task(s)"

    # Milestones
    local milestone_count
    milestone_count=$(bd list --status=closed --json --limit 0 2>/dev/null | jq '[.[] | select(.labels[]? | test("^milestone:"))] | length' 2>/dev/null || echo 0)
    [ "$milestone_count" -gt 0 ] && echo "  • $milestone_count milestone(s)"

    # Worktrees
    if [ -d "$project_dir/.hype-worktrees" ]; then
        local worktree_count
        worktree_count=$(find "$project_dir/.hype-worktrees" -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        worktree_count=$((worktree_count - 1))  # exclude parent dir
        [ "$worktree_count" -gt 0 ] && echo "  • $worktree_count worktree(s) in .hype-worktrees/"
    fi

    # Stashes
    local stash_count
    stash_count=$(git stash list 2>/dev/null | grep -ci hype || echo 0)
    [ "$stash_count" -gt 0 ] && echo "  • $stash_count hype-related git stash(es)"

    # SPEC.md
    [ -f "$project_dir/SPEC.md" ] && echo "  • SPEC.md → SPEC.prev.md (archived)"

    echo ""
    echo "Starting cleanup..."

    # 1. Sync beads (backup to issues.jsonl)
    echo "  → Syncing beads..."
    bd sync 2>/dev/null || true

    # 2. Delete logs
    echo "  → Deleting logs..."
    rm -f "$logs_dir"/*.log 2>/dev/null || true
    rm -rf "$logs_dir"/archive 2>/dev/null || true

    # 3. Clean beads tasks
    echo "  → Cleaning beads tasks..."
    bd admin cleanup --force 2>/dev/null || true

    # 4. Delete all milestones (using function from this file)
    echo "  → Deleting milestones..."
    local deleted_count
    deleted_count=$(delete_all_milestones)
    [ "$deleted_count" -gt 0 ] && echo "    Deleted $deleted_count milestone(s)"

    # 5. Clean git stash and worktrees
    echo "  → Cleaning worktrees..."
    git stash list 2>/dev/null | grep -i hype | cut -d: -f1 | xargs -I{} git stash drop {} 2>/dev/null || true
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
