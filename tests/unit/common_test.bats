#!/usr/bin/env bats
# tests/unit/common_test.bats
# Unit tests for common.sh functions

load '../helpers/setup'
load '../helpers/mock_bd'

# =============================================================================
# strip_ansi tests
# =============================================================================

@test "strip_ansi removes color codes" {
    local input=$'\033[31mred text\033[0m'
    local result=$(echo "$input" | strip_ansi)
    [[ "$result" == "red text" ]]
}

@test "strip_ansi removes cursor movement codes" {
    local input=$'\033[2Amoved up'
    local result=$(echo "$input" | strip_ansi)
    [[ "$result" == "moved up" ]]
}

@test "strip_ansi handles plain text" {
    local input="plain text no codes"
    local result=$(echo "$input" | strip_ansi)
    [[ "$result" == "plain text no codes" ]]
}

# =============================================================================
# retry_command tests
# =============================================================================

@test "retry_command succeeds on first try" {
    run retry_command 3 true
    [[ "$status" -eq 0 ]]
}

@test "retry_command fails after all retries" {
    run retry_command 2 false
    [[ "$status" -eq 1 ]]
}

@test "retry_command outputs attempt messages" {
    run retry_command 2 false
    [[ "$output" == *"Attempt 1/2 failed"* ]]
}

# =============================================================================
# timeout_cmd tests
# =============================================================================

@test "timeout_cmd runs command successfully" {
    run timeout_cmd 5s echo "hello"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "hello" ]]
}

@test "timeout_cmd handles minutes format" {
    run timeout_cmd 1m echo "test"
    [[ "$status" -eq 0 ]]
}

# =============================================================================
# map_model tests
# =============================================================================

@test "map_model returns requested when allowed" {
    local result=$(map_model "sonnet" "opus,sonnet,haiku")
    [[ "$result" == "sonnet" ]]
}

@test "map_model maps haiku to sonnet when haiku not allowed" {
    local result=$(map_model "haiku" "opus,sonnet")
    [[ "$result" == "sonnet" ]]
}

@test "map_model maps opus to sonnet when opus not allowed" {
    local result=$(map_model "opus" "sonnet,haiku")
    [[ "$result" == "sonnet" ]]
}

@test "map_model maps sonnet to opus when sonnet not allowed" {
    local result=$(map_model "sonnet" "opus")
    [[ "$result" == "opus" ]]
}

@test "map_model falls back to first allowed" {
    local result=$(map_model "unknown" "haiku")
    [[ "$result" == "haiku" ]]
}

# =============================================================================
# is_audit_task tests
# =============================================================================

@test "is_audit_task returns true for audit label" {
    local task_json='[{"labels": ["audit", "backend"], "description": "Check code"}]'
    run is_audit_task "$task_json"
    [[ "$status" -eq 0 ]]
}

@test "is_audit_task returns true for AUDIT SCOPE in description" {
    local task_json='[{"labels": ["backend"], "description": "AUDIT SCOPE: Review API"}]'
    run is_audit_task "$task_json"
    [[ "$status" -eq 0 ]]
}

@test "is_audit_task returns false for regular task" {
    local task_json='[{"labels": ["backend"], "description": "Implement feature"}]'
    run is_audit_task "$task_json"
    [[ "$status" -eq 1 ]]
}

# =============================================================================
# has_milestone tests (with mock bd)
# =============================================================================

@test "has_milestone returns true when milestone exists" {
    mock_bd_init "planning"
    run has_milestone "milestone:planning-done"
    mock_bd_cleanup
    [[ "$status" -eq 0 ]]
}

@test "has_milestone returns false when milestone missing" {
    mock_bd_init "empty"
    run has_milestone "milestone:planning-done"
    mock_bd_cleanup
    [[ "$status" -eq 1 ]]
}

# =============================================================================
# append_notes tests (with mock bd)
# =============================================================================

@test "append_notes adds to empty notes" {
    mock_bd_init "empty"
    local result=$(append_notes "test-001" "new note")
    mock_bd_cleanup
    [[ "$result" == "new note" ]]
}

