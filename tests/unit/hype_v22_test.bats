#!/usr/bin/env bats
# tests/unit/hype_v22_test.bats
# Tests for v2.2 changes in hype.sh: CODING routing + heal_stuck_tasks

load '../helpers/setup'

# =============================================================================
# CODING phase: calls run-reviewers.sh + run-merge-queue.sh
# =============================================================================

@test "hype: CODING calls run-reviewers.sh" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local impl_block
    impl_block=$(sed -n '/CODING)/,/;;/p' "$hype_sh")

    echo "$impl_block" | grep -q 'run-reviewers.sh'
}

@test "hype: CODING calls run-merge-queue.sh" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local impl_block
    impl_block=$(sed -n '/CODING)/,/;;/p' "$hype_sh")

    echo "$impl_block" | grep -q 'run-merge-queue.sh'
}

@test "hype: CODING does NOT call run-senior-executor.sh" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local impl_block
    impl_block=$(sed -n '/CODING)/,/;;/p' "$hype_sh")

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

@test "merge-queue: push failure in try_fast_merge returns 1 (triggers agent)" {
    local merge_sh="$SCRIPTS_DIR/run-merge-queue.sh"

    # v2.3.11: Push failure in try_fast_merge returns 1, agent takes over
    local fast_fn
    fast_fn=$(sed -n '/^try_fast_merge()/,/^}/p' "$merge_sh")

    # Push failure → reset → return 1
    echo "$fast_fn" | grep -q 'push origin.*main_ref'
    echo "$fast_fn" | grep -q 'reset --hard'
    echo "$fast_fn" | grep -q 'return 1'
}

@test "merge-queue: no reject:N increment for infrastructure failures" {
    local merge_sh="$SCRIPTS_DIR/run-merge-queue.sh"

    # v2.3.3: merge queue should NOT use reject:N at all
    # reject:N is for code quality only (reviewers)
    local merge_fn
    merge_fn=$(sed -n '/^merge_task()/,/^}/p' "$merge_sh")
    ! echo "$merge_fn" | grep -q '"reject"'
}

# =============================================================================
# health check: v2.2 scripts included
# =============================================================================

@test "hype: health check includes run-reviewers.sh" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    grep 'required_scripts=' "$hype_sh" | grep -q 'run-reviewers.sh'
}

@test "hype: health check includes run-merge-queue.sh" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    grep 'required_scripts=' "$hype_sh" | grep -q 'run-merge-queue.sh'
}

# =============================================================================
# reviewer timeout: does NOT increment reject:N
# =============================================================================

@test "reviewers: timeout returns to queue without reject increment" {
    local reviewers_sh="$SCRIPTS_DIR/run-reviewers.sh"

    # Timeout handler should exist and return to needs-review
    local timeout_block
    timeout_block=$(sed -n '/exit_code.*-eq 124/,/return 0/p' "$reviewers_sh")

    echo "$timeout_block" | grep -q 'add-label=needs-review'
    echo "$timeout_block" | grep -q 'remove-label=reviewing'
    # Must NOT increment reject:N in timeout block
    ! echo "$timeout_block" | grep -q 'set_counter_label'
}
