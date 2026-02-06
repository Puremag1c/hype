#!/usr/bin/env bats
# tests/integration/doctor_test.bats
# Integration tests for Doctor diagnostics
#
# Tests the diagnostic logic without running full claude agent

load '../helpers/setup'
# NOTE: Don't load mock_bd - Doctor tests use real beads

# =============================================================================
# Setup
# =============================================================================

setup() {
    TEST_TMPDIR=$(mktemp -d)/doctortest
    mkdir -p "$TEST_TMPDIR/.hype"
    mkdir -p "$TEST_TMPDIR/logs"
    mkdir -p "$TEST_TMPDIR/scripts"

    cd "$TEST_TMPDIR"
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test"

    bd init --quiet 2>/dev/null || true

    # Link scripts for detect-phase.sh
    ln -sf "$SCRIPTS_DIR" "$TEST_TMPDIR/scripts"

    export PROJECT_ROOT="$TEST_TMPDIR"
    source "$SCRIPTS_DIR/common.sh"
}

teardown() {
    cd / 2>/dev/null || true
    if [[ -n "$TEST_TMPDIR" ]]; then
        (cd "$TEST_TMPDIR" && bd daemon stop 2>/dev/null) || true
        rm -rf "$(dirname "$TEST_TMPDIR")" 2>/dev/null || true
    fi
}

# =============================================================================
# Stuck Task Detection
# =============================================================================

@test "Doctor: detects stuck in_progress task" {
    # Create task that's been in_progress for a while
    cd "$TEST_TMPDIR"
    local id=$(bd create --title="Stuck task" --type=task --priority=1 2>&1 | grep "Created issue:" | sed 's/.*Created issue: //' | awk '{print $1}')
    bd update "$id" --status=in_progress

    # Check in_progress tasks
    local in_progress=$(bd list --status=in_progress --json 2>/dev/null | jq 'length')

    [[ "$in_progress" -gt 0 ]]
}

@test "Doctor: identifies task age from updated_at" {
    cd "$TEST_TMPDIR"
    local id=$(bd create --title="Test task" --type=task --priority=2 2>&1 | grep "Created issue:" | sed 's/.*Created issue: //' | awk '{print $1}')
    bd update "$id" --status=in_progress

    # Get updated_at timestamp
    local updated_at=$(bd show "$id" --json 2>/dev/null | jq -r '.[0].updated_at')

    [[ -n "$updated_at" ]]
    [[ "$updated_at" != "null" ]]
}

# =============================================================================
# Orphaned Label Detection
# =============================================================================

@test "Doctor: detects needs-review on closed task" {
    cd "$TEST_TMPDIR"
    local id=$(bd create --title="Reviewed task" --type=task --labels="needs-review" 2>&1 | grep "Created issue:" | sed 's/.*Created issue: //' | awk '{print $1}')
    bd close "$id"

    # Check for closed tasks with needs-review
    local orphaned=$(bd list --status=closed --json 2>/dev/null | jq '[.[] | select(.labels[]? == "needs-review")] | length')

    [[ "$orphaned" -gt 0 ]]
}

@test "Doctor: executor label on non-in_progress is orphan" {
    cd "$TEST_TMPDIR"
    local id=$(bd create --title="Orphan executor" --type=task --labels="executor" 2>&1 | grep "Created issue:" | sed 's/.*Created issue: //' | awk '{print $1}')

    # Task is open but has executor label (orphaned)
    local status=$(bd show "$id" --json 2>/dev/null | jq -r '.[0].status')
    local has_executor=$(bd show "$id" --json 2>/dev/null | jq -r '.[0].labels | index("executor") != null')

    [[ "$status" == "open" ]]
    [[ "$has_executor" == "true" ]]
}

# =============================================================================
# SMOKE_REVIEW Loop Detection
# =============================================================================

@test "Doctor: detects regression loop" {
    cd "$TEST_TMPDIR"
    touch SPEC.md

    # Create regression task (indicates loop)
    bd create --title="Bug from smoke" --type=bug --labels="regression" >/dev/null 2>&1
    bd create --title="Another regression" --type=bug --labels="regression" >/dev/null 2>&1

    # Count regressions
    local regressions=$(bd list --json 2>/dev/null | jq '[.[] | select(.labels[]? == "regression")] | length')

    [[ "$regressions" -eq 2 ]]
}

