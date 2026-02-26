#!/usr/bin/env bats
# tests/unit/review_loop_fix_test.bats
# Tests for #21: review-coder loop, missing escalation, ALREADY_MERGED
#
# Bug 1: ALREADY_MERGED detection (branch tip == main tip)
# Bug 2: Model escalation in NO_COMMITS path
# Bug 3: Lost ownership path increments reject:N

load '../helpers/setup'

# =============================================================================
# Bug 1: ALREADY_MERGED detection in preflight_check
# =============================================================================

@test "preflight: detects ALREADY_MERGED (rev-parse comparison)" {
    local reviewers_sh="$SCRIPTS_DIR/run-seniors.sh"

    # preflight_check should compare branch SHA to main SHA
    local fn_block
    fn_block=$(sed -n '/^preflight_check()/,/^}/p' "$reviewers_sh")

    echo "$fn_block" | grep -q 'ALREADY_MERGED'
    echo "$fn_block" | grep -q 'rev-parse.*origin/\$base_branch'
    echo "$fn_block" | grep -q 'rev-parse.*origin/\$branch_name'
}

@test "preflight: ALREADY_MERGED only when main_sha == branch_sha" {
    local reviewers_sh="$SCRIPTS_DIR/run-seniors.sh"

    local fn_block
    fn_block=$(sed -n '/^preflight_check()/,/^}/p' "$reviewers_sh")

    # Should check equality of SHAs
    echo "$fn_block" | grep -q '\$main_sha.*=.*\$branch_sha'
}

@test "preflight: still returns NO_COMMITS when branch differs from main" {
    local reviewers_sh="$SCRIPTS_DIR/run-seniors.sh"

    # NO_COMMITS must still exist as a return value
    local fn_block
    fn_block=$(sed -n '/^preflight_check()/,/^}/p' "$reviewers_sh")

    echo "$fn_block" | grep -q 'echo "NO_COMMITS"'
}

@test "ALREADY_MERGED: case handler closes task (bd_safe close)" {
    local reviewers_sh="$SCRIPTS_DIR/run-seniors.sh"

    local block
    block=$(sed -n '/ALREADY_MERGED)/,/;;/p' "$reviewers_sh")

    echo "$block" | grep -q 'bd_safe close'
    echo "$block" | grep -q 'already merged'
}

@test "ALREADY_MERGED: case handler does NOT call reject_from_review" {
    local reviewers_sh="$SCRIPTS_DIR/run-seniors.sh"

    local block
    block=$(sed -n '/ALREADY_MERGED)/,/;;/p' "$reviewers_sh")

    ! echo "$block" | grep -q 'reject_from_review'
}

@test "ALREADY_MERGED: case handler releases lock and cleans up" {
    local reviewers_sh="$SCRIPTS_DIR/run-seniors.sh"

    local block
    block=$(sed -n '/ALREADY_MERGED)/,/;;/p' "$reviewers_sh")

    echo "$block" | grep -q 'release_review_lock'
    echo "$block" | grep -q 'cleanup_senior_slot'
    echo "$block" | grep -q 'return 0'
}

# =============================================================================
# Bug 2: Model escalation in NO_COMMITS/NO_BRANCH path
# =============================================================================

@test "NO_COMMITS: model escalation at reject >= 2" {
    local reviewers_sh="$SCRIPTS_DIR/run-seniors.sh"

    # The NO_BRANCH|NO_COMMITS case block (from case to ;;) should contain
    # model escalation logic (clean_model_label) in the else branch (reject < 4)
    local block
    block=$(sed -n '/NO_BRANCH|NO_COMMITS)/,/;;/p' "$reviewers_sh")

    echo "$block" | grep -q 'clean_model_label'
    echo "$block" | grep -q 'reject_count.*-ge 2'
}

@test "NO_COMMITS: escalation follows haiku→sonnet→opus ladder" {
    local reviewers_sh="$SCRIPTS_DIR/run-seniors.sh"

    local block
    block=$(sed -n '/NO_BRANCH|NO_COMMITS)/,/;;/p' "$reviewers_sh")

    echo "$block" | grep -q 'haiku.*sonnet'
    echo "$block" | grep -q 'sonnet.*opus'
}