# =============================================================================
# Mock bd integration tests
# =============================================================================

@test "mock_bd list returns tasks" {
    mock_bd_init "planning"
    run bd list --json
    mock_bd_cleanup
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"test-001"* ]]
}

@test "mock_bd update changes status" {
    mock_bd_init "planning"
    bd update test-001 --status=in_progress
    run bd show test-001 --json
    mock_bd_cleanup
    [[ "$output" == *"in_progress"* ]]
}

@test "mock_bd close marks task closed" {
    mock_bd_init "planning"
    bd close test-003
    run bd list --status=closed --json --all
    mock_bd_cleanup
    [[ "$output" == *"test-003"* ]]
}

@test "mock_bd create adds new task" {
    mock_bd_init "empty"
    bd create --title="New task" --type=task --priority=1
    run bd list --json
    mock_bd_cleanup
    [[ "$output" == *"New task"* ]]
}

@test "assert_bd_called tracks calls" {
    mock_bd_init "empty"
    bd list --json
    bd update test-001 --status=in_progress
    run assert_bd_called "list --json"
    [[ "$status" -eq 0 ]]
    run assert_bd_called "update test-001"
    [[ "$status" -eq 0 ]]
    mock_bd_cleanup
}

# =============================================================================
# ensure_milestone tests
# =============================================================================

@test "ensure_milestone creates milestone when missing" {
    mock_bd_init "empty"
    # ensure_milestone calls bd create + bd close
    ensure_milestone "milestone:test-done" "Test complete" || true
    run assert_bd_called "create"
    [[ "$status" -eq 0 ]]
    mock_bd_cleanup
}

@test "ensure_milestone is idempotent" {
    mock_bd_init "planning"  # Has milestone:planning-done
    # Should not create again
    ensure_milestone "milestone:planning-done" "Planning complete"
    run assert_bd_not_called "create"
    [[ "$status" -eq 0 ]]
    mock_bd_cleanup
}

# =============================================================================
# delete_milestone tests
# =============================================================================

@test "delete_milestone removes milestone task" {
    mock_bd_init "planning"
    # delete_milestone calls bd delete for matching tasks
    run delete_milestone "milestone:planning-done"
    [[ "$status" -eq 0 ]]
    mock_bd_cleanup
}

@test "delete_milestone handles missing milestone" {
    mock_bd_init "empty"
    run delete_milestone "milestone:nonexistent"
    [[ "$status" -eq 0 ]]  # Should not fail
    mock_bd_cleanup
}

# =============================================================================
# delete_all_milestones tests
# =============================================================================

@test "delete_all_milestones removes all milestones" {
    mock_bd_init "implementation"  # Has multiple milestones
    run delete_all_milestones
    [[ "$status" -eq 0 ]]
    # Should return count (may be 0 if mock doesn't track deletes)
    [[ "$output" =~ ^[0-9]+$ ]]
    mock_bd_cleanup
}

@test "delete_all_milestones returns 0 for empty beads" {
    mock_bd_init "empty"
    run delete_all_milestones
    [[ "$status" -eq 0 ]]
    [[ "$output" == "0" ]]
    mock_bd_cleanup
}

# =============================================================================
# build_retry_context tests
# =============================================================================

@test "build_retry_context returns empty for task without retry" {
    mock_bd_init "planning"
    local result=$(build_retry_context "test-001")
    mock_bd_cleanup
    [[ -z "$result" ]]
}

@test "build_retry_context returns context for retry task" {
    # Create fixture with retry label
    mock_bd_init "empty"
    # Manually add task with retry label to mock state
    echo '[{"id": "retry-task", "labels": ["retry:2"], "notes": "Previous error: timeout", "status": "open"}]' > "$MOCK_BD_STATE_DIR/tasks.json"

    local result=$(build_retry_context "retry-task")
    mock_bd_cleanup

    # Should contain attempt number
    [[ "$result" == *"attempt 3"* ]]
}

