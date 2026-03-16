#!/usr/bin/env bats
# tests/unit/phase_transitions_test.bats
#
# FUNCTIONAL tests for detect-phase.sh phase transition logic.
# These run the ACTUAL script with mocked bd, not grep patterns.
# Each test sets up a state (tasks, milestones, PID files) and asserts the output phase.

load '../helpers/setup'

# === Test harness ===

setup() {
    # Isolated project directory
    TEST_PROJECT=$(mktemp -d)
    MOCK_DIR=$(mktemp -d)
    MOCK_BIN=$(mktemp -d)

    mkdir -p "$TEST_PROJECT/.hype"

    # Default: SPEC.md exists
    touch "$TEST_PROJECT/SPEC.md"

    # Default: empty task list, no cycles
    echo '[]' > "$MOCK_DIR/tasks.json"
    echo 'No cycles detected' > "$MOCK_DIR/dep-cycles.txt"

    # Create mock bd executable
    cat > "$MOCK_BIN/bd" << 'MOCKSCRIPT'
#!/bin/bash
MOCK_DIR="${HYPE_TEST_MOCK_DIR}"
case "$*" in
    *list*--json*)
        cat "$MOCK_DIR/tasks.json" 2>/dev/null || echo '[]'
        ;;
    *dep*cycles*)
        cat "$MOCK_DIR/dep-cycles.txt" 2>/dev/null || echo 'No cycles detected'
        ;;
    *)
        # update, close, create, daemon — no-op
        true
        ;;
esac
MOCKSCRIPT
    chmod +x "$MOCK_BIN/bd"

    # Cleanup stale bd lock from previous test
    rmdir /tmp/hype-bd.lock.d 2>/dev/null || true
}

teardown() {
    # Kill test sleep process if alive
    [ -n "${TEST_PID:-}" ] && kill "$TEST_PID" 2>/dev/null || true
    rm -rf "$TEST_PROJECT" "$MOCK_DIR" "$MOCK_BIN"
    rmdir /tmp/hype-bd.lock.d 2>/dev/null || true
}

# --- Helpers ---

set_tasks() {
    echo "$1" > "$MOCK_DIR/tasks.json"
}

set_milestone() {
    touch "$TEST_PROJECT/.hype/milestone-$1"
}

set_all_milestones() {
    set_milestone "planning-done"
    set_milestone "analysts-done"
    set_milestone "plan-reviewed"
}

create_alive_pid() {
    sleep 300 &
    TEST_PID=$!
    echo "$TEST_PID" > "$TEST_PROJECT/.hype/run-testers.pid"
}

create_dead_pid() {
    # PID that definitely doesn't exist
    echo "99999" > "$TEST_PROJECT/.hype/run-testers.pid"
}

set_dep_cycles() {
    echo "$1" > "$MOCK_DIR/dep-cycles.txt"
}

get_phase() {
    local output
    output=$(cd "$TEST_PROJECT" && \
        PATH="$MOCK_BIN:$PATH" \
        HYPE_TEST_MOCK_DIR="$MOCK_DIR" \
        BD_TIMEOUT=5s \
        bash "$SCRIPTS_DIR/detect-phase.sh" 2>/dev/null) || true
    echo "$output" | jq -r '.phase' 2>/dev/null || echo "PARSE_ERROR"
}

# ============================================================
# 1. BASIC PHASE PROGRESSION (happy path)
# ============================================================

@test "phase: no SPEC.md → PREPARING" {
    rm -f "$TEST_PROJECT/SPEC.md"
    [ "$(get_phase)" = "PREPARING" ]
}

@test "phase: SPEC + no tasks → PLANNING" {
    [ "$(get_phase)" = "PLANNING" ]
}

@test "phase: tasks exist, no planning milestone → PLANNING" {
    set_tasks '[{"id":"t1","title":"task","status":"open","priority":2,"labels":[]}]'
    [ "$(get_phase)" = "PLANNING" ]
}

@test "phase: planning done, no analysts milestone → ANALYZE" {
    set_tasks '[{"id":"t1","title":"task","status":"open","priority":2,"labels":[]}]'
    set_milestone "planning-done"
    [ "$(get_phase)" = "ANALYZE" ]
}

