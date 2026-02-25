#!/usr/bin/env bats
# tests/unit/subissue_filter_test.bats
# Tests for sub-issue filtering and CLOSED count consistency (#20)

load '../helpers/setup'

# =============================================================================
# Fix 3: Sub-issue filter in detect-phase.sh
# =============================================================================

@test "detect-phase: filters sub-issues with dotted IDs" {
    local detect_sh="$SCRIPTS_DIR/detect-phase.sh"

    # Should filter out IDs containing dots (bd set-state audit trail)
    grep -q 'select(.id | test(' "$detect_sh"
    grep -q 'sub-issues' "$detect_sh"
}

@test "detect-phase: sub-issue filter is applied before stats computation" {
    local detect_sh="$SCRIPTS_DIR/detect-phase.sh"

    # Sub-issue filter line must come before OPEN/IN_PROGRESS/CLOSED stats
    local filter_line stats_line
    filter_line=$(grep -n 'sub-issues.*set-state' "$detect_sh" | head -1 | cut -d: -f1)
    stats_line=$(grep -n '^OPEN=' "$detect_sh" | head -1 | cut -d: -f1)

    [ -n "$filter_line" ]
    [ -n "$stats_line" ]
    [ "$filter_line" -lt "$stats_line" ]
}

# =============================================================================
# Fix 4: CLOSED count excludes triggers and milestones
# =============================================================================

@test "detect-phase: CLOSED excludes trigger-labeled tasks" {
    local detect_sh="$SCRIPTS_DIR/detect-phase.sh"

    # CLOSED filter should exclude triggers (consistent with OPEN)
    local closed_block
    closed_block=$(sed -n '/^CLOSED=/,/|| echo "0")/p' "$detect_sh")

    echo "$closed_block" | grep -q 'index("trigger") | not'
}

@test "detect-phase: CLOSED excludes milestone-labeled tasks" {
    local detect_sh="$SCRIPTS_DIR/detect-phase.sh"

    local closed_block
    closed_block=$(sed -n '/^CLOSED=/,/|| echo "0")/p' "$detect_sh")

    echo "$closed_block" | grep -q 'startswith("milestone:")'
}

@test "detect-phase: OPEN already excludes triggers (baseline)" {
    local detect_sh="$SCRIPTS_DIR/detect-phase.sh"

    local open_block
    open_block=$(sed -n '/^OPEN=/,/|| echo "0")/p' "$detect_sh")

    echo "$open_block" | grep -q 'index("trigger") | not'
}

# =============================================================================
# Functional: sub-issue filter with mock bd
# =============================================================================

@test "functional: sub-issues excluded from progress count" {
    # Uses phase_transitions_test harness style
    local TEST_PROJECT MOCK_DIR MOCK_BIN
    TEST_PROJECT=$(mktemp -d)
    MOCK_DIR=$(mktemp -d)
    MOCK_BIN=$(mktemp -d)

    mkdir -p "$TEST_PROJECT/.hype"
    touch "$TEST_PROJECT/SPEC.md"
    touch "$TEST_PROJECT/.hype/milestone-planning-done"
    touch "$TEST_PROJECT/.hype/milestone-analysts-done"
    touch "$TEST_PROJECT/.hype/milestone-plan-reviewed"

    # Simulate: 2 real tasks + 3 sub-issues from bd set-state
    cat > "$MOCK_DIR/tasks.json" << 'JSON'
[
  {"id":"beads-abc","title":"Implement X","status":"closed","priority":2,"labels":[]},
  {"id":"beads-def","title":"Implement Y","status":"open","priority":2,"labels":["model:sonnet"]},
  {"id":"beads-abc.1","title":"Implement X","status":"closed","priority":2,"labels":[]},
  {"id":"beads-abc.2","title":"Implement X","status":"closed","priority":2,"labels":[]},
  {"id":"beads-def.1","title":"Implement Y","status":"open","priority":2,"labels":["model:sonnet"]}
]
JSON
    echo 'No cycles detected' > "$MOCK_DIR/dep-cycles.txt"

    cat > "$MOCK_BIN/bd" << 'MOCKSCRIPT'
#!/bin/bash
MOCK_DIR="${HYPE_TEST_MOCK_DIR}"
case "$*" in
    *list*--json*) cat "$MOCK_DIR/tasks.json" ;;
    *dep*cycles*) cat "$MOCK_DIR/dep-cycles.txt" ;;
    *) true ;;
