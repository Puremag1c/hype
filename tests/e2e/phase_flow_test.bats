#!/usr/bin/env bats
# tests/e2e/phase_flow_test.bats
# End-to-end tests for HYPE phase transitions
#
# These tests verify the complete flow: INIT → DONE

load '../helpers/setup'

# E2E test environment
E2E_TMPDIR=""
DETECT_PHASE="$SCRIPTS_DIR/detect-phase.sh"

# =============================================================================
# Setup / Teardown
# =============================================================================

setup() {
    E2E_TMPDIR=$(mktemp -d)/hype-e2e
    mkdir -p "$E2E_TMPDIR"

    cd "$E2E_TMPDIR"

    # Initialize git
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test"
    touch README.md
    git add README.md
    git commit -m "Initial" --quiet

    # Initialize beads
    bd init --quiet 2>/dev/null || true

    # Create .hype structure
    mkdir -p .hype
    mkdir -p logs
    mkdir -p .claude/agents

    # Create config
    cat > .hype/config.sh << 'EOF'
MAX_PARALLEL_EXECUTORS=2
RETRY_LIMIT=3
ITERATION_DELAY=5
TASK_STALE_TIMEOUT=600
LOG_TOKENS=false
DEBUG=false
TASK_TIMEOUT="10m"
ALLOWED_MODELS="opus,sonnet,haiku"
EOF

    export PROJECT_ROOT="$E2E_TMPDIR"
}

teardown() {
    cd / 2>/dev/null || true
    if [[ -n "$E2E_TMPDIR" ]]; then
        (cd "$E2E_TMPDIR" && bd daemon stop 2>/dev/null) || true
        rm -rf "$(dirname "$E2E_TMPDIR")" 2>/dev/null || true
    fi
}

# Helper: get current phase
get_phase() {
    cd "$E2E_TMPDIR"
    "$DETECT_PHASE" | jq -r '.phase'
}

# Helper: create milestone
create_milestone() {
    local label="$1"
    local title="$2"
    cd "$E2E_TMPDIR"
    local id=$(bd create --title="$title" --type=task --labels="$label" 2>&1 | grep "Created issue:" | sed 's/.*Created issue: //' | awk '{print $1}')
    if [[ -n "$id" ]]; then
        bd close "$id" 2>/dev/null || true
    fi
}

# Helper: create and close task
create_closed_task() {
    local title="$1"
    cd "$E2E_TMPDIR"
    local id=$(bd create --title="$title" --type=task --priority=2 2>&1 | grep "Created issue:" | sed 's/.*Created issue: //' | awk '{print $1}')
    if [[ -n "$id" ]]; then
        bd close "$id" 2>/dev/null || true
    fi
    echo "$id"
}

# =============================================================================
# Phase Transition Tests: Happy Path
# =============================================================================

@test "E2E: INIT → PLANNING (create SPEC)" {
    # Start in INIT
    local phase1=$(get_phase)
    [[ "$phase1" == "INIT" ]]

    # Create SPEC.md (Tech Writer's output)
    cat > "$E2E_TMPDIR/SPEC.md" << 'EOF'
# Test Specification
## Must Have
- Feature 1
EOF

    # Should transition to PLANNING
    local phase2=$(get_phase)
    [[ "$phase2" == "PLANNING" ]]
}

@test "E2E: PLANNING → HELPERS (create milestone)" {
    touch "$E2E_TMPDIR/SPEC.md"
    local phase1=$(get_phase)
    [[ "$phase1" == "PLANNING" ]]

    # Architect creates planning-done milestone
    create_milestone "milestone:planning-done" "Planning complete"

    # Should transition to HELPERS
    local phase2=$(get_phase)
    [[ "$phase2" == "HELPERS" ]]
}

@test "E2E: HELPERS → PLAN_REVIEW (analysts complete)" {
    touch "$E2E_TMPDIR/SPEC.md"
    create_milestone "milestone:planning-done" "Planning"

    local phase1=$(get_phase)
    [[ "$phase1" == "HELPERS" ]]

    # Analysts complete
    create_milestone "milestone:analysts-done" "Analysts"

    # Should transition to PLAN_REVIEW
    local phase2=$(get_phase)
    [[ "$phase2" == "PLAN_REVIEW" ]]
}

