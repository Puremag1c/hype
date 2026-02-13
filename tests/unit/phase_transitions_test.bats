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

@test "phase: no SPEC.md → INIT" {
    rm -f "$TEST_PROJECT/SPEC.md"
    [ "$(get_phase)" = "INIT" ]
}

@test "phase: SPEC + no tasks → PLANNING" {
    [ "$(get_phase)" = "PLANNING" ]
}

@test "phase: tasks exist, no planning milestone → PLANNING" {
    set_tasks '[{"id":"t1","title":"task","status":"open","priority":2,"labels":[]}]'
    [ "$(get_phase)" = "PLANNING" ]
}

@test "phase: planning done, no analysts milestone → HELPERS" {
    set_tasks '[{"id":"t1","title":"task","status":"open","priority":2,"labels":[]}]'
    set_milestone "planning-done"
    [ "$(get_phase)" = "HELPERS" ]
}

@test "phase: analysts done, no plan-reviewed → PLAN_REVIEW" {
    set_tasks '[{"id":"t1","title":"task","status":"open","priority":2,"labels":[]}]'
    set_milestone "planning-done"
    set_milestone "analysts-done"
    [ "$(get_phase)" = "PLAN_REVIEW" ]
}

@test "phase: all milestones + open tasks → IMPLEMENTATION" {
    set_all_milestones
    set_tasks '[{"id":"t1","title":"task","status":"open","priority":2,"labels":["model:sonnet"]}]'
    [ "$(get_phase)" = "IMPLEMENTATION" ]
}

@test "phase: all milestones + in_progress tasks → IMPLEMENTATION" {
    set_all_milestones
    set_tasks '[{"id":"t1","title":"task","status":"in_progress","priority":2,"labels":["model:sonnet"]}]'
    [ "$(get_phase)" = "IMPLEMENTATION" ]
}

@test "phase: all milestones + all closed + no smoke-test-done → SMOKE_TEST" {
    set_all_milestones
    set_tasks '[{"id":"t1","title":"task","status":"closed","priority":2,"labels":[]}]'
    [ "$(get_phase)" = "SMOKE_TEST" ]
}

@test "phase: all milestones + smoke-test-done → FINAL_REVIEW" {
    set_all_milestones
    set_milestone "smoke-test-done"
    set_tasks '[{"id":"t1","title":"task","status":"closed","priority":2,"labels":[]}]'
    [ "$(get_phase)" = "FINAL_REVIEW" ]
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

@test "smoke: testers PID alive + no smoke tasks → SMOKE_TEST" {
    set_all_milestones
    set_tasks '[{"id":"t1","title":"task","status":"closed","priority":2,"labels":[]}]'
    create_alive_pid
    [ "$(get_phase)" = "SMOKE_TEST" ]
}

@test "smoke: testers PID alive + smoke tasks exist → SMOKE_TEST (NOT SMOKE_REVIEW)" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"task","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"SMOKE: bug","status":"open","priority":1,"labels":["smoke"]}
    ]'
    create_alive_pid
    local phase=$(get_phase)
    [ "$phase" = "SMOKE_TEST" ]
}

@test "smoke: testers PID alive + open tasks (executor) → SMOKE_TEST (NOT IMPLEMENTATION)" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"closed task","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"Fix bug","status":"open","priority":1,"labels":["model:sonnet"]}
    ]'
    create_alive_pid
    local phase=$(get_phase)
    [ "$phase" = "SMOKE_TEST" ]
}

@test "smoke: testers PID alive + in_progress executor → SMOKE_TEST (NOT IMPLEMENTATION)" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"closed task","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"Fix bug","status":"in_progress","priority":1,"labels":["model:sonnet"]}
    ]'
    create_alive_pid
    local phase=$(get_phase)
    [ "$phase" = "SMOKE_TEST" ]
}

@test "smoke: testers PID alive + smoke + regression → SMOKE_TEST (NOT SMOKE_REVIEW)" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"task","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"SMOKE: new","status":"open","priority":1,"labels":["smoke"]},
        {"id":"t3","title":"REGRESS: old","status":"open","priority":0,"labels":["smoke","regression"]}
    ]'
    create_alive_pid
    local phase=$(get_phase)
    [ "$phase" = "SMOKE_TEST" ]
}

@test "smoke: testers PID dead + smoke tasks → SMOKE_REVIEW" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"task","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"SMOKE: bug","status":"open","priority":1,"labels":["smoke"]}
    ]'
    create_dead_pid
    [ "$(get_phase)" = "SMOKE_REVIEW" ]
}