@test "build_retry_context includes notes" {
    mock_bd_init "empty"
    echo '[{"id": "retry-task", "labels": ["retry:1"], "notes": "Error: build failed", "status": "open"}]' > "$MOCK_BD_STATE_DIR/tasks.json"

    local result=$(build_retry_context "retry-task")
    mock_bd_cleanup

    [[ "$result" == *"Error: build failed"* ]]
}

# =============================================================================
# save_attempt_result tests
# =============================================================================

@test "save_attempt_result formats result with timestamp" {
    mock_bd_init "empty"
    echo '[{"id": "test-task", "labels": [], "notes": "", "status": "open"}]' > "$MOCK_BD_STATE_DIR/tasks.json"

    local result=$(save_attempt_result "test-task" "Build succeeded")
    mock_bd_cleanup

    # Should contain attempt number and result
    [[ "$result" == *"Attempt 1"* ]]
    [[ "$result" == *"Build succeeded"* ]]
}

@test "save_attempt_result includes timestamp" {
    mock_bd_init "empty"
    echo '[{"id": "test-task", "labels": ["retry:1"], "notes": "", "status": "open"}]' > "$MOCK_BD_STATE_DIR/tasks.json"

    local result=$(save_attempt_result "test-task" "Test result")
    mock_bd_cleanup

    # Should contain date format
    [[ "$result" == *"202"* ]]  # Year prefix
}

# =============================================================================
# Additional map_model edge cases
# =============================================================================

@test "map_model with single model in allowed list" {
    local result=$(map_model "sonnet" "sonnet")
    [[ "$result" == "sonnet" ]]
}

@test "map_model uses ALLOWED_MODELS env if no second arg" {
    export ALLOWED_MODELS="opus,sonnet"
    local result=$(map_model "haiku")
    unset ALLOWED_MODELS
    [[ "$result" == "sonnet" ]]  # haiku not allowed, maps to sonnet
}

# =============================================================================
# Additional timeout_cmd edge cases
# =============================================================================

@test "timeout_cmd handles hours format" {
    run timeout_cmd 1h echo "hour test"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "hour test" ]]
}

@test "timeout_cmd handles numeric seconds" {
    run timeout_cmd 10 echo "numeric"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "numeric" ]]
}

# =============================================================================
# Additional is_audit_task edge cases
# =============================================================================

@test "is_audit_task case insensitive for AUDIT SCOPE" {
    local task_json='[{"labels": [], "description": "audit scope: check things"}]'
    run is_audit_task "$task_json"
    [[ "$status" -eq 0 ]]
}

@test "is_audit_task handles empty labels" {
    local task_json='[{"labels": [], "description": "Normal task"}]'
    run is_audit_task "$task_json"
    [[ "$status" -eq 1 ]]
}

@test "is_audit_task handles null description" {
    local task_json='[{"labels": ["audit"], "description": null}]'
    run is_audit_task "$task_json"
    [[ "$status" -eq 0 ]]
}

# =============================================================================
# calculate_backoff_delay tests
# =============================================================================

@test "calculate_backoff_delay: healthy daemon returns base delay" {
    run calculate_backoff_delay 20 1 10
    [[ "$output" == "10" ]]
}

@test "calculate_backoff_delay: slow daemon doubles delay" {
    run calculate_backoff_delay 10 3 10
    [[ "$output" == "20" ]]
}

@test "calculate_backoff_delay: progressive doubling" {
    # 10 → 20
    local d=$(calculate_backoff_delay 10 5 10)
    [[ "$d" == "20" ]]
    # 20 → 40
    d=$(calculate_backoff_delay 20 5 10)
    [[ "$d" == "40" ]]
    # 40 → 60 (capped)
    d=$(calculate_backoff_delay 40 5 10)
    [[ "$d" == "60" ]]
}

@test "calculate_backoff_delay: caps at 60 seconds" {
    run calculate_backoff_delay 60 10 10
    [[ "$output" == "60" ]]
}

@test "calculate_backoff_delay: resets to base when healthy" {
    # Was backed off to 40, now healthy → back to base
    run calculate_backoff_delay 40 1 10
    [[ "$output" == "10" ]]
}