@test "E2E: PLAN_REVIEW → IMPLEMENTATION (review done)" {
    touch "$E2E_TMPDIR/SPEC.md"
    create_milestone "milestone:planning-done" "Planning"
    create_milestone "milestone:analysts-done" "Analysts"

    local phase1=$(get_phase)
    [[ "$phase1" == "PLAN_REVIEW" ]]

    # Architect reviews plan
    create_milestone "milestone:plan-reviewed" "Reviewed"

    # Need open task to go to IMPLEMENTATION (not SMOKE_TEST)
    cd "$E2E_TMPDIR"
    bd create --title="Implement feature" --type=task --priority=1

    # Should transition to IMPLEMENTATION
    local phase2=$(get_phase)
    [[ "$phase2" == "IMPLEMENTATION" ]]
}

@test "E2E: IMPLEMENTATION → SMOKE_TEST (all tasks closed)" {
    touch "$E2E_TMPDIR/SPEC.md"
    create_milestone "milestone:planning-done" "Planning"
    create_milestone "milestone:analysts-done" "Analysts"
    create_milestone "milestone:plan-reviewed" "Reviewed"

    # Create task and close it
    create_closed_task "Implement feature"

    # Should transition to SMOKE_TEST
    local phase=$(get_phase)
    [[ "$phase" == "SMOKE_TEST" ]]
}

@test "E2E: SMOKE_TEST → FINAL_REVIEW (smoke done)" {
    touch "$E2E_TMPDIR/SPEC.md"
    create_milestone "milestone:planning-done" "Planning"
    create_milestone "milestone:analysts-done" "Analysts"
    create_milestone "milestone:plan-reviewed" "Reviewed"
    create_closed_task "Task"
    create_milestone "milestone:smoke-test-done" "Smoke"

    # Should transition to FINAL_REVIEW
    local phase=$(get_phase)
    [[ "$phase" == "FINAL_REVIEW" ]]
}

@test "E2E: FINAL_REVIEW → DONE (project complete)" {
    touch "$E2E_TMPDIR/SPEC.md"
    create_milestone "milestone:planning-done" "Planning"
    create_milestone "milestone:analysts-done" "Analysts"
    create_milestone "milestone:plan-reviewed" "Reviewed"
    create_closed_task "Task"
    create_milestone "milestone:smoke-test-done" "Smoke"
    create_milestone "milestone:project-done" "Done"

    # Should transition to DONE
    local phase=$(get_phase)
    [[ "$phase" == "DONE" ]]
}

# =============================================================================
# Phase Transition Tests: Edge Cases
# =============================================================================

@test "E2E: SMOKE_REVIEW triggered by regression" {
    touch "$E2E_TMPDIR/SPEC.md"
    create_milestone "milestone:planning-done" "Planning"
    create_milestone "milestone:analysts-done" "Analysts"
    create_milestone "milestone:plan-reviewed" "Reviewed"

    # Create regression task (found in smoke test)
    cd "$E2E_TMPDIR"
    bd create --title="Regression bug" --type=bug --priority=0 --labels="regression"

    # Should trigger SMOKE_REVIEW
    local phase=$(get_phase)
    [[ "$phase" == "SMOKE_REVIEW" ]]
}

@test "E2E: force-phase overrides normal detection" {
    touch "$E2E_TMPDIR/SPEC.md"

    # Normally would be PLANNING
    local phase1=$(get_phase)
    [[ "$phase1" == "PLANNING" ]]

    # Force IMPLEMENTATION
    echo "IMPLEMENTATION" > "$E2E_TMPDIR/.hype/force-phase"

    # Should be IMPLEMENTATION now
    local phase2=$(get_phase)
    [[ "$phase2" == "IMPLEMENTATION" ]]

    # force-phase file should be deleted
    [[ ! -f "$E2E_TMPDIR/.hype/force-phase" ]]
}

@test "E2E: in_progress task keeps IMPLEMENTATION" {
    touch "$E2E_TMPDIR/SPEC.md"
    create_milestone "milestone:planning-done" "Planning"
    create_milestone "milestone:analysts-done" "Analysts"
    create_milestone "milestone:plan-reviewed" "Reviewed"

    # Create and start task
    cd "$E2E_TMPDIR"
    local id=$(bd create --title="Active task" --type=task --priority=1 2>&1 | grep "Created issue:" | sed 's/.*Created issue: //' | awk '{print $1}')
    bd update "$id" --status=in_progress

    # Should stay in IMPLEMENTATION
    local phase=$(get_phase)
    [[ "$phase" == "IMPLEMENTATION" ]]
}

# =============================================================================
# Stats Verification
# =============================================================================

