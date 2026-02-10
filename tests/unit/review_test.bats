#!/usr/bin/env bats
# tests/unit/review_test.bats
# Unit tests for v2.1.8 review fixes:
# - Soft secret scanner (SECRETS_WARNING instead of SECRETS_DETECTED)
# - Circuit breaker (reformulated + same reason → user-escalation)
# - Reset reject:N after troubleshooter reformulation

load '../helpers/setup'
load '../helpers/mock_bd'

# =============================================================================
# Soft secret scanner
# =============================================================================

@test "preflight: returns SECRETS_WARNING not SECRETS_DETECTED" {
    # Verify the source code no longer returns SECRETS_DETECTED
    local senior_exec="$SCRIPTS_DIR/run-senior-executor.sh"

    # SECRETS_WARNING should be present
    grep -q 'echo "SECRETS_WARNING"' "$senior_exec"

    # SECRETS_DETECTED should NOT be returned anywhere
    ! grep -q 'echo "SECRETS_DETECTED"' "$senior_exec"
}

@test "preflight: SECRETS_WARNING case does not return (falls through)" {
    local senior_exec="$SCRIPTS_DIR/run-senior-executor.sh"

    # The SECRETS_WARNING case should NOT have 'return 0' statement
    local block
    block=$(sed -n '/SECRETS_WARNING)/,/;;/p' "$senior_exec")

    # Should NOT contain 'return 0' (actual return statement, not comments)
    ! echo "$block" | grep -qE '^\s*return'
}

@test "preflight: SECRETS_WARNING adds secrets-warning label" {
    local senior_exec="$SCRIPTS_DIR/run-senior-executor.sh"

    # Should add secrets-warning label
    grep -q 'add-label=secrets-warning' "$senior_exec"
}

@test "preflight: SECRETS_WARNING re-fetches task_json" {
    local senior_exec="$SCRIPTS_DIR/run-senior-executor.sh"

    # After adding label, should re-fetch task_json for build_review_context
    local block
    block=$(sed -n '/SECRETS_WARNING)/,/;;/p' "$senior_exec")
    echo "$block" | grep -q 'task_json=.*bd_safe show'
}

@test "build_review_context: injects warning when secrets-warning label present" {
    local senior_exec="$SCRIPTS_DIR/run-senior-executor.sh"

    # Should check for secrets-warning label
    grep -q 'secrets-warning' "$senior_exec"

    # Should inject SECURITY WARNING section
    grep -q 'SECURITY WARNING' "$senior_exec"
}

# =============================================================================
# Circuit breaker
# =============================================================================

@test "circuit breaker: detects reformulated + same rejection reason" {
    mock_bd_init "empty"

    # Simulate task that was reformulated and has last-reject:NO_BRANCH
    echo '[{
        "id": "cb-task",
        "title": "Failing task",
        "status": "in_progress",
        "labels": ["needs-review", "reformulated", "last-reject:NO_BRANCH", "reject:3"],
        "notes": "Previous failures"
    }]' > "$MOCK_BD_STATE_DIR/tasks.json"

    local task_json
    task_json=$(bd show cb-task --json)

    # Extract check logic (same as in handle_preflight_rejection)
    local has_reformulated last_reject_reason rejection_type
    has_reformulated=$(echo "$task_json" | jq -r '[.[0].labels[]? | select(. == "reformulated")] | length')
    last_reject_reason=$(echo "$task_json" | jq -r '.[0].labels[]? | select(startswith("last-reject:")) | split(":")[1]' | head -1)
    rejection_type="NO_BRANCH"

    # Should trigger circuit breaker
    [[ "$has_reformulated" != "0" ]]
    [[ "$last_reject_reason" == "$rejection_type" ]]

    mock_bd_cleanup
}

@test "circuit breaker: does NOT trigger for different rejection reason" {
    mock_bd_init "empty"

    echo '[{
        "id": "cb-task",
        "title": "Failing task",
        "status": "in_progress",
        "labels": ["needs-review", "reformulated", "last-reject:NO_BRANCH", "reject:3"],
        "notes": "Previous failures"
    }]' > "$MOCK_BD_STATE_DIR/tasks.json"

    local task_json
    task_json=$(bd show cb-task --json)

    local has_reformulated last_reject_reason rejection_type
    has_reformulated=$(echo "$task_json" | jq -r '[.[0].labels[]? | select(. == "reformulated")] | length')
    last_reject_reason=$(echo "$task_json" | jq -r '.[0].labels[]? | select(startswith("last-reject:")) | split(":")[1]' | head -1)
    rejection_type="NO_COMMITS"  # Different reason!

    # Should NOT trigger circuit breaker (different reason)
    [[ "$has_reformulated" != "0" ]]
    [[ "$last_reject_reason" != "$rejection_type" ]]

    mock_bd_cleanup
}