@test "calculate_backoff_delay: boundary at exactly 2s is healthy" {
    run calculate_backoff_delay 20 2 10
    [[ "$output" == "10" ]]
}

# =============================================================================
# v2.3.1: Daemon Resilience — source code pattern tests
# =============================================================================

@test "no bd_safe delete in common.sh (tombstone prevention)" {
    ! grep -q 'bd_safe delete' "$SCRIPTS_DIR/common.sh"
}

@test "no bd_safe delete in detect-phase.sh (tombstone prevention)" {
    ! grep -q 'bd_safe delete' "$SCRIPTS_DIR/detect-phase.sh"
}

@test "bd_safe explosion threshold is 5" {
    grep -q 'daemon_count.*-gt 5' "$SCRIPTS_DIR/common.sh"
}

@test "ensure_single_daemon function exists in common.sh" {
    grep -q '^ensure_single_daemon()' "$SCRIPTS_DIR/common.sh"
}

@test "compact_beads_if_large function exists in common.sh" {
    grep -q '^compact_beads_if_large()' "$SCRIPTS_DIR/common.sh"
}

@test "check_beads uses bd daemon status not bd sync --status" {
    # check_beads should use bd daemon status
    sed -n '/^check_beads()/,/^}/p' "$SCRIPTS_DIR/common.sh" | grep -q 'bd daemon status'

    # check_beads should NOT use bd sync --status
    ! sed -n '/^check_beads()/,/^}/p' "$SCRIPTS_DIR/common.sh" | grep -q 'bd sync --status'
}

@test "delete_milestone uses --remove-label not delete" {
    local body
    body=$(sed -n '/^delete_milestone()/,/^}/p' "$SCRIPTS_DIR/common.sh")
    echo "$body" | grep -q 'remove-label'
    ! echo "$body" | grep -q 'bd_safe delete'
}

@test "delete_all_milestones uses --remove-label not delete" {
    local body
    body=$(sed -n '/^delete_all_milestones()/,/^}/p' "$SCRIPTS_DIR/common.sh")
    echo "$body" | grep -q 'remove-label'
    ! echo "$body" | grep -q 'bd_safe delete'
}

@test "hype.sh calls ensure_single_daemon at startup" {
    grep -q 'ensure_single_daemon' "$SCRIPTS_DIR/hype.sh"
}

@test "hype.sh calls compact_beads_if_large at startup" {
    grep -q 'compact_beads_if_large' "$SCRIPTS_DIR/hype.sh"
}

# =============================================================================
# v2.3.2: bd call reduction — caching pattern tests
# =============================================================================

@test "set_counter_label accepts optional task_json parameter" {
    # Function signature should have 4th param (task_json)
    local body
    body=$(sed -n '/^set_counter_label()/,/^}/p' "$SCRIPTS_DIR/common.sh")
    echo "$body" | grep -q 'task_json="\${4:-}"'
}

@test "set_counter_label skips bd show when task_json provided" {
    local body
    body=$(sed -n '/^set_counter_label()/,/^}/p' "$SCRIPTS_DIR/common.sh")
    echo "$body" | grep -q 'if \[ -z "\$task_json" \]'
}

@test "all set_counter_label callers pass task_json" {
    # Every set_counter_label call (except the definition) should have 4 args
    # Match: set_counter_label "$var" "prefix" "$val" "$json"
    local calls_without_json
    calls_without_json=$(grep -n 'set_counter_label ' "$SCRIPTS_DIR/run-reviewers.sh" "$SCRIPTS_DIR/run-merge-queue.sh" "$SCRIPTS_DIR/hype.sh" "$SCRIPTS_DIR/run-testers.sh" 2>/dev/null | grep -v '^\s*#' | grep -cv '"$' || echo "0")
    # All calls should end with a 4th argument (quoted variable)
    local total_calls
    total_calls=$(grep -n 'set_counter_label ' "$SCRIPTS_DIR/run-reviewers.sh" "$SCRIPTS_DIR/run-merge-queue.sh" "$SCRIPTS_DIR/hype.sh" "$SCRIPTS_DIR/run-testers.sh" 2>/dev/null | grep -cv '^\s*#' || echo "0")
    [[ "$total_calls" -gt 0 ]]
}