@test "E2E: progress_pct increases as tasks complete" {
    touch "$E2E_TMPDIR/SPEC.md"
    create_milestone "milestone:planning-done" "Planning"
    create_milestone "milestone:analysts-done" "Analysts"
    create_milestone "milestone:plan-reviewed" "Reviewed"

    # Create 4 tasks
    cd "$E2E_TMPDIR"
    for i in 1 2 3 4; do
        bd create --title="Task $i" --type=task --priority=2 >/dev/null 2>&1
    done

    # Get initial progress (should be low)
    local json1=$("$DETECT_PHASE")
    local progress1=$(echo "$json1" | jq '.progress_pct')

    # Close 2 tasks
    local ids=$(bd list --json 2>/dev/null | jq -r '.[] | select(.type == "task") | select(.title | startswith("Task")) | .id' | head -2)
    for id in $ids; do
        bd close "$id" >/dev/null 2>&1
    done

    # Get updated progress (should be higher)
    local json2=$("$DETECT_PHASE")
    local progress2=$(echo "$json2" | jq '.progress_pct')

    [[ "$progress2" -ge "$progress1" ]]
}

# =============================================================================
# v2.2: Review Pipeline Stats
# =============================================================================

@test "E2E: reviewing count in detect-phase output" {
    touch "$E2E_TMPDIR/SPEC.md"
    create_milestone "milestone:planning-done" "P"
    create_milestone "milestone:analysts-done" "A"
    create_milestone "milestone:plan-reviewed" "R"

    # Create task in reviewing state
    cd "$E2E_TMPDIR"
    local id=$(bd create --title="Review me" --type=task --priority=1 2>&1 | grep "Created issue:" | sed 's/.*Created issue: //' | awk '{print $1}')
    bd update "$id" --status=in_progress --add-label=reviewing

    local json=$("$DETECT_PHASE")
    local reviewing=$(echo "$json" | jq '.stats.reviewing')

    [[ "$reviewing" -ge 1 ]]
}

@test "E2E: approved count in detect-phase output" {
    touch "$E2E_TMPDIR/SPEC.md"
    create_milestone "milestone:planning-done" "P"
    create_milestone "milestone:analysts-done" "A"
    create_milestone "milestone:plan-reviewed" "R"

    # Create task in approved state
    cd "$E2E_TMPDIR"
    local id=$(bd create --title="Approved task" --type=task --priority=1 2>&1 | grep "Created issue:" | sed 's/.*Created issue: //' | awk '{print $1}')
    bd update "$id" --status=in_progress --add-label=approved

    local json=$("$DETECT_PHASE")
    local approved=$(echo "$json" | jq '.stats.approved')

    [[ "$approved" -ge 1 ]]
}

@test "E2E: reviewing task keeps IMPLEMENTATION phase" {
    touch "$E2E_TMPDIR/SPEC.md"
    create_milestone "milestone:planning-done" "P"
    create_milestone "milestone:analysts-done" "A"
    create_milestone "milestone:plan-reviewed" "R"

    # Task being reviewed (in_progress + reviewing) blocks phase transition
    cd "$E2E_TMPDIR"
    local id=$(bd create --title="Under review" --type=task --priority=1 2>&1 | grep "Created issue:" | sed 's/.*Created issue: //' | awk '{print $1}')
    bd update "$id" --status=in_progress --add-label=reviewing

    local phase=$(get_phase)
    [[ "$phase" == "IMPLEMENTATION" ]]
}

@test "E2E: approved task keeps IMPLEMENTATION phase" {
    touch "$E2E_TMPDIR/SPEC.md"
    create_milestone "milestone:planning-done" "P"
    create_milestone "milestone:analysts-done" "A"
    create_milestone "milestone:plan-reviewed" "R"

    # Task approved but not merged (in_progress + approved) blocks phase transition
    cd "$E2E_TMPDIR"
    local id=$(bd create --title="Awaiting merge" --type=task --priority=1 2>&1 | grep "Created issue:" | sed 's/.*Created issue: //' | awk '{print $1}')
    bd update "$id" --status=in_progress --add-label=approved

    local phase=$(get_phase)
    [[ "$phase" == "IMPLEMENTATION" ]]
}

@test "E2E: regression_count reflects open regression tasks" {
    touch "$E2E_TMPDIR/SPEC.md"
    create_milestone "milestone:planning-done" "P"
    create_milestone "milestone:analysts-done" "A"
    create_milestone "milestone:plan-reviewed" "R"

    # Create 2 regression tasks
    cd "$E2E_TMPDIR"
    bd create --title="Regression 1" --type=bug --labels="regression" >/dev/null 2>&1
    bd create --title="Regression 2" --type=bug --labels="regression" >/dev/null 2>&1

    local json=$("$DETECT_PHASE")
    local count=$(echo "$json" | jq '.regression_count')

    [[ "$count" -eq 2 ]]
}