@test "NO_COMMITS: escalation logs with preflight reason" {
    local reviewers_sh="$SCRIPTS_DIR/run-seniors.sh"

    # The ESCALATE log in NO_COMMITS path should include $preflight
    local block
    block=$(sed -n '/NO_BRANCH|NO_COMMITS)/,/;;/p' "$reviewers_sh")

    echo "$block" | grep -q 'ESCALATE.*\$preflight'
}

# =============================================================================
# Bug 3: Lost ownership path increments reject:N
# =============================================================================

@test "lost ownership: increments reject:N" {
    local reviewers_sh="$SCRIPTS_DIR/run-seniors.sh"

    # The "coder label present" block should call set_counter_label
    local block
    block=$(sed -n '/Review lost ownership/,/return 0/p' "$reviewers_sh" | head -30)

    echo "$block" | grep -q 'get_counter_value'
    echo "$block" | grep -q 'set_counter_label.*reject'
}

@test "lost ownership: model escalation at reject >= 2" {
    local reviewers_sh="$SCRIPTS_DIR/run-seniors.sh"

    local block
    block=$(sed -n '/Review lost ownership/,/return 0/p' "$reviewers_sh" | head -30)

    echo "$block" | grep -q 'clean_model_label'
    echo "$block" | grep -q 'reject_count.*-ge 2'
}

@test "lost ownership: escalation follows haiku→sonnet→opus ladder" {
    local reviewers_sh="$SCRIPTS_DIR/run-seniors.sh"

    local block
    block=$(sed -n '/Review lost ownership/,/return 0/p' "$reviewers_sh" | head -30)

    echo "$block" | grep -q 'haiku.*sonnet'
    echo "$block" | grep -q 'sonnet.*opus'
}

@test "lost ownership: still releases lock and returns" {
    local reviewers_sh="$SCRIPTS_DIR/run-seniors.sh"

    local block
    block=$(sed -n '/Review lost ownership/,/return 0/p' "$reviewers_sh" | head -30)

    echo "$block" | grep -q 'release_review_lock'
    echo "$block" | grep -q 'cleanup_senior_slot'
}

# =============================================================================
# Integration: escalation symmetry
# =============================================================================

@test "escalation: all three rejection paths have model escalation" {
    local reviewers_sh="$SCRIPTS_DIR/run-seniors.sh"

    # Count clean_model_label calls — should be at least 5:
    #   1. NO_COMMITS path (fix #2)
    #   2. Claude rejection path (reject >= 2, existing)
    #   3. No-action path (reject >= 2, existing)
    #   4. Lost ownership path (fix #3)
    #   Plus get_review_model uses model label but doesn't call clean_model_label
    local count
    count=$(grep -c 'clean_model_label' "$reviewers_sh")

    # At minimum 4 calls (NO_COMMITS, Claude reject, no-action, lost ownership)
    [ "$count" -ge 4 ]
}

@test "escalation: NO_COMMITS path escalation matches Claude rejection pattern" {
    local reviewers_sh="$SCRIPTS_DIR/run-seniors.sh"

    # Both paths should use the same escalation conditions
    # Claude rejection path (existing):
    local claude_block
    claude_block=$(sed -n '/Rejected.*increment reject/,/REJECTED:/p' "$reviewers_sh")
    echo "$claude_block" | grep -q 'reject_count.*-ge 2'

    # NO_COMMITS path (new):
    local preflight_block
    preflight_block=$(sed -n '/NO_BRANCH|NO_COMMITS)/,/;;/p' "$reviewers_sh")
    echo "$preflight_block" | grep -q 'reject_count.*-ge 2'
}

# =============================================================================
# Fix #22: audit label in agent prompts
# =============================================================================

@test "architect prompt includes --label=audit for verification tasks" {
    grep -q 'label=audit' "$SCRIPTS_DIR/../agents/architect.md"
}

@test "plan-reviewer prompt includes --label=audit for verification tasks" {
    grep -q 'label=audit' "$SCRIPTS_DIR/../agents/plan-reviewer.md"
}
