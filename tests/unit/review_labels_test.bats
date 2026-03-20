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

@test "reject_from_review: removes reviewing and needs-review, reopens (GH #40)" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local fn_block
    fn_block=$(sed -n '/^reject_from_review()/,/^}/p' "$common_sh")

    echo "$fn_block" | grep -q '\-\-remove-label=reviewing'
    echo "$fn_block" | grep -q '\-\-remove-label=needs-review'
    echo "$fn_block" | grep -q '\-\-status=open'
    # Must NOT add needs-review (was the root cause of GH #40 dead zone)
    ! echo "$fn_block" | grep -q '\-\-add-label=needs-review'
}

@test "reject_from_review: removes coder label (prevent re-claim)" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local fn_block
    fn_block=$(sed -n '/^reject_from_review()/,/^}/p' "$common_sh")

    echo "$fn_block" | grep -q '\-\-remove-label=coder'
}

# =============================================================================
# GH #40: Claude rejection cleans review labels
# =============================================================================

@test "run-seniors.sh: Claude rejection removes needs-review+reviewing (GH #40)" {
    local seniors_sh="$SCRIPTS_DIR/run-seniors.sh"
    # The "open" status block (Claude rejected) must remove review labels
    # Find the block: elif [ "$task_status" = "open" ]; then
    local block
    block=$(sed -n '/task_status.*=.*open/,/REJECTED.*reject_count/p' "$seniors_sh")
    echo "$block" | grep -q '\-\-remove-label=needs-review'
    echo "$block" | grep -q '\-\-remove-label=reviewing'
}

@test "heal_stuck_tasks: heals open+needs-review dead zone (GH #40)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"
    local fn_block
    fn_block=$(sed -n '/^heal_stuck_tasks()/,/^}/p' "$hype_sh")
    echo "$fn_block" | grep -q 'open.*needs-review dead zone'
    echo "$fn_block" | grep -q '\-\-remove-label=needs-review'
    echo "$fn_block" | grep -q 'status=open'
}

# =============================================================================
# All utilities exported
# =============================================================================

@test "review label utilities: all exported" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    grep -q 'export -f claim_for_review' "$common_sh"
    grep -q 'export -f approve_task' "$common_sh"
    grep -q 'export -f reject_from_review' "$common_sh"
    grep -q 'export -f try_claim_for_review' "$common_sh"
    grep -q 'export -f release_review_lock' "$common_sh"
}

# =============================================================================
# try_claim_for_review (atomic lock-based claim)
# =============================================================================

@test "try_claim_for_review: uses mkdir for atomic lock" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local fn_block
    fn_block=$(sed -n '/^try_claim_for_review()/,/^}/p' "$common_sh")

    echo "$fn_block" | grep -q 'mkdir'
    echo "$fn_block" | grep -q 'review-.*lock'
}

@test "try_claim_for_review: calls claim_for_review on success" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local fn_block
    fn_block=$(sed -n '/^try_claim_for_review()/,/^}/p' "$common_sh")

    echo "$fn_block" | grep -q 'claim_for_review'
}

@test "try_claim_for_review: releases lock on bd failure" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local fn_block
    fn_block=$(sed -n '/^try_claim_for_review()/,/^}/p' "$common_sh")

    echo "$fn_block" | grep -q 'rmdir'
}

# =============================================================================
# detect-phase.sh: reviewing/approved counts
# =============================================================================

@test "detect-phase: tracks reviewing count" {
    local detect_sh="$SCRIPTS_DIR/detect-phase.sh"

    grep -q 'REVIEWING=' "$detect_sh"
    grep -q '"reviewing"' "$detect_sh"
}

@test "detect-phase: tracks approved count" {
    local detect_sh="$SCRIPTS_DIR/detect-phase.sh"

    grep -q 'APPROVED=' "$detect_sh"
    grep -q '"approved"' "$detect_sh"
}

@test "detect-phase: includes reviewing/approved in JSON output" {
    local detect_sh="$SCRIPTS_DIR/detect-phase.sh"

    grep -q 'reviewing.*REVIEWING' "$detect_sh"
    grep -q 'approved.*APPROVED' "$detect_sh"
}

