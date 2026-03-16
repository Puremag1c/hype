#!/usr/bin/env bats
# tests/unit/audit_escalation_test.bats
# Tests for audit escalation: GH#25 (fork bomb defense) + GH#30 (troubleshooter routing) + GH#31 (race fix)
#
# GH#25: is_audit_task() escalation guard prevents recursive audit routing
# GH#30: 3rd audit failure routes to troubleshooter (not new task creation)
# GH#31: escalation keeps in_progress (no --status=open), AUDIT_TIMEOUT=10m

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
# Layer 2: Audit escalation routes to troubleshooter (GH#30)
# =============================================================================

@test "run-coders.sh: audit escalation uses blocked:troubleshoot" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    local fn_block
    fn_block=$(sed -n '/^run_auditor()/,/^}/p' "$coders_sh")

    # 3rd failure should add blocked:troubleshoot label
    echo "$fn_block" | grep -q 'blocked:troubleshoot'
}

@test "run-coders.sh: audit escalation does not create new tasks" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    local fn_block
    fn_block=$(sed -n '/^run_auditor()/,/^}/p' "$coders_sh")

    # Should NOT have bd_safe create in audit escalation path
    ! echo "$fn_block" | grep -q 'bd_safe create.*Review failed audit'
}

@test "run-coders.sh: audit escalation does not use blocked:escalated" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    local fn_block
    fn_block=$(sed -n '/^run_auditor()/,/^}/p' "$coders_sh")

    # blocked:escalated replaced by blocked:troubleshoot (GH#30)
    ! echo "$fn_block" | grep -q 'blocked:escalated'
}

@test "run-coders.sh: audit escalation does not use blocked:escalation-loop" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    local fn_block
    fn_block=$(sed -n '/^run_auditor()/,/^}/p' "$coders_sh")

    # escalation-loop guard removed — no new task = no recursion risk (GH#30)
    ! echo "$fn_block" | grep -q 'blocked:escalation-loop'
}

@test "run-coders.sh: audit escalation removes coder label" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    local fn_block
    fn_block=$(sed -n '/^run_auditor()/,/^}/p' "$coders_sh")

    # Must remove coder label so task isn't picked up by coders again
    # The bd_safe update call spans multiple lines, so check the whole block
    echo "$fn_block" | grep -q 'remove-label=coder'
    echo "$fn_block" | grep -q 'blocked:troubleshoot'
}

# =============================================================================
# Layer 3: Race condition fix — no --status=open in escalation (GH#31)
# =============================================================================

@test "run-coders.sh: audit escalation does not set --status=open" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    local fn_block
    fn_block=$(sed -n '/^run_auditor()/,/^}/p' "$coders_sh")

    # Extract the escalation bd_safe update (the one with blocked:troubleshoot)
    # It must NOT contain --status=open (race condition fix GH#31)
    local escalation_block
    escalation_block=$(echo "$fn_block" | sed -n '/routing to troubleshooter/,/|| true/p')
    ! echo "$escalation_block" | grep -q '\-\-status=open'
}

@test "run-coders.sh: AUDIT_TIMEOUT defaults to 10m" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # AUDIT_TIMEOUT default must be 10m (not 5m — GH#31)
    grep -q 'AUDIT_TIMEOUT:-10m' "$coders_sh"
}

@test "config template: AUDIT_TIMEOUT setting exists" {
    local config_tpl="$PROJECT_ROOT/templates/config.template.sh"
    [ -f "$config_tpl" ]
    grep -q 'AUDIT_TIMEOUT=' "$config_tpl"
}

@test "architect.md: prohibits per-task verification audits" {
    local architect_md="$PROJECT_ROOT/core/agents/architect.md"

    # Must contain prohibition against per-task audits
    grep -q 'per-task' "$architect_md"
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