@test "smoke: no PID file + smoke tasks → SMOKE_REVIEW" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"task","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"SMOKE: bug","status":"open","priority":1,"labels":["smoke"]}
    ]'
    [ "$(get_phase)" = "SMOKE_REVIEW" ]
}

@test "smoke: testers PID dead + no smoke + all closed → SMOKE_TEST (milestone path)" {
    set_all_milestones
    set_tasks '[{"id":"t1","title":"task","status":"closed","priority":2,"labels":[]}]'
    create_dead_pid
    [ "$(get_phase)" = "SMOKE_TEST" ]
}

@test "smoke: after triage (smoke labels removed) + tasks open → IMPLEMENTATION" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"done task","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"Fix bug from smoke","status":"open","priority":1,"labels":["model:sonnet"]}
    ]'
    # No PID file, no smoke labels
    [ "$(get_phase)" = "IMPLEMENTATION" ]
}

# ============================================================
# 3. TRIGGER-BASED SMOKE_TEST
# ============================================================

@test "triggers: tester triggers open + all real closed → SMOKE_TEST" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"real task","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"run-tester-functional","status":"open","priority":0,"labels":["trigger"]}
    ]'
    [ "$(get_phase)" = "SMOKE_TEST" ]
}

@test "triggers: tester triggers + open real tasks → IMPLEMENTATION (not SMOKE_TEST)" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"real task","status":"open","priority":2,"labels":["model:sonnet"]},
        {"id":"t2","title":"run-tester-functional","status":"open","priority":0,"labels":["trigger"]}
    ]'
    [ "$(get_phase)" = "IMPLEMENTATION" ]
}

@test "triggers: tester triggers + in_progress real task → IMPLEMENTATION" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"real task","status":"in_progress","priority":2,"labels":["model:sonnet"]},
        {"id":"t2","title":"run-tester-functional","status":"open","priority":0,"labels":["trigger"]}
    ]'
    [ "$(get_phase)" = "IMPLEMENTATION" ]
}

@test "triggers: tester triggers + smoke-test-done → not SMOKE_TEST" {
    set_all_milestones
    set_milestone "smoke-test-done"
    set_tasks '[
        {"id":"t1","title":"task","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"run-tester-functional","status":"open","priority":0,"labels":["trigger"]}
    ]'
    # smoke-test-done milestone exists, so check 12 skips, falls to IMPLEMENTATION (trigger is open)
    # Actually: OPEN excludes triggers, so OPEN=0, IN_PROGRESS=0 → falls to FINAL_REVIEW
    # Wait: triggers are open but excluded from OPEN count. So OPEN=0, IN_PROGRESS=0.
    # Check 14: CLOSED > 0 + smoke-test-done → FINAL_REVIEW
    [ "$(get_phase)" = "FINAL_REVIEW" ]
}

# ============================================================
# 4. EDGE CASES & OVERRIDES
# ============================================================

@test "edge: force-phase file overrides everything" {
    set_all_milestones
    set_tasks '[{"id":"t1","title":"task","status":"open","priority":2,"labels":[]}]'
    echo "FINAL_REVIEW" > "$TEST_PROJECT/.hype/force-phase"
    [ "$(get_phase)" = "FINAL_REVIEW" ]
    # force-phase is one-shot — consumed after read
    [ ! -f "$TEST_PROJECT/.hype/force-phase" ]
}

@test "edge: user-escalation overrides SMOKE_REVIEW and IMPLEMENTATION" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"Escalated task","status":"open","priority":1,"labels":["user-escalation"]},
        {"id":"t2","title":"SMOKE: bug","status":"open","priority":1,"labels":["smoke"]}
    ]'
    [ "$(get_phase)" = "USER_REVIEW" ]
}

@test "edge: user-escalation overrides testers PID" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"Escalated","status":"open","priority":1,"labels":["user-escalation"]}
    ]'
    create_alive_pid
    [ "$(get_phase)" = "USER_REVIEW" ]
}

@test "edge: needs-spec + empty tasks → INIT" {
    set_tasks '[]'
    touch "$TEST_PROJECT/.hype/needs-spec"
    [ "$(get_phase)" = "INIT" ]
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

@test "edge: mixed open + closed + in_progress → IMPLEMENTATION" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"done","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"working","status":"in_progress","priority":2,"labels":["model:sonnet"]},
        {"id":"t3","title":"waiting","status":"open","priority":2,"labels":["model:haiku"]},
        {"id":"t4","title":"approved","status":"in_progress","priority":2,"labels":["approved"]}
    ]'
    [ "$(get_phase)" = "IMPLEMENTATION" ]
}