esac
MOCKSCRIPT
    chmod +x "$MOCK_BIN/bd"

    # Cleanup stale bd lock from previous test
    rmdir /tmp/hype-bd.lock.d 2>/dev/null || true

    local output
    output=$(cd "$TEST_PROJECT" && \
        PATH="$MOCK_BIN:$PATH" \
        HYPE_TEST_MOCK_DIR="$MOCK_DIR" \
        BD_TIMEOUT=5s \
        bash "$SCRIPTS_DIR/detect-phase.sh" 2>/dev/null) || true

    local phase total open closed
    phase=$(echo "$output" | jq -r '.phase')
    total=$(echo "$output" | jq -r '.stats.total')
    open=$(echo "$output" | jq -r '.stats.open')
    closed=$(echo "$output" | jq -r '.stats.closed')

    # Should be CODING (1 open real task)
    [ "$phase" = "CODING" ]
    # Total should be 2 (not 5), open=1 (not 2), closed=1 (not 3)
    [ "$total" -eq 2 ]
    [ "$open" -eq 1 ]
    [ "$closed" -eq 1 ]

    rm -rf "$TEST_PROJECT" "$MOCK_DIR" "$MOCK_BIN"
    rmdir /tmp/hype-bd.lock.d 2>/dev/null || true
}

@test "functional: closed triggers excluded from progress" {
    local TEST_PROJECT MOCK_DIR MOCK_BIN
    TEST_PROJECT=$(mktemp -d)
    MOCK_DIR=$(mktemp -d)
    MOCK_BIN=$(mktemp -d)

    mkdir -p "$TEST_PROJECT/.hype"
    touch "$TEST_PROJECT/SPEC.md"
    touch "$TEST_PROJECT/.hype/milestone-planning-done"
    touch "$TEST_PROJECT/.hype/milestone-analysts-done"
    touch "$TEST_PROJECT/.hype/milestone-plan-reviewed"

    # 2 real closed tasks + 1 closed trigger (should not inflate CLOSED count)
    cat > "$MOCK_DIR/tasks.json" << 'JSON'
[
  {"id":"beads-abc","title":"Implement X","status":"closed","priority":2,"labels":[]},
  {"id":"beads-def","title":"Implement Y","status":"closed","priority":2,"labels":[]},
  {"id":"beads-trg","title":"run-tester-functional","status":"closed","priority":0,"labels":["trigger"]}
]
JSON
    echo 'No cycles detected' > "$MOCK_DIR/dep-cycles.txt"

    cat > "$MOCK_BIN/bd" << 'MOCKSCRIPT'
#!/bin/bash
MOCK_DIR="${HYPE_TEST_MOCK_DIR}"
case "$*" in
    *list*--json*) cat "$MOCK_DIR/tasks.json" ;;
    *dep*cycles*) cat "$MOCK_DIR/dep-cycles.txt" ;;
    *) true ;;
esac
MOCKSCRIPT
    chmod +x "$MOCK_BIN/bd"

    rmdir /tmp/hype-bd.lock.d 2>/dev/null || true

    local output
    output=$(cd "$TEST_PROJECT" && \
        PATH="$MOCK_BIN:$PATH" \
        HYPE_TEST_MOCK_DIR="$MOCK_DIR" \
        BD_TIMEOUT=5s \
        bash "$SCRIPTS_DIR/detect-phase.sh" 2>/dev/null) || true

    local closed total
    closed=$(echo "$output" | jq -r '.stats.closed')
    total=$(echo "$output" | jq -r '.stats.total')

    # CLOSED should be 2 (not 3 — trigger excluded)
    [ "$closed" -eq 2 ]
    # Total = open + in_progress + closed = 0 + 0 + 2 = 2
    [ "$total" -eq 2 ]

    rm -rf "$TEST_PROJECT" "$MOCK_DIR" "$MOCK_BIN"
    rmdir /tmp/hype-bd.lock.d 2>/dev/null || true
}
