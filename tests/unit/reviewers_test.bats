#!/usr/bin/env bats
# tests/unit/reviewers_test.bats
# Unit tests for v2.2 run-reviewers.sh

load '../helpers/setup'

# =============================================================================
# Structure: slot management
# =============================================================================

@test "reviewers: lock-based slot management (reviewer-N.lock)" {
    local reviewers_sh="$SCRIPTS_DIR/run-reviewers.sh"

    grep -q 'reviewer-.*\.lock' "$reviewers_sh"
    grep -q 'count_active_reviewers' "$reviewers_sh"
    grep -q 'find_free_reviewer_slot' "$reviewers_sh"
}

@test "reviewers: stale lock cleanup" {
    local reviewers_sh="$SCRIPTS_DIR/run-reviewers.sh"

    local fn_block
    fn_block=$(sed -n '/^find_free_reviewer_slot()/,/^}/p' "$reviewers_sh")

    echo "$fn_block" | grep -q 'lock_age'
    echo "$fn_block" | grep -q 'rmdir'
}

# =============================================================================
# Structure: review flow
# =============================================================================

@test "reviewers: uses try_claim_for_review for atomic claim" {
    local reviewers_sh="$SCRIPTS_DIR/run-reviewers.sh"

    grep -q 'try_claim_for_review' "$reviewers_sh"
}

@test "reviewers: runs preflight check before review" {
    local reviewers_sh="$SCRIPTS_DIR/run-reviewers.sh"

    grep -q 'preflight_check' "$reviewers_sh"
    grep -q 'NO_BRANCH' "$reviewers_sh"
    grep -q 'NO_COMMITS' "$reviewers_sh"
}

@test "reviewers: builds review context with diff, commits, logs" {
    local reviewers_sh="$SCRIPTS_DIR/run-reviewers.sh"

    local fn_block
    fn_block=$(sed -n '/^build_review_context()/,/^}/p' "$reviewers_sh")

    echo "$fn_block" | grep -q 'git log.*oneline'
    echo "$fn_block" | grep -q 'git diff'
    echo "$fn_block" | grep -q 'executor_log'
}

@test "reviewers: includes secrets-warning in context (v2.1.8 compat)" {
    local reviewers_sh="$SCRIPTS_DIR/run-reviewers.sh"

    grep -q 'secrets-warning' "$reviewers_sh"
    grep -q 'SECURITY WARNING' "$reviewers_sh"
}

@test "reviewers: uses run_claude_with_progress" {
    local reviewers_sh="$SCRIPTS_DIR/run-reviewers.sh"

    grep -q 'run_claude_with_progress' "$reviewers_sh"
}

# =============================================================================
# Post-review: escalation ladder
# =============================================================================

@test "reviewers: handles approved result" {
    local reviewers_sh="$SCRIPTS_DIR/run-reviewers.sh"

    grep -q 'has_approved' "$reviewers_sh"
    grep -q 'APPROVED:' "$reviewers_sh"
}

@test "reviewers: handles rejection with reject:N increment" {
    local reviewers_sh="$SCRIPTS_DIR/run-reviewers.sh"

    grep -q 'set_counter_label.*reject' "$reviewers_sh"
    grep -q 'REJECTED:' "$reviewers_sh"
}

@test "reviewers: escalates to troubleshooter at reject:4" {
    local reviewers_sh="$SCRIPTS_DIR/run-reviewers.sh"

    grep -q 'blocked:troubleshoot' "$reviewers_sh"
}

@test "reviewers: model escalation at reject:2+" {
    local reviewers_sh="$SCRIPTS_DIR/run-reviewers.sh"

    grep -q 'clean_model_label' "$reviewers_sh"
}

@test "reviewers: re-adds needs-review on no-action (v2.1.10 compat)" {
    local reviewers_sh="$SCRIPTS_DIR/run-reviewers.sh"

    # The "no action" path should re-add needs-review
    local no_action_block
    no_action_block=$(sed -n '/No action.*reviewer/,/fi$/p' "$reviewers_sh" || true)

    grep -q 'add-label=needs-review' "$reviewers_sh"
}

# =============================================================================
# Backpressure and --limit 0
# =============================================================================

@test "reviewers: respects MAX_PARALLEL_REVIEWERS" {
    local reviewers_sh="$SCRIPTS_DIR/run-reviewers.sh"

    grep -q 'MAX_PARALLEL_REVIEWERS' "$reviewers_sh"
}

@test "reviewers: uses --limit 0 for bd list" {
    local reviewers_sh="$SCRIPTS_DIR/run-reviewers.sh"

    local missing
    missing=$(grep 'bd_safe list.*--json' "$reviewers_sh" | grep -cv '\-\-limit 0' || true)
    [ "$missing" -eq 0 ]
}

@test "reviewers: releases lock on all exit paths" {
    local reviewers_sh="$SCRIPTS_DIR/run-reviewers.sh"

    # Trap for cleanup
    grep -q 'trap.*release_review_lock' "$reviewers_sh"
    # Explicit cleanup in preflight failure
    grep -q 'release_review_lock.*cleanup_reviewer_slot' "$reviewers_sh"
}
