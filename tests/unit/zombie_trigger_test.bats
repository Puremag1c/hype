#!/usr/bin/env bats
# tests/unit/zombie_trigger_test.bats
# Unit tests for v2.1.9 zombie trigger fix:
# - Tester triggers closed on timeout/failure (not reopened)
# - All bd_safe list --json calls use --limit 0

load '../helpers/setup'

# =============================================================================
# Tester triggers: close on timeout/failure
# =============================================================================

@test "run_tester: timeout closes trigger (bd_safe close, not update --status=open)" {
    local testers_sh="$SCRIPTS_DIR/run-testers.sh"

    # The timeout block (exit_code 124) should use bd_safe close
    local timeout_block
    timeout_block=$(sed -n '/exit_code -eq 124/,/;;/p' "$testers_sh")

    echo "$timeout_block" | grep -q 'bd_safe close'
    ! echo "$timeout_block" | grep -q '\-\-status=open'
}

@test "run_tester: failure closes trigger (bd_safe close, not update --status=open)" {
    local testers_sh="$SCRIPTS_DIR/run-testers.sh"

    # The failure block (else after exit_code 124) should use bd_safe close
    local failure_section
    failure_section=$(sed -n '/exit_code -ne 0/,/return 0/p' "$testers_sh")

    # Should have bd_safe close (2 instances: timeout + failure)
    local close_count
    close_count=$(echo "$failure_section" | grep -c 'bd_safe close' || true)
    [ "$close_count" -ge 2 ]

    # Should NOT have --status=open in the failure handler
    ! echo "$failure_section" | grep -q '\-\-status=open'
}

@test "run_tester: clears trap after timeout/failure to prevent double-close" {
    local testers_sh="$SCRIPTS_DIR/run-testers.sh"

    # After closing trigger on failure, should clear trap
    local failure_section
    failure_section=$(sed -n '/exit_code -ne 0/,/return 0/p' "$testers_sh")

    echo "$failure_section" | grep -q 'trap - EXIT INT TERM'
    echo "$failure_section" | grep -q 'task_id=""'
}

# =============================================================================
# --limit 0: all bd_safe list --json calls use unlimited
# =============================================================================

@test "run-testers.sh: all bd_safe list calls use --limit 0" {
    local testers_sh="$SCRIPTS_DIR/run-testers.sh"

    # Every bd_safe list --json should have --limit 0
    local missing
    missing=$(grep 'bd_safe list.*--json' "$testers_sh" | grep -cv '\-\-limit 0' || true)
    [ "$missing" -eq 0 ]
}

@test "run-analysts.sh: all bd_safe list calls use --limit 0" {
    local analysts_sh="$SCRIPTS_DIR/run-analysts.sh"

    local missing
    missing=$(grep 'bd_safe list.*--json' "$analysts_sh" | grep -cv '\-\-limit 0' || true)
    [ "$missing" -eq 0 ]
}

@test "hype.sh: all bd_safe list calls use --limit 0" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local missing
    missing=$(grep 'bd_safe list.*--json' "$hype_sh" | grep -cv '\-\-limit 0' || true)
    [ "$missing" -eq 0 ]
}

@test "common.sh: all bd_safe list calls use --limit 0" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local missing
    missing=$(grep 'bd_safe list.*--json' "$common_sh" | grep -cv '\-\-limit 0' || true)
    [ "$missing" -eq 0 ]
}

@test "detect-phase.sh: all bd_safe list calls use --limit 0" {
    local detect_sh="$SCRIPTS_DIR/detect-phase.sh"

    local missing
    missing=$(grep 'bd_safe list.*--json' "$detect_sh" | grep -cv '\-\-limit 0' || true)
    [ "$missing" -eq 0 ]
}

# =============================================================================
# Stale trigger cleanup: close old triggers before creating new ones (v2.2.3)
# =============================================================================

@test "create_tester_triggers: cleans stale triggers via cleanup_stale_trigger" {
    local testers_sh="$SCRIPTS_DIR/run-testers.sh"

    local fn_body
    fn_body=$(sed -n '/^create_tester_triggers/,/^}/p' "$testers_sh")

    # Must call cleanup_stale_trigger before creating
    echo "$fn_body" | grep -q 'cleanup_stale_trigger'

    # Must always create fresh trigger (unconditional bd_safe create)
    echo "$fn_body" | grep -q 'bd_safe create.*--label=trigger'
}

@test "create_analyst_triggers: cleans stale triggers via cleanup_stale_trigger" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local fn_body
    fn_body=$(sed -n '/^create_analyst_triggers/,/^}/p' "$hype_sh")

    # Must call cleanup_stale_trigger before creating
    echo "$fn_body" | grep -q 'cleanup_stale_trigger'

    # Must always create fresh trigger
    echo "$fn_body" | grep -q 'bd_safe create.*--label=trigger'
}

@test "cleanup_stale_trigger: defined in common.sh and exported" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    grep -q 'cleanup_stale_trigger()' "$common_sh"
    grep -q 'export -f cleanup_stale_trigger' "$common_sh"
}

@test "hype.sh: inline triggers use cleanup_stale_trigger" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # All inline trigger creation points should call cleanup first
    grep -q 'cleanup_stale_trigger "run-plan-review"' "$hype_sh"
    grep -q 'cleanup_stale_trigger "run-smoke-review"' "$hype_sh"
    grep -q 'cleanup_stale_trigger "run-versioning"' "$hype_sh"
}

@test "run-reviewers.sh: for loop glob does not have inline 2>/dev/null" {
    local reviewers_sh="$SCRIPTS_DIR/run-reviewers.sh"

    # The 2>/dev/null must be on 'done', not in 'for ... in ...' word list
    ! grep -q 'for .* in .*\*.*2>/dev/null; do' "$reviewers_sh"
}