@test "circuit breaker: does NOT trigger without reformulated label" {
    mock_bd_init "empty"

    echo '[{
        "id": "cb-task",
        "title": "Failing task",
        "status": "in_progress",
        "labels": ["needs-review", "last-reject:NO_BRANCH", "reject:3"],
        "notes": "Previous failures"
    }]' > "$MOCK_BD_STATE_DIR/tasks.json"

    local task_json
    task_json=$(bd show cb-task --json)

    local has_reformulated
    has_reformulated=$(echo "$task_json" | jq -r '[.[0].labels[]? | select(. == "reformulated")] | length')

    # Should NOT trigger (no reformulated label)
    [[ "$has_reformulated" == "0" ]]

    mock_bd_cleanup
}

@test "circuit breaker: source code routes to user-escalation" {
    local senior_exec="$SCRIPTS_DIR/run-senior-executor.sh"

    # Should contain circuit breaker logic
    grep -q 'CIRCUIT BREAKER' "$senior_exec"

    # Should add user-escalation label
    grep -q 'user-escalation' "$senior_exec"
}

# =============================================================================
# Reset reject:N after reformulation
# =============================================================================

@test "reset reject:N: hype.sh resets counter after reformulation" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Should check for reformulated label after troubleshooter
    grep -q 'reformulated' "$hype_sh"

    # Should call set_counter_label to reset
    grep -q 'set_counter_label.*reject.*0' "$hype_sh"
}

@test "reset reject:N: only resets for open+reformulated tasks" {
    mock_bd_init "empty"

    # Task that was reformulated (open + reformulated label)
    echo '[{
        "id": "reset-task",
        "title": "Reformulated task",
        "status": "open",
        "labels": ["reformulated", "reject:4"],
        "notes": "Troubleshooter reformulated"
    }]' > "$MOCK_BD_STATE_DIR/tasks.json"

    local task_json updated_status has_reformulated
    task_json=$(bd show reset-task --json)
    updated_status=$(echo "$task_json" | jq -r '.[0].status')
    has_reformulated=$(echo "$task_json" | jq -r '[.[0].labels[]? | select(. == "reformulated")] | length')

    # Should match reset condition
    [[ "$updated_status" == "open" ]]
    [[ "$has_reformulated" != "0" ]]

    mock_bd_cleanup
}

@test "reset reject:N: does NOT reset for closed tasks" {
    mock_bd_init "empty"

    # Task that was closed by troubleshooter (scope reduction)
    echo '[{
        "id": "closed-task",
        "title": "Removed task",
        "status": "closed",
        "labels": ["reject:4"],
        "notes": "Troubleshooter: removed from scope"
    }]' > "$MOCK_BD_STATE_DIR/tasks.json"

    local task_json updated_status
    task_json=$(bd show closed-task --json)
    updated_status=$(echo "$task_json" | jq -r '.[0].status')

    # Should NOT match reset condition
    [[ "$updated_status" != "open" ]]

    mock_bd_cleanup
}

@test "reset reject:N: does NOT reset without reformulated label" {
    mock_bd_init "empty"

    # Task reopened by troubleshooter but NOT reformulated (e.g. user-escalation)
    echo '[{
        "id": "escalated-task",
        "title": "Escalated task",
        "status": "open",
        "labels": ["user-escalation", "reject:4"],
        "notes": "Troubleshooter: requires user input"
    }]' > "$MOCK_BD_STATE_DIR/tasks.json"

    local task_json has_reformulated
    task_json=$(bd show escalated-task --json)
    has_reformulated=$(echo "$task_json" | jq -r '[.[0].labels[]? | select(. == "reformulated")] | length')

    # Should NOT match (no reformulated label)
    [[ "$has_reformulated" == "0" ]]

    mock_bd_cleanup
}
