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

@test "create_tester_triggers: closes stale triggers before creating new ones" {
    local testers_sh="$SCRIPTS_DIR/run-testers.sh"

    # create_tester_triggers should close old triggers (bd_safe close)
    local fn_body
    fn_body=$(sed -n '/^create_tester_triggers/,/^}/p' "$testers_sh")

    # Must have bd_safe close for stale cleanup
    echo "$fn_body" | grep -q 'bd_safe close.*Stale trigger cleanup'

    # Must always create fresh trigger (unconditional bd_safe create)
    echo "$fn_body" | grep -q 'bd_safe create.*--label=trigger'
}

@test "create_analyst_triggers: closes stale triggers before creating new ones" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # create_analyst_triggers should close old triggers
    local fn_body
    fn_body=$(sed -n '/^create_analyst_triggers/,/^}/p' "$hype_sh")

    # Must have bd_safe close for stale cleanup
    echo "$fn_body" | grep -q 'bd_safe close.*Stale trigger cleanup'

    # Must always create fresh trigger
    echo "$fn_body" | grep -q 'bd_safe create.*--label=trigger'
}