@test "hype.sh: FINAL_REVIEW PASSED checks for new open tasks" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # After grep PASSED, must check for open tasks before setting success
    local passed_block
    passed_block=$(sed -n '/FINAL_REVIEW: PASSED/,/final_review_success=true/p' "$hype_sh")

    echo "$passed_block" | grep -q 'bd_safe list.*--status=open'
    echo "$passed_block" | grep -q 'NEEDS_FIXES'
}

@test "architect-qa.md: final_review bugs do NOT get smoke label" {
    local qa_md="$SCRIPTS_DIR/../agents/architect-qa.md"

    # The bug creation template in final_review section should NOT have --label=smoke
    local final_review_section
    final_review_section=$(sed -n '/## MODE: final_review/,/## MODE: smoke_review/p' "$qa_md")

    # The bd create template should not include --label=smoke
    ! echo "$final_review_section" | grep 'bd create.*--label=smoke'
}

# =============================================================================
# Phase machine: triggers excluded from OPEN/IN_PROGRESS counts (v2.2.5)
# =============================================================================

@test "detect-phase.sh: OPEN excludes trigger-labeled tasks" {
    local detect_sh="$SCRIPTS_DIR/detect-phase.sh"

    # The OPEN= line must filter out trigger labels
    local open_line
    open_line=$(grep '^OPEN=' "$detect_sh")

    echo "$open_line" | grep -q 'index("trigger") | not'
}

@test "detect-phase.sh: IN_PROGRESS excludes trigger-labeled tasks" {
    local detect_sh="$SCRIPTS_DIR/detect-phase.sh"

    # The IN_PROGRESS= line must filter out trigger labels
    local ip_line
    ip_line=$(grep '^IN_PROGRESS=' "$detect_sh")

    echo "$ip_line" | grep -q 'index("trigger") | not'
}

@test "hype.sh: startup closes orphaned triggers" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Must have orphaned trigger cleanup block before main loop
    local cleanup_block
    cleanup_block=$(sed -n '/orphaned triggers/,/^$/p' "$hype_sh")

    # Must use bd_safe list with --limit 0
    echo "$cleanup_block" | grep -q 'bd_safe list.*--limit 0'

    # Must filter for trigger label
    echo "$cleanup_block" | grep -q 'index("trigger")'

    # Must close with reason
    echo "$cleanup_block" | grep -q 'bd_safe close.*--reason'
}

@test "hype.sh: startup cleans stale testers PID file" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Startup must remove stale PID file before main loop
    grep -q 'rm -f.*run-testers.pid' "$hype_sh"
}

# =============================================================================
# Async SMOKE_TEST: non-blocking testers (v2.2.6)
# =============================================================================

@test "hype.sh: SMOKE_TEST launches testers in background" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # run-testers.sh must be launched with & (background)
    local smoke_block
    smoke_block=$(sed -n '/SMOKE_TEST)/,/;;/p' "$hype_sh")

    echo "$smoke_block" | grep -q './scripts/run-testers.sh &'
}

@test "hype.sh: SMOKE_TEST uses PID file for state tracking" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local smoke_block
    smoke_block=$(sed -n '/SMOKE_TEST)/,/;;/p' "$hype_sh")

    # Must write PID file
    echo "$smoke_block" | grep -q 'run-testers.pid'

    # Must check if process alive (kill -0)
    echo "$smoke_block" | grep -q 'kill -0'
}

@test "hype.sh: SMOKE_TEST does NOT call run-testers.sh synchronously" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local smoke_block
    smoke_block=$(sed -n '/SMOKE_TEST)/,/;;/p' "$hype_sh")

    # Must NOT have synchronous call (without &)
    # All ./scripts/run-testers.sh calls must end with &
    local sync_calls
    sync_calls=$(echo "$smoke_block" | grep './scripts/run-testers.sh' | grep -cv '&$' || true)
    [ "$sync_calls" -eq 0 ]
}

# =============================================================================
# Shared check_beads: common.sh exports daemon health check (v2.2.8)
# =============================================================================

@test "common.sh: check_beads defined and exported" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    grep -q 'check_beads()' "$common_sh"
    grep -q 'export -f check_beads' "$common_sh"
}

@test "common.sh: hard_kill_beads_daemon defined and exported" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    grep -q 'hard_kill_beads_daemon()' "$common_sh"
    grep -q 'export -f hard_kill_beads_daemon' "$common_sh"
}

@test "hype.sh: does NOT define check_beads locally (uses common.sh)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Should NOT have check_beads() function definition
    ! grep -q '^check_beads()' "$hype_sh"
    ! grep -q '^hard_kill_beads_daemon()' "$hype_sh"
}

@test "doctor.sh: uses check_beads from common.sh (not inline daemon check)" {
    local doctor_sh="$SCRIPTS_DIR/doctor.sh"

    # Must call check_beads
    grep -q 'check_beads' "$doctor_sh"

    # Must NOT have inline hard kill logic (old pattern)
    ! grep -q 'kill -9.*pid' "$doctor_sh"
    ! grep -q 'daemon.pid' "$doctor_sh"
}

@test "hype.sh: check_beads failure retries instead of exit" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Main loop must NOT exit on check_beads failure
    local beads_block
    beads_block=$(sed -n '/check_beads/,/beads_fail_streak=0/p' "$hype_sh")

    # Must have retry with continue (not exit)
    echo "$beads_block" | grep -q 'continue'

    # Must NOT have exit 1 after check_beads failure
    ! echo "$beads_block" | grep -q 'exit 1'

    # Must track failure streak
    echo "$beads_block" | grep -q 'beads_fail_streak'
}