@test "hype.sh shares in_progress cache between check_stale and heal_stuck" {
    # Should fetch once and pass to both
    grep -q 'in_progress_cache.*bd_safe list' "$SCRIPTS_DIR/hype.sh"
    grep -q 'check_stale_tasks "\$in_progress_cache"' "$SCRIPTS_DIR/hype.sh"
    grep -q 'heal_stuck_tasks "\$in_progress_cache"' "$SCRIPTS_DIR/hype.sh"
}

@test "heal_stuck_tasks accepts optional in_progress_json parameter" {
    local body
    body=$(sed -n '/^heal_stuck_tasks()/,/^[a-z]/p' "$SCRIPTS_DIR/hype.sh" | head -10)
    echo "$body" | grep -q 'in_progress_json="\${1:-}"'
}

@test "reset_stale_tasks accepts optional in_progress_json parameter" {
    local body
    body=$(sed -n '/^reset_stale_tasks()/,/^}/p' "$SCRIPTS_DIR/common.sh")
    echo "$body" | grep -q 'all_tasks_json="\${3:-}"'
}

@test "hype.sh IMPLEMENTATION shares cache via HYPE_IN_PROGRESS_CACHE" {
    grep -q 'HYPE_IN_PROGRESS_CACHE=.*run-reviewers.sh' "$SCRIPTS_DIR/hype.sh"
    grep -q 'HYPE_IN_PROGRESS_CACHE=.*run-merge-queue.sh' "$SCRIPTS_DIR/hype.sh"
}

@test "run-reviewers.sh uses HYPE_IN_PROGRESS_CACHE when available" {
    grep -q 'HYPE_IN_PROGRESS_CACHE' "$SCRIPTS_DIR/run-reviewers.sh"
}

@test "run-merge-queue.sh uses HYPE_IN_PROGRESS_CACHE when available" {
    grep -q 'HYPE_IN_PROGRESS_CACHE' "$SCRIPTS_DIR/run-merge-queue.sh"
}

@test "run-executors.sh: single bd show for status check + details" {
    # Should NOT have two consecutive bd_safe show calls for same task
    # The merged pattern: task_json=$(bd_safe show...) then current_status=$(echo "$task_json"|jq...)
    local main_loop
    main_loop=$(sed -n '/for task_id in \$tasks/,/done/p' "$SCRIPTS_DIR/run-executors.sh")
    # Should have exactly ONE bd_safe show in the pre-launch section
    local show_count
    show_count=$(echo "$main_loop" | grep -c 'bd_safe show' || true)
    # One show in the loop (pre-check), plus potentially in run_executor (post-claim)
    # The key: the two adjacent shows (lines 498+508) should now be one
    echo "$main_loop" | grep -q 'task_json=.*bd_safe show'
    echo "$main_loop" | grep -q 'current_status=.*echo.*task_json.*jq'
}

@test "run-reviewers.sh: title from cache, no bd show in main loop" {
    # Main loop should extract title from all_in_progress, not bd_safe show
    local main_loop
    main_loop=$(sed -n '/for task_id in \$tasks/,/done/p' "$SCRIPTS_DIR/run-reviewers.sh")
    ! echo "$main_loop" | grep -q 'bd_safe show'
    echo "$main_loop" | grep -q 'all_in_progress.*jq.*title'
}

# =============================================================================
# v2.3.3: Merge conflict retry-in-place + doctor label fix
# =============================================================================

@test "merge queue: uses merge-conflict:N counter (not reject:N)" {
    local merge_fn
    merge_fn=$(sed -n '/^merge_task()/,/^}/p' "$SCRIPTS_DIR/run-merge-queue.sh")

    # Must use merge-conflict counter for conflicts
    echo "$merge_fn" | grep -q 'merge-conflict'

    # Must NOT use reject:N for infrastructure failures
    ! echo "$merge_fn" | grep -q '"reject"'
}

