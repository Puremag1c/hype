#!/usr/bin/env bats
# tests/unit/hype_v22_test.bats
# Tests for v2.2 changes in hype.sh: IMPLEMENTATION routing + heal_stuck_tasks

load '../helpers/setup'

# =============================================================================
# IMPLEMENTATION phase: calls run-reviewers.sh + run-merge-queue.sh
# =============================================================================

@test "hype: IMPLEMENTATION calls run-reviewers.sh" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local impl_block
    impl_block=$(sed -n '/IMPLEMENTATION)/,/;;/p' "$hype_sh")

    echo "$impl_block" | grep -q 'run-reviewers.sh'
}

@test "hype: IMPLEMENTATION calls run-merge-queue.sh" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local impl_block
    impl_block=$(sed -n '/IMPLEMENTATION)/,/;;/p' "$hype_sh")

    echo "$impl_block" | grep -q 'run-merge-queue.sh'
}

@test "hype: IMPLEMENTATION does NOT call run-senior-executor.sh" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local impl_block
    impl_block=$(sed -n '/IMPLEMENTATION)/,/;;/p' "$hype_sh")

    ! echo "$impl_block" | grep -q 'run-senior-executor.sh'
}

# =============================================================================
# heal_stuck_tasks: reviewing healing (v2.2)
# =============================================================================

@test "heal: detects reviewing label in stuck tasks" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local heal_block
    heal_block=$(sed -n '/^heal_stuck_tasks()/,/^}/p' "$hype_sh")

    echo "$heal_block" | grep -q 'index("reviewing")'
}

@test "heal: reviewing threshold is 180s (3 min)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local heal_block
    heal_block=$(sed -n '/^heal_stuck_tasks()/,/^}/p' "$hype_sh")

    echo "$heal_block" | grep -q 'reviewing_threshold=180'
}

@test "heal: checks reviewer lock before healing reviewing task" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local heal_block
    heal_block=$(sed -n '/^heal_stuck_tasks()/,/^}/p' "$hype_sh")

    echo "$heal_block" | grep -q 'review-.*lock'
}

@test "heal: reviewing recovery removes reviewing, adds needs-review" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local heal_block
    heal_block=$(sed -n '/^heal_stuck_tasks()/,/^}/p' "$hype_sh")

    echo "$heal_block" | grep -q 'remove-label=reviewing.*add-label=needs-review'
}

# =============================================================================
# heal_stuck_tasks: approved warning (v2.2)
# =============================================================================

@test "heal: detects approved label in stuck tasks" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local heal_block
    heal_block=$(sed -n '/^heal_stuck_tasks()/,/^}/p' "$hype_sh")

    echo "$heal_block" | grep -q 'index("approved")'
}

@test "heal: approved threshold is 300s (5 min)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local heal_block
    heal_block=$(sed -n '/^heal_stuck_tasks()/,/^}/p' "$hype_sh")

    echo "$heal_block" | grep -q 'approved_threshold=300'
}

@test "heal: logs warning for stuck approved tasks" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local heal_block
    heal_block=$(sed -n '/^heal_stuck_tasks()/,/^}/p' "$hype_sh")

    echo "$heal_block" | grep -q 'merge queue may be stuck'
}
