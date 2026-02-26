#!/usr/bin/env bats
# tests/unit/audit_escalation_test.bats
# Tests for GH#25: recursive audit escalation fork bomb
#
# Root cause: escalation tasks embed original description with "AUDIT SCOPE" marker
# → is_audit_task() matches → auditor route → timeout → spawns more escalations
# Defense in depth: 3 layers

load '../helpers/setup'

# =============================================================================
# Layer 1: is_audit_task() rejects escalation label (common.sh)
# =============================================================================

@test "is_audit_task: escalation guard exists before audit checks" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local fn_block
    fn_block=$(sed -n '/^is_audit_task()/,/^}/p' "$common_sh")

    # escalation check must come BEFORE audit label check
    local escalation_line audit_line
    escalation_line=$(echo "$fn_block" | grep -n 'escalation' | head -1 | cut -d: -f1)
    audit_line=$(echo "$fn_block" | grep -n '"^audit\$"' | head -1 | cut -d: -f1)

    [ -n "$escalation_line" ]
    [ -n "$audit_line" ]
    [ "$escalation_line" -lt "$audit_line" ]
}

@test "is_audit_task: escalation guard returns 1 (false)" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local fn_block
    fn_block=$(sed -n '/^is_audit_task()/,/^}/p' "$common_sh")

    # The escalation guard should return 1 (not audit)
    echo "$fn_block" | grep -A2 'escalation' | grep -q 'return 1'
}

# =============================================================================
# Layer 2: Description sanitization (run-coders.sh)
# =============================================================================

@test "run-coders.sh: escalation sanitizes AUDIT SCOPE in description" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    local fn_block
    fn_block=$(sed -n '/^run_auditor()/,/^}/p' "$coders_sh")

    # Should have sed replacing AUDIT SCOPE
    echo "$fn_block" | grep -q "sed.*AUDIT SCOPE.*audit scope"
}

@test "run-coders.sh: sanitization is case-insensitive" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    local fn_block
    fn_block=$(sed -n '/^run_auditor()/,/^}/p' "$coders_sh")

    # sed should use /I flag for case-insensitive
    echo "$fn_block" | grep 'AUDIT SCOPE' | grep -q '/gI'
}

# =============================================================================
# Layer 3: Escalation-loop guard (run-coders.sh)
# =============================================================================

@test "run-coders.sh: escalation guard checks existing labels" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    local fn_block
    fn_block=$(sed -n '/^run_auditor()/,/^}/p' "$coders_sh")

    # Should check for escalation label before creating new escalation
    echo "$fn_block" | grep -q 'escalation'
    echo "$fn_block" | grep -q 'escalation-loop'
}

@test "run-coders.sh: escalation-loop blocks task instead of spawning" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    local fn_block
    fn_block=$(sed -n '/^run_auditor()/,/^}/p' "$coders_sh")

    # When escalation detected, should add blocked:escalation-loop label
    echo "$fn_block" | grep -q 'blocked:escalation-loop'
    # And should log SKIP
    echo "$fn_block" | grep -q 'SKIP escalation'
}

# =============================================================================
# Integration: escalation task labels include "escalation"
# =============================================================================

@test "run-coders.sh: escalation task always gets escalation label" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    local fn_block
    fn_block=$(sed -n '/^run_auditor()/,/^}/p' "$coders_sh")

    # The bd_safe create for escalation must include escalation label (may span lines)
    echo "$fn_block" | grep -q 'labels=.*escalation'
}

# =============================================================================
# Integration: no unguarded "AUDIT SCOPE" in escalation descriptions
# =============================================================================

@test "run-coders.sh: no raw AUDIT SCOPE passed to bd_safe create" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    local fn_block
    fn_block=$(sed -n '/^run_auditor()/,/^}/p' "$coders_sh")

    # The $task_desc variable should be sanitized before use in bd_safe create
    # Check that sed sanitization happens BEFORE the bd_safe create call
    local sanitize_line create_line
    sanitize_line=$(echo "$fn_block" | grep -n 'sed.*AUDIT SCOPE' | head -1 | cut -d: -f1)
    create_line=$(echo "$fn_block" | grep -n 'bd_safe create.*Review failed audit' | head -1 | cut -d: -f1)

    [ -n "$sanitize_line" ]
    [ -n "$create_line" ]
    [ "$sanitize_line" -lt "$create_line" ]
}

# =============================================================================
# Layer 4: Audit findings routed to plan-reviewer (run-seniors.sh)
# =============================================================================

@test "run-seniors.sh: AUDIT_REVIEW routes to plan-reviewer (not auto-approve)" {
    local seniors_sh="$SCRIPTS_DIR/run-seniors.sh"

    # Extract AUDIT_REVIEW case block
    local case_block
    case_block=$(sed -n '/AUDIT_REVIEW)/,/;;/p' "$seniors_sh")

    # Should reference plan-reviewer.md
    echo "$case_block" | grep -q 'plan-reviewer.md'
    # Should NOT call approve_task
    ! echo "$case_block" | grep -q 'approve_task'
}

@test "run-seniors.sh: AUDIT_REVIEW passes MODE audit_review" {
    local seniors_sh="$SCRIPTS_DIR/run-seniors.sh"

    local case_block
    case_block=$(sed -n '/AUDIT_REVIEW)/,/;;/p' "$seniors_sh")

    echo "$case_block" | grep -q 'MODE: audit_review'
}

@test "run-seniors.sh: AUDIT_REVIEW passes task notes as Findings" {
    local seniors_sh="$SCRIPTS_DIR/run-seniors.sh"

    local case_block
    case_block=$(sed -n '/AUDIT_REVIEW)/,/;;/p' "$seniors_sh")

    echo "$case_block" | grep -q 'Findings:'
    echo "$case_block" | grep -q 'task_notes'
}

@test "run-seniors.sh: AUDIT_REVIEW calls run_claude_with_progress" {
    local seniors_sh="$SCRIPTS_DIR/run-seniors.sh"

    local case_block
    case_block=$(sed -n '/AUDIT_REVIEW)/,/;;/p' "$seniors_sh")

    echo "$case_block" | grep -q 'run_claude_with_progress'
}

@test "run-seniors.sh: AUDIT_REVIEW handles failure (returns to queue)" {
    local seniors_sh="$SCRIPTS_DIR/run-seniors.sh"

    local case_block
    case_block=$(sed -n '/AUDIT_REVIEW)/,/;;/p' "$seniors_sh")

    # On failure, should add needs-review label to return to queue
    echo "$case_block" | grep -q 'needs-review'
    echo "$case_block" | grep -q 'audit_exit'
}