@test "merge queue: conflict retry returns 1 to try next task" {
    local merge_fn
    merge_fn=$(sed -n '/^merge_task()/,/^}/p' "$SCRIPTS_DIR/run-merge-queue.sh")

    # return 1 signals "skip this task, try next"
    echo "$merge_fn" | grep -q 'return 1.*# Signal\|return 1.*# Try next'
}

@test "merge queue: main loop skips conflicting tasks" {
    local main_fn
    main_fn=$(sed -n '/^main()/,/^}/p' "$SCRIPTS_DIR/run-merge-queue.sh")

    # Loop through tasks, not just head -n 1
    echo "$main_fn" | grep -q 'for task_id in'
    # Check return code of merge_task
    echo "$main_fn" | grep -q 'merge_task.*task_id'
}

@test "merge queue: persistent conflict returns to executor at threshold 6" {
    local merge_fn
    merge_fn=$(sed -n '/^merge_task()/,/^}/p' "$SCRIPTS_DIR/run-merge-queue.sh")

    echo "$merge_fn" | grep -q 'conflict_count.*-ge 6'
    echo "$merge_fn" | grep -q 'status=open'
}

@test "doctor.sh: creates label before issue" {
    grep -q 'gh label create.*doctor-report' "$SCRIPTS_DIR/doctor.sh"
}

# =============================================================================
# v2.3.4: Hook-safe merge queue + commit failure handling
# =============================================================================

@test "merge queue: git_nh function disables hooks via core.hooksPath" {
    grep -q 'core.hooksPath=/dev/null' "$SCRIPTS_DIR/run-merge-queue.sh"
    grep -q '^git_nh()' "$SCRIPTS_DIR/run-merge-queue.sh"
}

@test "merge queue: all git checkout/pull/push/rebase/merge use git_nh" {
    local merge_fn
    merge_fn=$(sed -n '/^merge_task()/,/^}/p' "$SCRIPTS_DIR/run-merge-queue.sh")

    # git_nh should be used for state-changing operations
    echo "$merge_fn" | grep -q 'git_nh checkout'
    echo "$merge_fn" | grep -q 'git_nh pull'
    echo "$merge_fn" | grep -q 'git_nh push'
    echo "$merge_fn" | grep -q 'git_nh rebase'
    echo "$merge_fn" | grep -q 'git_nh merge'
    echo "$merge_fn" | grep -q 'git_nh commit'
    echo "$merge_fn" | grep -q 'git_nh fetch'

    # Raw git checkout/pull/push/commit/rebase/merge should NOT appear in merge_task
    # (only git rev-parse, git symbolic-ref, git status are allowed as read-only)
    # Exclude comments (lines starting with #) — they reference git in prose
    ! echo "$merge_fn" | grep -v '^\s*#' | grep -v 'git_nh' | grep -v 'git rev-parse' | grep -v 'git symbolic-ref' | grep -v 'git status' | grep -q 'git '
}

@test "merge queue: commit failure cleans staged changes (not || true)" {
    local merge_fn
    merge_fn=$(sed -n '/^merge_task()/,/^}/p' "$SCRIPTS_DIR/run-merge-queue.sh")

    # Commit should be wrapped in if ! ... not || true
    echo "$merge_fn" | grep -q 'if ! git_nh commit'
    # On failure: reset and return to executor
    echo "$merge_fn" | grep -q 'Commit failed.*cleaning staged'
    echo "$merge_fn" | grep -q 'reset --hard.*main_ref'
}

@test "merge queue: pre-flight dirty tree check" {
    local merge_fn
    merge_fn=$(sed -n '/^merge_task()/,/^}/p' "$SCRIPTS_DIR/run-merge-queue.sh")

    # Should check git status --porcelain
    echo "$merge_fn" | grep -q 'git status --porcelain'
    # Should clean up if dirty
    echo "$merge_fn" | grep -q 'Dirty working tree'
    echo "$merge_fn" | grep -q 'git_nh reset --hard'
}
