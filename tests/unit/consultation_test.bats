#!/usr/bin/env bats
# tests/unit/consultation_test.bats
# Pattern tests for CONSULTATION redesign (GH #27)

load '../helpers/setup'

# =============================================================================
# CONSULTATION uses interactive agent (not batch claude --print)
# =============================================================================

@test "CONSULTATION: uses run_interactive_agent (not claude --print)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Extract CONSULTATION case block
    local case_block
    case_block=$(sed -n '/^        CONSULTATION)/,/;;$/p' "$hype_sh")

    # Must use run_interactive_agent
    echo "$case_block" | grep -q 'run_interactive_agent'

    # Must NOT use claude --print
    ! echo "$case_block" | grep -q 'claude --print'
}

@test "CONSULTATION: does not return 0 (loop continues)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Extract CONSULTATION case block
    local case_block
    case_block=$(sed -n '/^        CONSULTATION)/,/;;$/p' "$hype_sh")

    # Must NOT have bare 'return 0' that stops the loop
    # (run_interactive_agent returning is fine, the case just ends with ;;)
    ! echo "$case_block" | grep -qE '^\s+return 0\s*$'
}

@test "CONSULTATION: passes escalated task IDs to agent" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Extract CONSULTATION case block
    local case_block
    case_block=$(sed -n '/^        CONSULTATION)/,/;;$/p' "$hype_sh")

    # Must extract user-escalation task IDs from tick-cache
    echo "$case_block" | grep -q 'user-escalation'

    # Must pass them to run_interactive_agent
    echo "$case_block" | grep -q 'ESCALATED_TASKS'
}

@test "CONSULTATION: uses opus model (not sonnet)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Extract CONSULTATION case block
    local case_block
    case_block=$(sed -n '/^        CONSULTATION)/,/;;$/p' "$hype_sh")

    # Default model should be opus for consultation
    echo "$case_block" | grep -q 'opus'
}

@test "CONSULTATION: handles manager failure gracefully" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Extract CONSULTATION case block
    local case_block
    case_block=$(sed -n '/^        CONSULTATION)/,/;;$/p' "$hype_sh")

    # Must have error handling (! run_interactive_agent pattern)
    echo "$case_block" | grep -q 'Manager exited with error'
}

# =============================================================================
# run_interactive_agent supports extra context and agent-specific tools
# =============================================================================

@test "run_interactive_agent: accepts optional extra_context parameter" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Extract run_interactive_agent function
    local func_block
    func_block=$(sed -n '/^run_interactive_agent/,/^}/p' "$hype_sh")

    # Must have extra_context parameter
    echo "$func_block" | grep -q 'extra_context'
}

@test "run_interactive_agent: manager-review gets bd access in allowedTools" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Extract run_interactive_agent function
    local func_block
    func_block=$(sed -n '/^run_interactive_agent/,/^}/p' "$hype_sh")

    # Must have manager-review specific tools
    echo "$func_block" | grep -q 'manager-review'
    echo "$func_block" | grep -q 'bd show'
    echo "$func_block" | grep -q 'bd close'
    echo "$func_block" | grep -q 'bd update'
}

@test "run_interactive_agent: default agents do NOT get bd access" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Extract run_interactive_agent function
    local func_block
    func_block=$(sed -n '/^run_interactive_agent/,/^}/p' "$hype_sh")

    # Default (else) branch must have Write but not bd
    # Check that bd commands are only in the manager-review branch
    local default_branch
    default_branch=$(echo "$func_block" | sed -n '/else/,/fi/p')
    ! echo "$default_branch" | grep -q 'bd show'
}

# =============================================================================
# manager-review.md agent prompt
# =============================================================================

@test "manager-review.md: is interactive consultation agent (not batch report)" {
    local agent_file="$SCRIPTS_DIR/../agents/manager-review.md"

    # Must NOT reference evidence/user-review-report.md (old batch output)
    ! grep -q 'user-review-report.md' "$agent_file"

    # Must have interactive dialogue instructions
    grep -q 'dialogue\|dialog\|DIALOGUE' "$agent_file"
}

@test "manager-review.md: removes user-escalation label" {
    local agent_file="$SCRIPTS_DIR/../agents/manager-review.md"

    grep -q 'remove-label=user-escalation' "$agent_file"
}

@test "manager-review.md: removes blocked:troubleshoot label" {
    local agent_file="$SCRIPTS_DIR/../agents/manager-review.md"

    grep -q 'remove-label=blocked:troubleshoot' "$agent_file"
}

@test "manager-review.md: writes consultation result to notes" {
    local agent_file="$SCRIPTS_DIR/../agents/manager-review.md"

    grep -q 'CONSULTATION RESULT' "$agent_file"
}

@test "manager-review.md: does not create tasks" {
    local agent_file="$SCRIPTS_DIR/../agents/manager-review.md"

    # Must explicitly say not to create tasks
    grep -qi 'not.*create.*task\|do not.*create' "$agent_file"

    # Must NOT have bd create in commands
    ! grep -q 'bd create' "$agent_file"
}

@test "manager-review.md: does not show bd commands to user" {
    local agent_file="$SCRIPTS_DIR/../agents/manager-review.md"

    grep -qi 'not.*show.*bd.*command\|not.*mention.*bd' "$agent_file"
}
