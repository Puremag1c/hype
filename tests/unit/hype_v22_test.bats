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

@test "heal: approved warn threshold is 300s (5 min)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local heal_block
    heal_block=$(sed -n '/^heal_stuck_tasks()/,/^}/p' "$hype_sh")

    echo "$heal_block" | grep -q 'approved_warn_threshold=300'
}

@test "heal: approved recovery threshold is 600s (10 min)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local heal_block
    heal_block=$(sed -n '/^heal_stuck_tasks()/,/^}/p' "$hype_sh")

    echo "$heal_block" | grep -q 'approved_recover_threshold=600'
}

@test "heal: logs warning for stuck approved tasks" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local heal_block
    heal_block=$(sed -n '/^heal_stuck_tasks()/,/^}/p' "$hype_sh")

    echo "$heal_block" | grep -q 'merge queue may be stuck'
}

@test "heal: recovers approved tasks stuck >10min (returns to executor)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local heal_block
    heal_block=$(sed -n '/^heal_stuck_tasks()/,/^}/p' "$hype_sh")

    # Should return to executor on recovery threshold
    echo "$heal_block" | grep -q 'returning to executor'
    # Should increment reject:N
    echo "$heal_block" | grep -q 'set_counter_label'
    # Should remove approved and set status=open
    echo "$heal_block" | grep -q 'remove-label=approved'
}

# =============================================================================
# merge queue: push failure handling
# =============================================================================

@test "merge-queue: handles push failure with reject:N increment" {
    local merge_sh="$SCRIPTS_DIR/run-merge-queue.sh"

    # Push failure block should increment reject:N
    local push_block
    push_block=$(sed -n '/git push.*main_ref/,/return 0/p' "$merge_sh" | head -20)

    echo "$push_block" | grep -q 'set_counter_label.*reject'
    echo "$push_block" | grep -q 'remove-label=approved'
    echo "$push_block" | grep -q 'status=open'
}

@test "merge-queue: push failure escalates to troubleshooter at reject:4" {
    local merge_sh="$SCRIPTS_DIR/run-merge-queue.sh"

    # After push failure, should escalate at reject:4
    grep -q 'blocked:troubleshoot' "$merge_sh"
    grep -q 'Push failures persist' "$merge_sh"
}