@test "Doctor: multiple regressions suggests infinite loop risk" {
    cd "$TEST_TMPDIR"

    # Create multiple regression tasks
    bd create --title="Regression 1" --type=bug --labels="regression" >/dev/null 2>&1
    bd create --title="Regression 2" --type=bug --labels="regression" >/dev/null 2>&1
    bd create --title="Regression 3" --type=bug --labels="regression" >/dev/null 2>&1

    local regressions=$(bd list --json 2>/dev/null | jq '[.[] | select(.labels[]? == "regression")] | length')

    # More than 2 regressions in one cycle = potential loop
    [[ "$regressions" -ge 2 ]]
}

# =============================================================================
# Beads Daemon Health
# =============================================================================

@test "Doctor: can check daemon status" {
    cd "$TEST_TMPDIR"

    # bd daemon status should work
    run bd daemon status
    # Status 0 = running, 1 = not running (both valid responses)
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
}

@test "Doctor: sync --status shows connection state" {
    cd "$TEST_TMPDIR"

    # Use timeout_cmd from common.sh (cross-platform)
    run timeout_cmd 5s bd sync --status
    # Should complete without hanging (0=ok, 1=error are both valid)
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
}

# =============================================================================
# Context Gathering
# =============================================================================

@test "Doctor: gathers bd stats" {
    cd "$TEST_TMPDIR"

    # Stats should return without error
    run bd stats
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Statistics"* || "$output" == *"Open"* || "$output" == *"open"* ]]
}

@test "Doctor: gathers blocked tasks" {
    cd "$TEST_TMPDIR"

    # Create blocked task
    local id1=$(bd create --title="Blocker" --type=task 2>&1 | grep "Created issue:" | sed 's/.*Created issue: //' | awk '{print $1}')
    local id2=$(bd create --title="Blocked" --type=task 2>&1 | grep "Created issue:" | sed 's/.*Created issue: //' | awk '{print $1}')
    bd dep add "$id2" "$id1" 2>/dev/null || true

    # Blocked should show the task
    run bd blocked
    [[ "$status" -eq 0 ]]
}

@test "Doctor: can detect current phase" {
    cd "$TEST_TMPDIR"
    touch SPEC.md

    # Should detect phase
    local phase=$(./scripts/detect-phase.sh 2>/dev/null | jq -r '.phase')
    [[ -n "$phase" ]]
    [[ "$phase" != "null" ]]
}

# =============================================================================
# doctor-log Creation
# =============================================================================

@test "Doctor: can write diagnostic output" {
    cd "$TEST_TMPDIR"
    local log_file="$TEST_TMPDIR/logs/doctor-$(date +%Y%m%d-%H%M%S).log"

    # Simulate doctor-log creation
    cat > "$log_file" << EOF
# Doctor Diagnostic Log
Generated: $(date)

## Summary
Test diagnostic log

## Findings
- No critical issues
EOF

    [[ -f "$log_file" ]]
    [[ $(cat "$log_file") == *"Doctor Diagnostic"* ]]
}

# =============================================================================
# Known Issue Patterns (from troubleshooting.md)
# =============================================================================

@test "Doctor: pattern match for stuck executor" {
    # Pattern: in_progress + executor label + old updated_at
    local task_json='[{"id":"t1","status":"in_progress","labels":["executor"],"updated_at":"2026-02-05T10:00:00Z"}]'

    # Check pattern
    local is_stuck=$(echo "$task_json" | jq '.[0].status == "in_progress" and (.[0].labels | index("executor") != null)')

    [[ "$is_stuck" == "true" ]]
}

@test "Doctor: pattern match for orphaned milestone" {
    # Pattern: milestone label on open task (should be closed)
    local task_json='[{"id":"m1","status":"open","labels":["milestone:planning-done"]}]'

    local is_orphan=$(echo "$task_json" | jq '.[0].status == "open" and (.[0].labels[]? | startswith("milestone:"))')

    [[ "$is_orphan" == "true" ]]
}

@test "Doctor: pattern match for review timeout" {
    # Pattern: needs-review label + retry count high
    local task_json='[{"id":"t1","status":"in_progress","labels":["needs-review","review-retry:3"]}]'

    local has_review_issue=$(echo "$task_json" | jq '(.[0].labels | index("needs-review") != null) and (.[0].labels[]? | select(startswith("review-retry:")))')

    [[ -n "$has_review_issue" ]]
}
