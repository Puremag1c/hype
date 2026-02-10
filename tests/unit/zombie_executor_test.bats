#!/usr/bin/env bats
# tests/unit/zombie_executor_test.bats
# Unit tests for v2.1.10 zombie executor fix:
# - Executor checks task status before post-execution modifications
# - Prevents zombie executor from reopening closed tasks
# - Review "no action" path re-adds needs-review label

load '../helpers/setup'

# =============================================================================
# run_executor: status guard after claude returns
# =============================================================================

@test "run_executor: checks task status before timeout handling" {
    local executors_sh="$SCRIPTS_DIR/run-executors.sh"

    # The status guard should appear BEFORE the exit_code check
    local guard_line timeout_line
    guard_line=$(grep -n 'already closed.*reviewed during executor' "$executors_sh" | head -1 | cut -d: -f1)
    timeout_line=$(grep -n 'exit_code -ne 0' "$executors_sh" | head -1 | cut -d: -f1)

    [ -n "$guard_line" ]
    [ -n "$timeout_line" ]
    # Guard must come before timeout handling
    [ "$guard_line" -lt "$timeout_line" ]
}

@test "run_executor: guard checks for closed status" {
    local executors_sh="$SCRIPTS_DIR/run-executors.sh"

    # Should check post_status == "closed"
    local guard_block
    guard_block=$(sed -n '/Guard.*already handled/,/return 0/p' "$executors_sh" | head -20)

    echo "$guard_block" | grep -q 'bd_safe show'
    echo "$guard_block" | grep -q '"closed"'
    echo "$guard_block" | grep -q 'return 0'
}

@test "run_executor: guard returns 0 (doesn't modify task)" {
    local executors_sh="$SCRIPTS_DIR/run-executors.sh"

    # The guard block should NOT contain --status=open (which would reopen)
    local guard_block
    guard_block=$(sed -n '/Guard.*already handled.*executor/,/return 0/p' "$executors_sh" | head -10)

    ! echo "$guard_block" | grep -q '\-\-status=open'
}

# =============================================================================
# run_auditor: same status guard
# =============================================================================

@test "run_auditor: checks task status before timeout handling" {
    local executors_sh="$SCRIPTS_DIR/run-executors.sh"

    # Should have guard for auditor too
    grep -q 'already closed.*reviewed during auditor' "$executors_sh"
}

@test "run_auditor: guard uses bd_safe show and checks closed" {
    local executors_sh="$SCRIPTS_DIR/run-executors.sh"

    # Extract the auditor guard block (from "Guard" comment to "return 0")
    # The auditor's guard is the SECOND Guard block in the file
    local guard_block
    guard_block=$(sed -n '/run_claude_with_progress.*AUDIT/,/Auditor timeout/p' "$executors_sh")

    echo "$guard_block" | grep -q 'bd_safe show'
    echo "$guard_block" | grep -q '"closed"'
    echo "$guard_block" | grep -q 'return 0'
}

# =============================================================================
# Scenario test: zombie executor can't reopen closed task
# =============================================================================

@test "scenario: timeout handler has --status=open but guard prevents it on closed tasks" {
    local executors_sh="$SCRIPTS_DIR/run-executors.sh"

    # Verify the timeout handler still uses --status=open (it should, for legitimate timeouts)
    grep -q '\-\-status=open.*remove-label=executor' "$executors_sh"

    # But the guard check comes first (verified in earlier test)
    # This means: closed task → guard returns → timeout handler never runs
}

# =============================================================================
# Review "no action" path: re-add needs-review (now tested in reviewers_test.bats)
# =============================================================================
