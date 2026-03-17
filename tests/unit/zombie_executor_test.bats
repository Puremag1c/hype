#!/usr/bin/env bats
# tests/unit/zombie_executor_test.bats (coder zombie tests)
# Unit tests for v2.1.10 zombie coder fix:
# - Executor checks task status before post-execution modifications
# - Prevents zombie coder from reopening closed tasks
# - Review "no action" path re-adds needs-review label

load '../helpers/setup'

# =============================================================================
# run_coder: status guard after claude returns
# =============================================================================

@test "run_coder: checks task status before timeout handling" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # The status guard should appear BEFORE the exit_code check
    local guard_line timeout_line
    guard_line=$(grep -n 'already closed.*reviewed during coder' "$coders_sh" | head -1 | cut -d: -f1)
    timeout_line=$(grep -n 'exit_code -ne 0' "$coders_sh" | head -1 | cut -d: -f1)

    [ -n "$guard_line" ]
    [ -n "$timeout_line" ]
    # Guard must come before timeout handling
    [ "$guard_line" -lt "$timeout_line" ]
}

@test "run_coder: guard checks for closed status" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # Should check post_status == "closed"
    local guard_block
    guard_block=$(sed -n '/Guard.*already handled/,/return 0/p' "$coders_sh" | head -20)

    echo "$guard_block" | grep -q 'bd_safe show'
    echo "$guard_block" | grep -q '"closed"'
    echo "$guard_block" | grep -q 'return 0'
}

@test "run_coder: guard returns 0 (doesn't modify task)" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # The guard block should NOT contain --status=open (which would reopen)
    local guard_block
    guard_block=$(sed -n '/Guard.*already handled.*coder/,/return 0/p' "$coders_sh" | head -10)

    ! echo "$guard_block" | grep -q '\-\-status=open'
}

# =============================================================================
# run_auditor: same status guard
# =============================================================================

@test "run_auditor: checks task status before timeout handling" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # Should have guard for auditor too
    grep -q 'already closed.*reviewed during auditor' "$coders_sh"
}

@test "run_auditor: guard uses bd_safe show and checks closed" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # Extract the auditor guard block (from "Guard" comment to "return 0")
    # The auditor's guard is the SECOND Guard block in the file
    local guard_block
    guard_block=$(sed -n '/run_claude_with_progress.*AUDIT/,/Auditor timeout/p' "$coders_sh")

    echo "$guard_block" | grep -q 'bd_safe show'
    echo "$guard_block" | grep -q '"closed"'
    echo "$guard_block" | grep -q 'return 0'
}

# =============================================================================
# Scenario test: zombie coder can't reopen closed task
# =============================================================================

@test "scenario: timeout handler has --status=open but guard prevents it on closed tasks" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # Verify the timeout handler still uses --status=open (it should, for legitimate timeouts)
    grep -q '\-\-status=open.*remove-label=coder' "$coders_sh"

    # But the guard check comes first (verified in earlier test)
    # This means: closed task → guard returns → timeout handler never runs
}

# =============================================================================
# GH #32: PID tracking for zombie coder kill
# =============================================================================

@test "run-coders.sh: writes PID file after launching coder" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # PID file should be written after background launch
    grep -q 'echo "\$!" > "\$WORKTREES_DIR/task-\$task_id.pid"' "$coders_sh"
}

@test "run-coders.sh: writes PID file after launching auditor" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # Auditor also gets PID file
    grep -A2 'run_auditor' "$coders_sh" | grep -q 'task-\$task_id.pid'
}

@test "run-coders.sh: cleans up PID file on normal coder exit" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # PID file cleanup inside subshell (rm after run_coder returns)
    grep -q 'run_coder.*rm -f.*task-\$task_id.pid' "$coders_sh"
}

@test "run-coders.sh: cleans up PID file on normal auditor exit" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # PID file cleanup inside subshell (rm after run_auditor returns)
    grep -q 'run_auditor.*rm -f.*task-\$task_id.pid' "$coders_sh"
}

@test "reset_stale_tasks: kills zombie process via PID file (GH #32)" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    # Should read PID from file and kill before resetting
    local kill_block
    kill_block=$(sed -n '/Kill zombie coder/,/rm -f.*pid_file/p' "$common_sh")

    echo "$kill_block" | grep -q 'cat "\$pid_file"'
    echo "$kill_block" | grep -q 'kill "\$old_pid"'
    echo "$kill_block" | grep -q 'rm -f "\$pid_file"'
}

# =============================================================================
# Review "no action" path: re-add needs-review (now tested in reviewers_test.bats)
# =============================================================================