# ============================================================
# 5. SELF-HEALING
# ============================================================

@test "self-heal: analyst triggers pending + analysts-done → HELPERS (milestone removed)" {
    set_tasks '[
        {"id":"t1","title":"task","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"run-analyst-code","status":"open","priority":0,"labels":["trigger"]}
    ]'
    set_milestone "planning-done"
    set_milestone "analysts-done"
    local phase=$(get_phase)
    [ "$phase" = "HELPERS" ]
    # Milestone file should be removed by self-heal
    [ ! -f "$TEST_PROJECT/.hype/milestone-analysts-done" ]
}

# ============================================================
# 6. REALISTIC MULTI-STEP SCENARIOS
# ============================================================

@test "scenario: full IMPLEMENTATION with review pipeline" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"done","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"working","status":"in_progress","priority":2,"labels":["executor"]},
        {"id":"t3","title":"reviewing","status":"in_progress","priority":2,"labels":["reviewing"]},
        {"id":"t4","title":"approved","status":"in_progress","priority":2,"labels":["approved"]},
        {"id":"t5","title":"waiting","status":"open","priority":2,"labels":["model:haiku"]}
    ]'
    [ "$(get_phase)" = "IMPLEMENTATION" ]
}

@test "scenario: smoke test just launched (triggers + PID alive)" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"done","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"run-tester-functional","status":"open","priority":0,"labels":["trigger"]},
        {"id":"t3","title":"run-tester-backend","status":"in_progress","priority":0,"labels":["trigger"]}
    ]'
    create_alive_pid
    [ "$(get_phase)" = "SMOKE_TEST" ]
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
    # MUST be SMOKE_TEST — testers still running, don't triage yet
    [ "$(get_phase)" = "SMOKE_TEST" ]
}

@test "scenario: all testers done + smoke tasks → SMOKE_REVIEW" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"done","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"run-tester-functional","status":"closed","priority":0,"labels":["trigger"]},
        {"id":"t3","title":"run-tester-backend","status":"closed","priority":0,"labels":["trigger"]},
        {"id":"t4","title":"SMOKE: api bug","status":"open","priority":1,"labels":["smoke"]},
        {"id":"t5","title":"SMOKE: ui bug","status":"open","priority":1,"labels":["smoke"]}
    ]'
    # No PID file (testers finished, hype.sh cleaned up)
    [ "$(get_phase)" = "SMOKE_REVIEW" ]
}

@test "scenario: architect triaged smoke → tasks back in IMPLEMENTATION" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"done","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"Fix api bug","status":"open","priority":1,"labels":["model:sonnet"]},
        {"id":"t3","title":"Fix ui bug","status":"in_progress","priority":1,"labels":["model:sonnet","executor"]}
    ]'
    # smoke labels removed by architect, PID file removed by SMOKE_REVIEW
    [ "$(get_phase)" = "IMPLEMENTATION" ]
}

@test "scenario: all smoke fixes done → SMOKE_TEST (for re-test)" {
    set_all_milestones
    # No smoke-test-done milestone (will be created after re-test passes)
    set_tasks '[
        {"id":"t1","title":"done","status":"closed","priority":2,"labels":[]},
        {"id":"t2","title":"Fix api bug","status":"closed","priority":1,"labels":[]},
        {"id":"t3","title":"Fix ui bug","status":"closed","priority":1,"labels":[]}
    ]'
    [ "$(get_phase)" = "SMOKE_TEST" ]
}

# ============================================================
# v2.3.16: blocked:* tasks stay in IMPLEMENTATION (not DONE)
# ============================================================

@test "scenario: blocked:troubleshoot task keeps phase in IMPLEMENTATION" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"Impl X","status":"open","priority":2,"labels":["blocked:troubleshoot"]},
        {"id":"t2","title":"done","status":"closed","priority":2,"labels":[]}
    ]'
    # blocked:troubleshoot is still open — phase must not jump to DONE/SMOKE_TEST
    [ "$(get_phase)" = "IMPLEMENTATION" ]
}

@test "scenario: blocked:escalated task keeps phase in IMPLEMENTATION" {
    set_all_milestones
    set_tasks '[
        {"id":"t1","title":"Impl Y","status":"open","priority":2,"labels":["blocked:escalated"]},
        {"id":"t2","title":"done","status":"closed","priority":2,"labels":[]}
    ]'
    [ "$(get_phase)" = "IMPLEMENTATION" ]
}
