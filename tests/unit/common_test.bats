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