@test "phase: analysts done, no plan-reviewed → THINKING" {
    set_tasks '[{"id":"t1","title":"task","status":"open","priority":2,"labels":[]}]'
    set_milestone "planning-done"
    set_milestone "analysts-done"
    [ "$(get_phase)" = "THINKING" ]
}

@test "phase: all milestones + open tasks → CODING" {
    set_all_milestones
    set_tasks '[{"id":"t1","title":"task","status":"open","priority":2,"labels":["model:sonnet"]}]'
    [ "$(get_phase)" = "CODING" ]
}

@test "phase: all milestones + in_progress tasks → CODING" {
    set_all_milestones
    set_tasks '[{"id":"t1","title":"task","status":"in_progress","priority":2,"labels":["model:sonnet"]}]'
    [ "$(get_phase)" = "CODING" ]
}

@test "phase: all milestones + all closed + no testing-done → TESTING" {
    set_all_milestones
    set_tasks '[{"id":"t1","title":"task","status":"closed","priority":2,"labels":[]}]'
    [ "$(get_phase)" = "TESTING" ]
}

@test "phase: all milestones + testing-done → VALIDATING" {
    set_all_milestones
    set_milestone "testing-done"
    set_tasks '[{"id":"t1","title":"task","status":"closed","priority":2,"labels":[]}]'
    [ "$(get_phase)" = "VALIDATING" ]
}

@test "phase: project-done milestone → DONE" {
    set_all_milestones
    set_milestone "project-done"
    set_tasks '[{"id":"t1","title":"task","status":"closed","priority":2,"labels":[]}]'
    [ "$(get_phase)" = "DONE" ]
}

# ============================================================
# 2. SMOKE TEST PHASE TRANSITIONS (the critical ones)
# ============================================================

@test "smoke: testers PID alive + no smoke tasks → TESTING" {
    set_all_milestones
    set_tasks '[{"id":"t1","title":"task","status":"closed","priority":2,"labels":[]}]'
    create_alive_pid
    [ "$(get_phase)" = "TESTING" ]
}

@test "smoke: testers PID alive + smoke tasks exist → TESTING (NOT REFLEXING)" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"task","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"SMOKE: bug","status":"open","priority":1,"labels":["smoke"]}
    ]'
    create_alive_pid
    local phase=$(get_phase)
    [ "$phase" = "TESTING" ]
}

@test "smoke: testers PID alive + open tasks (coder) → TESTING (NOT CODING)" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"closed task","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"Fix bug","status":"open","priority":1,"labels":["model:sonnet"]}
    ]'
    create_alive_pid
    local phase=$(get_phase)
    [ "$phase" = "TESTING" ]
}

@test "smoke: testers PID alive + in_progress coder → TESTING (NOT CODING)" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"closed task","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"Fix bug","status":"in_progress","priority":1,"labels":["model:sonnet"]}
    ]'
    create_alive_pid
    local phase=$(get_phase)
    [ "$phase" = "TESTING" ]
}

@test "smoke: testers PID alive + smoke + regression → TESTING (NOT REFLEXING)" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"task","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"SMOKE: new","status":"open","priority":1,"labels":["smoke"]},
        {"id":"t3","title":"REGRESS: old","status":"open","priority":0,"labels":["smoke","regression"]}
    ]'
    create_alive_pid
    local phase=$(get_phase)
    [ "$phase" = "TESTING" ]
}

@test "smoke: testers PID dead + smoke tasks → REFLEXING" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"task","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"SMOKE: bug","status":"open","priority":1,"labels":["smoke"]}
    ]'
    create_dead_pid
    [ "$(get_phase)" = "REFLEXING" ]
}

@test "smoke: no PID file + smoke tasks → REFLEXING" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"task","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"SMOKE: bug","status":"open","priority":1,"labels":["smoke"]}
    ]'
    [ "$(get_phase)" = "REFLEXING" ]
}

@test "smoke: testers PID dead + no smoke + all closed → TESTING (milestone path)" {
    set_all_milestones
    set_tasks '[{"id":"t1","title":"task","status":"closed","priority":2,"labels":[]}]'
    create_dead_pid
    [ "$(get_phase)" = "TESTING" ]
}

