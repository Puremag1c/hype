#!/usr/bin/env bats
# tests/unit/review_labels_test.bats
# Unit tests for v2.2 review label utilities in common.sh

load '../helpers/setup'

# =============================================================================
# claim_for_review
# =============================================================================

@test "claim_for_review: removes needs-review and adds reviewing" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local fn_block
    fn_block=$(sed -n '/^claim_for_review()/,/^}/p' "$common_sh")

    echo "$fn_block" | grep -q '\-\-remove-label=needs-review'
    echo "$fn_block" | grep -q '\-\-add-label=reviewing'
}

# =============================================================================
# approve_task
# =============================================================================

@test "approve_task: removes reviewing and adds approved" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local fn_block
    fn_block=$(sed -n '/^approve_task()/,/^}/p' "$common_sh")

    echo "$fn_block" | grep -q '\-\-remove-label=reviewing'
    echo "$fn_block" | grep -q '\-\-add-label=approved'
}

# =============================================================================
# reject_from_review
# =============================================================================

@test "reject_from_review: removes reviewing, adds needs-review, reopens" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local fn_block
    fn_block=$(sed -n '/^reject_from_review()/,/^}/p' "$common_sh")

    echo "$fn_block" | grep -q '\-\-remove-label=reviewing'
    echo "$fn_block" | grep -q '\-\-add-label=needs-review'
    echo "$fn_block" | grep -q '\-\-status=open'
}

@test "reject_from_review: removes executor label (prevent re-claim)" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local fn_block
    fn_block=$(sed -n '/^reject_from_review()/,/^}/p' "$common_sh")

    echo "$fn_block" | grep -q '\-\-remove-label=executor'
}

# =============================================================================
# All utilities exported
# =============================================================================

@test "review label utilities: all exported" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    grep -q 'export -f claim_for_review' "$common_sh"
    grep -q 'export -f approve_task' "$common_sh"
    grep -q 'export -f reject_from_review' "$common_sh"
}
