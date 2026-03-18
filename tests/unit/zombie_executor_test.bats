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
# GH #35, #34: blocked:* label check in run_coder/run_auditor
# =============================================================================

@test "run_coder: checks blocked:* labels before claiming (GH #35)" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # Extract run_coder function
    local func_block
    func_block=$(sed -n '/^run_coder()/,/^}/p' "$coders_sh")

    # Should check for blocked: labels
    echo "$func_block" | grep -q 'startswith("blocked:")'
    echo "$func_block" | grep -q 'has_blocked.*!=.*"0"'
}

@test "run_auditor: checks blocked:* labels before claiming (GH #35)" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # Extract run_auditor function
    local func_block
    func_block=$(sed -n '/^run_auditor()/,/^}/p' "$coders_sh")

    # Should check for blocked: labels
    echo "$func_block" | grep -q 'startswith("blocked:")'
}

@test "run_coder: blocked check comes before claim (GH #35)" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # blocked check line must come before claim line
    local blocked_line claim_line
    blocked_line=$(grep -n 'has_blocked.*!=.*"0"' "$coders_sh" | head -1 | cut -d: -f1)
    claim_line=$(grep -n 'status=in_progress.*add-label=coder' "$coders_sh" | head -1 | cut -d: -f1)

    [ -n "$blocked_line" ]
    [ -n "$claim_line" ]
    [ "$blocked_line" -lt "$claim_line" ]
}

# =============================================================================
# GH #35, #34: troubleshooter runs before dispatch
# =============================================================================

@test "hype.sh: check_and_route_troubleshoot runs before dispatch_phase (GH #35)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # troubleshoot line must come before dispatch line in main loop
    local troubleshoot_line dispatch_line
    troubleshoot_line=$(grep -n 'Route troubleshoot tasks BEFORE dispatch' "$hype_sh" | head -1 | cut -d: -f1)
    dispatch_line=$(grep -n 'dispatch_phase "\$phase"' "$hype_sh" | head -1 | cut -d: -f1)

    [ -n "$troubleshoot_line" ]
    [ -n "$dispatch_line" ]
    [ "$troubleshoot_line" -lt "$dispatch_line" ]
}

@test "hype.sh: check_problems_and_consult_manager no longer calls troubleshoot (GH #35)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # The function should NOT call check_and_route_troubleshoot anymore
    local func_block
    func_block=$(sed -n '/^check_problems_and_consult_manager()/,/^}/p' "$hype_sh")

    ! echo "$func_block" | grep -q '^    check_and_route_troubleshoot'
}

# =============================================================================
# GH #34: senior.md prohibits status=blocked
# =============================================================================

@test "senior.md: prohibits status=blocked (GH #34)" {
    local senior_md
    # Check both possible locations
    if [ -f "$SCRIPTS_DIR/../agents/senior.md" ]; then
        senior_md="$SCRIPTS_DIR/../agents/senior.md"
    else
        senior_md="$PROJECT_DIR/core/agents/senior.md"
    fi

    grep -qi 'status=blocked' "$senior_md"
    grep -qi 'запрещено\|NEVER\|never.*status.*blocked' "$senior_md"
}

# =============================================================================
# GH #37: retry counter on ALL failures + fresh read
# =============================================================================

@test "run_coder: non-timeout failures increment retry:N (GH #37)" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # The old code had separate branches for exit==124 (retry++) and exit!=124 (no retry)
    # Now both paths should go through the same retry increment block
    # Verify there is only ONE retry increment block (unified), not two separate branches
    local retry_blocks
    retry_blocks=$(grep -c 'add-label="retry:\$new_retry"' "$coders_sh")

    # Should have exactly 2 occurrences (one with remove old label, one without)
    # in a single unified block, not in separate if/else branches
    [ "$retry_blocks" -eq 2 ]
}

@test "run_coder: reads fresh retry count from bd, not stale snapshot (GH #37)" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # The retry reading should use fresh_json (re-read from bd), not task_json (stale snapshot)
    local fail_block
    fail_block=$(sed -n '/exit_code -ne 0/,/return 0/p' "$coders_sh" | head -30)

    echo "$fail_block" | grep -q 'fresh_json.*bd_safe show'
    echo "$fail_block" | grep -q 'echo "\$fresh_json".*retry:'
}

@test "run_coder: unified failure handler for timeout and non-timeout (GH #37)" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # Both timeout (124) and non-timeout should set fail_reason, then share retry code
    local fail_block
    fail_block=$(sed -n '/exit_code -ne 0/,/return 0/p' "$coders_sh" | head -5)

    # Should NOT have nested if/else with separate retry logic
    # The old pattern was: if 124 → retry++; else → no retry
    # New pattern: if 124 → set reason; else → set reason; then → shared retry++
    echo "$fail_block" | grep -q 'fail_reason'
}

# =============================================================================
# GH #36: check_beads stale Dolt lock cleanup
# =============================================================================

@test "check_beads: detects stale dolt-access.lock (GH #36)" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local check_block
    check_block=$(sed -n '/^check_beads()/,/^}/p' "$common_sh")

    echo "$check_block" | grep -q 'dolt-access.lock'
    echo "$check_block" | grep -q 'lock_age.*-gt.*300'
}

@test "check_beads: detects stale Dolt noms LOCK (GH #36)" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local check_block
    check_block=$(sed -n '/^check_beads()/,/^}/p' "$common_sh")

    echo "$check_block" | grep -q 'noms/LOCK'
}

@test "check_beads: retries after stale lock cleanup (GH #36)" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local check_block
    check_block=$(sed -n '/^check_beads()/,/^}/p' "$common_sh")

    # After removing locks, should retry bd list
    echo "$check_block" | grep -q 'recovered after stale lock cleanup'
}

# =============================================================================
# Review "no action" path: re-add needs-review (now tested in reviewers_test.bats)
# =============================================================================