@test "smoke: after triage (smoke labels removed) + tasks open → CODING" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"done task","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"Fix bug from smoke","status":"open","priority":1,"labels":["model:sonnet"]}
    ]'
    # No PID file, no smoke labels
    [ "$(get_phase)" = "CODING" ]
}

# ============================================================
# 3. TRIGGER-BASED TESTING
# ============================================================

@test "triggers: tester triggers open + all real closed → TESTING" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"real task","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"run-tester-functional","status":"open","priority":0,"labels":["trigger"]}
    ]'
    [ "$(get_phase)" = "TESTING" ]
}

@test "triggers: tester triggers + open real tasks → CODING (not TESTING)" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"real task","status":"open","priority":2,"labels":["model:sonnet"]},
        {"id":"t2","title":"run-tester-functional","status":"open","priority":0,"labels":["trigger"]}
    ]'
    [ "$(get_phase)" = "CODING" ]
}

@test "triggers: tester triggers + in_progress real task → CODING" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"real task","status":"in_progress","priority":2,"labels":["model:sonnet"]},
        {"id":"t2","title":"run-tester-functional","status":"open","priority":0,"labels":["trigger"]}
    ]'
    [ "$(get_phase)" = "CODING" ]
}

@test "triggers: tester triggers + testing-done → not TESTING" {
    set_all_milestones
    set_milestone "testing-done"
    set_tasks '[
        {"id":"t1","title":"task","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"run-tester-functional","status":"open","priority":0,"labels":["trigger"]}
    ]'
    # testing-done milestone exists, so check 12 skips, falls to CODING (trigger is open)
    # Actually: OPEN excludes triggers, so OPEN=0, IN_PROGRESS=0 → falls to VALIDATING
    # Wait: triggers are open but excluded from OPEN count. So OPEN=0, IN_PROGRESS=0.
    # Check 14: CLOSED > 0 + testing-done → VALIDATING
    [ "$(get_phase)" = "VALIDATING" ]
}

# ============================================================
# 4. EDGE CASES & OVERRIDES
# ============================================================

@test "edge: force-phase file overrides everything" {
    set_all_milestones
    set_tasks '[{"id":"t1","title":"task","status":"open","priority":2,"labels":[]}]'
    echo "VALIDATING" > "$TEST_PROJECT/.hype/force-phase"
    [ "$(get_phase)" = "VALIDATING" ]
    # force-phase is one-shot — consumed after read
    [ ! -f "$TEST_PROJECT/.hype/force-phase" ]
}

@test "edge: user-escalation overrides REFLEXING and CODING" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"Escalated task","status":"open","priority":1,"labels":["user-escalation"]},
        {"id":"t2","title":"SMOKE: bug","status":"open","priority":1,"labels":["smoke"]}
    ]'
    [ "$(get_phase)" = "CONSULTATION" ]
}

@test "edge: user-escalation overrides testers PID" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"Escalated","status":"open","priority":1,"labels":["user-escalation"]}
    ]'
    create_alive_pid
    [ "$(get_phase)" = "CONSULTATION" ]
}

@test "edge: needs-spec + empty tasks → PREPARING" {
    set_tasks '[]'
    touch "$TEST_PROJECT/.hype/needs-spec"
    [ "$(get_phase)" = "PREPARING" ]
}

@test "edge: empty bd response + planning milestone → ERROR" {
    set_tasks '[]'
    set_milestone "planning-done"
    [ "$(get_phase)" = "ERROR" ]
}

@test "edge: dependency cycles → BLOCKED_CYCLES" {
    set_all_milestones
    set_tasks '[{"id":"t1","title":"task","status":"open","priority":2,"labels":["model:sonnet"]}]'
    set_dep_cycles "t1 → t2 → t1"
    [ "$(get_phase)" = "BLOCKED_CYCLES" ]
}

@test "edge: mixed open + closed + in_progress → CODING" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"done","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"working","status":"in_progress","priority":2,"labels":["model:sonnet"]},
        {"id":"t3","title":"waiting","status":"open","priority":2,"labels":["model:haiku"]},
        {"id":"t4","title":"approved","status":"in_progress","priority":2,"labels":["approved"]}
    ]'
    [ "$(get_phase)" = "CODING" ]
}