# =============================================================================
# run-merge-queue.sh: structure tests
# =============================================================================

@test "merge queue: handles audit tasks without merge" {
    local merge_sh="$SCRIPTS_DIR/run-merge-queue.sh"

    grep -q 'is_audit_task' "$merge_sh"
    grep -q 'closing without merge' "$merge_sh"
}

@test "merge queue: handles merge conflicts with agent fallback (v2.3.11)" {
    local merge_sh="$SCRIPTS_DIR/run-merge-queue.sh"

    # v2.3.11: conflict triggers merger agent, not retry counter
    # try_fast_merge returns 1 on rebase failure
    local fast_fn
    fast_fn=$(sed -n '/^try_fast_merge()/,/^}/p' "$merge_sh")
    echo "$fast_fn" | grep -q 'rebase --abort'
    echo "$fast_fn" | grep -q 'return 1'

    # merge_task calls run_merger_agent on fast merge failure
    local merge_fn
    merge_fn=$(sed -n '/^merge_task()/,/^}/p' "$merge_sh")
    echo "$merge_fn" | grep -q 'run_merger_agent'
}

@test "merge queue: verifies main changed after merge" {
    local merge_sh="$SCRIPTS_DIR/run-merge-queue.sh"

    grep -q 'main_before.*main_after' "$merge_sh"
}

@test "merge queue: closes task on empty squash (not infinite loop)" {
    local merge_sh="$SCRIPTS_DIR/run-merge-queue.sh"

    # Empty squash should close the task, not retry
    local empty_block
    empty_block=$(sed -n '/main_before.*=.*main_after/,/return 0/p' "$merge_sh")

    echo "$empty_block" | grep -q 'bd_safe close'
    echo "$empty_block" | grep -q 'add-label=reviewed'
}

@test "merge queue: no troubleshooter escalation for merge conflicts" {
    local merge_sh="$SCRIPTS_DIR/run-merge-queue.sh"

    # v2.3.3: merge conflicts use merge-conflict:N, NOT reject:N
    # No blocked:troubleshoot for infrastructure issues
    ! grep -q 'blocked:troubleshoot' "$merge_sh"
}

@test "merge queue: auto-rebase before merge (v2.2.7)" {
    local merge_sh="$SCRIPTS_DIR/run-merge-queue.sh"

    # Must rebase branch on main before squash merge (v2.3.4: uses git_nh)
    grep -q 'git_nh rebase.*main_ref' "$merge_sh"

    # Must force-push rebased branch
    grep -q 'force-with-lease' "$merge_sh"
}

@test "merge queue: agent failure returns task to coder (v2.3.11)" {
    local merge_sh="$SCRIPTS_DIR/run-merge-queue.sh"

    # v2.3.11: After agent fails, return to coder with notes
    local merge_fn
    merge_fn=$(sed -n '/^merge_task()/,/^}/p' "$merge_sh")

    echo "$merge_fn" | grep -q 'Merger agent failed'
    echo "$merge_fn" | grep -q 'status=open.*remove-label=approved'
}

@test "merge queue: uses --limit 0 for bd list" {
    local merge_sh="$SCRIPTS_DIR/run-merge-queue.sh"

    local missing
    missing=$(grep 'bd_safe list.*--json' "$merge_sh" | grep -cv '\-\-limit 0' || true)
    [ "$missing" -eq 0 ]
}

# =============================================================================
# senior.md: prompt structure
# =============================================================================

@test "reviewer prompt: does NOT contain merge/push instructions (only prohibition)" {
    local reviewer_md="$SCRIPTS_DIR/../agents/senior.md"

    # Should NOT have merge/push as instructions (code blocks)
    ! grep -q '^git merge --squash' "$reviewer_md"
    ! grep -q '^git push origin' "$reviewer_md"
    # But SHOULD have the prohibition rule
    grep -q 'НЕ делай git merge' "$reviewer_md"
}

@test "reviewer prompt: uses approve label (not bd close for approve)" {
    local reviewer_md="$SCRIPTS_DIR/../agents/senior.md"

    grep -q 'add-label=approved' "$reviewer_md"
}