# ============================================================
# 5. SELF-HEALING
# ============================================================

@test "self-heal: analyst triggers pending + analysts-done → ANALYZE (milestone removed)" {
    set_tasks '[
        {"id":"t1","title":"task","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"run-analyst-code","status":"open","priority":0,"labels":["trigger"]}
    ]'
    set_milestone "planning-done"
    set_milestone "analysts-done"
    local phase=$(get_phase)
    [ "$phase" = "ANALYZE" ]
    # Milestone file should be removed by self-heal
    [ ! -f "$TEST_PROJECT/.hype/milestone-analysts-done" ]
}

# ============================================================
# 6. REALISTIC MULTI-STEP SCENARIOS
# ============================================================

@test "scenario: full CODING with review pipeline" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"done","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"working","status":"in_progress","priority":2,"labels":["coder"]},
        {"id":"t3","title":"reviewing","status":"in_progress","priority":2,"labels":["reviewing"]},
        {"id":"t4","title":"approved","status":"in_progress","priority":2,"labels":["approved"]},
        {"id":"t5","title":"waiting","status":"open","priority":2,"labels":["model:haiku"]}
    ]'
    [ "$(get_phase)" = "CODING" ]
}

@test "scenario: smoke test just launched (triggers + PID alive)" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"done","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"run-tester-functional","status":"open","priority":0,"labels":["trigger"]},
        {"id":"t3","title":"run-tester-backend","status":"in_progress","priority":0,"labels":["trigger"]}
    ]'
    create_alive_pid
    [ "$(get_phase)" = "TESTING" ]
}

@test "scenario: one tester done (created smoke task) + others still running" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"done","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"run-tester-functional","status":"closed","priority":0,"labels":["trigger"]},
        {"id":"t3","title":"run-tester-backend","status":"in_progress","priority":0,"labels":["trigger"]},
        {"id":"t4","title":"SMOKE: api bug","status":"open","priority":1,"labels":["smoke"]}
    ]'
    create_alive_pid
    # MUST be TESTING — testers still running, don't triage yet
    [ "$(get_phase)" = "TESTING" ]
}

@test "scenario: all testers done + smoke tasks → REFLEXING" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"done","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"run-tester-functional","status":"closed","priority":0,"labels":["trigger"]},
        {"id":"t3","title":"run-tester-backend","status":"closed","priority":0,"labels":["trigger"]},
        {"id":"t4","title":"SMOKE: api bug","status":"open","priority":1,"labels":["smoke"]},
        {"id":"t5","title":"SMOKE: ui bug","status":"open","priority":1,"labels":["smoke"]}
    ]'
    # No PID file (testers finished, hype.sh cleaned up)
    [ "$(get_phase)" = "REFLEXING" ]
}

@test "scenario: architect triaged smoke → tasks back in CODING" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"done","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"Fix api bug","status":"open","priority":1,"labels":["model:sonnet"]},
        {"id":"t3","title":"Fix ui bug","status":"in_progress","priority":1,"labels":["model:sonnet","coder"]}
    ]'
    # smoke labels removed by architect, PID file removed by REFLEXING
    [ "$(get_phase)" = "CODING" ]
}

@test "scenario: all smoke fixes done → TESTING (for re-test)" {
    set_all_milestones
    # No testing-done milestone (will be created after re-test passes)
    set_tasks '[
        {"id":"t1","title":"done","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"Fix api bug","status":"closed","priority":1,"labels":[]},
        {"id":"t3","title":"Fix ui bug","status":"closed","priority":1,"labels":[]}
    ]'
    [ "$(get_phase)" = "TESTING" ]
}

# ============================================================
# v2.3.16: blocked:* tasks stay in CODING (not DONE)
# ============================================================

@test "scenario: blocked:troubleshoot task keeps phase in CODING" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"Impl X","status":"open","priority":2,"labels":["blocked:troubleshoot"]},
        {"id":"t2","title":"done","status":"closed","priority":2,"labels":[]}
    ]'
    # blocked:troubleshoot is still open — phase must not jump to DONE/TESTING
    [ "$(get_phase)" = "CODING" ]
}


