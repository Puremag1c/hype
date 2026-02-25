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

@test "hype.sh: all bd_safe query --json calls use --limit 0" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local missing
    missing=$(grep 'bd_safe query.*--json' "$hype_sh" | grep -cv '\-\-limit 0' || true)
    [ "$missing" -eq 0 ]
}

@test "common.sh: all bd_safe query --json calls use --limit 0" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local missing
    missing=$(grep 'bd_safe query.*--json' "$common_sh" | grep -cv '\-\-limit 0' || true)
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
    grep -q 'cleanup_stale_trigger "run-completion"' "$hype_sh"
}

@test "run-seniors.sh: for loop glob does not have inline 2>/dev/null" {
    local reviewers_sh="$SCRIPTS_DIR/run-seniors.sh"

    # The 2>/dev/null must be on 'done', not in 'for ... in ...' word list
    ! grep -q 'for .* in .*\*.*2>/dev/null; do' "$reviewers_sh"
}

@test "hype.sh: VALIDATING PASSED checks for new open tasks" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # After grep PASSED, must check for open tasks before setting success
    local passed_block
    passed_block=$(sed -n '/VALIDATING: PASSED/,/final_review_success=true/p' "$hype_sh")

    echo "$passed_block" | grep -q 'bd_safe query.*status=open'
    echo "$passed_block" | grep -q 'NEEDS_FIXES'
}

@test "qa.md: final_review bugs do NOT get smoke label" {
    local qa_md="$SCRIPTS_DIR/../agents/qa.md"

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

    # Must use bd_safe query for trigger label (server-side filter)
    echo "$cleanup_block" | grep -q 'bd_safe query.*trigger'

    # Must close with reason
    echo "$cleanup_block" | grep -q 'bd_safe close.*--reason'
}

@test "hype.sh: startup cleans stale testers PID file" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Startup must remove stale PID file before main loop
    grep -q 'rm -f.*run-testers.pid' "$hype_sh"
}

@test "hype.sh: REFLEXING cleans testers PID file (v2.3.5)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # REFLEXING must remove PID file — testers are done when this phase starts.
    # Without cleanup, stale PID persists through CODING and causes
    # TESTING STATE 3 to skip actual test launch on next round.
    local smoke_review_block
    smoke_review_block=$(sed -n '/REFLEXING)/,/;;/p' "$hype_sh")

    echo "$smoke_review_block" | grep -q 'rm -f.*run-testers.pid'
}

@test "hype.sh: CODING cleans stale testers PID file (v2.3.21)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # CODING must remove PID file — covers TESTING→IMPL→TESTING path
    # that bypasses REFLEXING (v2.3.5 only covers the REFLEXING path)
    local impl_block
    impl_block=$(sed -n '/CODING)/,/;;/p' "$hype_sh")

    echo "$impl_block" | grep -q 'rm -f.*run-testers.pid'
}

# =============================================================================
# Async TESTING: non-blocking testers (v2.2.6)
# =============================================================================

@test "hype.sh: TESTING launches testers in background" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # run-testers.sh must be launched with & (background)
    local smoke_block
    smoke_block=$(sed -n '/TESTING)/,/;;/p' "$hype_sh")

    echo "$smoke_block" | grep -q './scripts/run-testers.sh &'
}

@test "hype.sh: TESTING uses PID file for state tracking" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local smoke_block
    smoke_block=$(sed -n '/TESTING)/,/;;/p' "$hype_sh")

    # Must write PID file
    echo "$smoke_block" | grep -q 'run-testers.pid'

    # Must check if process alive (kill -0)
    echo "$smoke_block" | grep -q 'kill -0'
}

@test "hype.sh: TESTING does NOT call run-testers.sh synchronously" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local smoke_block
    smoke_block=$(sed -n '/TESTING)/,/;;/p' "$hype_sh")

    # Must NOT have synchronous call (without &)
    # All ./scripts/run-testers.sh calls must end with &
    local sync_calls
    sync_calls=$(echo "$smoke_block" | grep './scripts/run-testers.sh' | grep -cv '&$' || true)
    [ "$sync_calls" -eq 0 ]
}

# =============================================================================
# Shared check_beads: Dolt backend health check (v2.5, daemon removed v0.50)
# =============================================================================

@test "common.sh: check_beads defined and exported" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    grep -q 'check_beads()' "$common_sh"
    grep -q 'export -f check_beads' "$common_sh"
}

@test "common.sh: check_beads uses bd list probe (no daemon)" {
    local common_sh="$SCRIPTS_DIR/common.sh"
    local body
    body=$(sed -n '/^check_beads()/,/^}/p' "$common_sh")

    echo "$body" | grep -q 'bd list --limit 1'
    ! echo "$body" | grep -q 'bd daemon'
}

@test "common.sh: no hard_kill_beads_daemon (daemon removed v0.50)" {
    local common_sh="$SCRIPTS_DIR/common.sh"
    ! grep -q '^hard_kill_beads_daemon()' "$common_sh"
}

@test "hype.sh: does NOT define check_beads locally (uses common.sh)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    ! grep -q '^check_beads()' "$hype_sh"
}

@test "doctor.sh: uses check_beads from common.sh" {
    local doctor_sh="$SCRIPTS_DIR/doctor.sh"

    grep -q 'check_beads' "$doctor_sh"
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

# =============================================================================
# set -e resilience: scripts don't kill HYPE on bd failure (v2.2.8)
# =============================================================================

@test "hype.sh: CODING script calls protected with || log" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local impl_block
    impl_block=$(sed -n '/CODING)/,/;;/p' "$hype_sh")

    # All three scripts must have || log protection
    echo "$impl_block" | grep 'run-coders.sh' | grep -q '|| log'
    echo "$impl_block" | grep 'run-seniors.sh' | grep -q '|| log'
    echo "$impl_block" | grep 'run-merge-queue.sh' | grep -q '|| log'
}

@test "hype.sh: ANALYZE script call protected with || log" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local helpers_block
    helpers_block=$(sed -n '/ANALYZE)/,/;;/p' "$hype_sh")

    echo "$helpers_block" | grep 'run-analysts.sh' | grep -q '|| log'
}

@test "hype.sh: EXIT trap logs unexpected exit" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Must have exit handler that logs unexpected exits
    grep -q '_hype_exit_handler' "$hype_sh"
    grep -q 'exited unexpectedly' "$hype_sh"
}

# =============================================================================
# ANALYZE loop fix: trigger close retry + recovery + status filter (v2.4.5)
# =============================================================================

@test "run-analysts.sh: trigger close checks return code (not silent)" {
    local analysts_sh="$SCRIPTS_DIR/run-analysts.sh"

    # Close trigger must check return code (if bd_safe close ...)
    local close_block
    close_block=$(sed -n '/Close trigger task/,/^}/p' "$analysts_sh")

    # Must use if/then pattern, not bare bd_safe close >/dev/null
    echo "$close_block" | grep -q 'if bd_safe close'

    # Must have retry on failure
    echo "$close_block" | grep -q 'retrying'
}

@test "run-analysts.sh: trigger select filters by status=open" {
    local analysts_sh="$SCRIPTS_DIR/run-analysts.sh"

    # jq select must filter by status == "open" to avoid stale duplicates
    grep 'select(.title ==' "$analysts_sh" | grep -q 'select(.status == \\"open\\")'
}

# =============================================================================
# cleanup_iteration: bd_safe everywhere, no direct bd calls (v2.4.5)
# =============================================================================

@test "cleanup_iteration: uses bd_safe for remaining count (not direct bd)" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    # Extract cleanup retry loop
    local cleanup_block
    cleanup_block=$(sed -n '/Run cleanup with retry/,/fi$/p' "$common_sh" | head -30)

    # remaining= must use bd_safe, not bare bd
    echo "$cleanup_block" | grep 'remaining=' | grep -q 'bd_safe count'
}

@test "cleanup_iteration: fallback delete uses bd_safe (not direct bd)" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    # Extract fallback delete block
    local fallback_block
    fallback_block=$(sed -n '/Fallback.*cleanup missed/,/fi$/p' "$common_sh" | head -20)

    # Must use bd_safe delete, not bare bd delete
    echo "$fallback_block" | grep 'delete' | grep -v '^#' | grep -q 'bd_safe'

    # Must NOT have bare 'bd delete' (without _safe)
    ! echo "$fallback_block" | grep -v '^#' | grep -E '^\s+bd delete'
}

@test "cleanup_iteration: final verification after fallback delete" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    # After individual deletes, must re-check remaining
    local fallback_block
    fallback_block=$(sed -n '/Fallback.*cleanup missed/,/fi$/p' "$common_sh")

    # Must have "Final verification" or "still remain" warning
    echo "$fallback_block" | grep -q 'still remain\|Final verification'
}

@test "detect-phase.sh: trigger exclusion uses run-completion (not run-versioning)" {
    local detect_sh="$SCRIPTS_DIR/detect-phase.sh"

    # Must reference run-completion, not run-versioning
    grep -q 'run-completion' "$detect_sh"
    ! grep -q 'run-versioning' "$detect_sh"
}

@test "bin/hype: reset-phase includes CONSULTATION and REFLEXING" {
    local hype_bin="$SCRIPTS_DIR/../../bin/hype"

    local phases_line
    phases_line=$(grep 'valid_phases=' "$hype_bin")

    echo "$phases_line" | grep -q 'CONSULTATION'
    echo "$phases_line" | grep -q 'REFLEXING'
}

@test "hype.sh: ANALYZE force-closes orphan triggers after analysts finish" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local analyze_block
    analyze_block=$(sed -n '/ANALYZE)/,/;;/p' "$hype_sh")

    # Must have force-close recovery when pending_triggers > 0
    echo "$analyze_block" | grep -q 'force-closing'

    # Must close orphans
    echo "$analyze_block" | grep -q 'Force cleanup'

    # Must re-check after force close
    echo "$analyze_block" | grep -q 'Re-check'
}

@test "get_approved_tasks: pipeline has fallback (|| echo)" {
    local merge_sh="$SCRIPTS_DIR/run-merge-queue.sh"

    local fn_block
    fn_block=$(sed -n '/^get_approved_tasks/,/^}/p' "$merge_sh")

    echo "$fn_block" | grep -q '|| echo'
}

@test "get_ready_tasks: pipeline has fallback (|| echo)" {
    local exec_sh="$SCRIPTS_DIR/run-coders.sh"

    local fn_block
    fn_block=$(sed -n '/^get_ready_tasks/,/^}/p' "$exec_sh")

    echo "$fn_block" | grep -q '|| echo'
}

@test "get_review_tasks: pipeline has fallback (|| echo)" {
    local rev_sh="$SCRIPTS_DIR/run-seniors.sh"

    local fn_block
    fn_block=$(sed -n '/^get_review_tasks/,/^}/p' "$rev_sh")

    echo "$fn_block" | grep -q '|| echo'
}

# =============================================================================
# v2.5.7 fixes
# =============================================================================

@test "hype.sh: all run_agent_with_mode calls have || guard (#23)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Every run_agent_with_mode call must be guarded against set -e:
    # Either has || on same/next line, or is inside an if condition (which suppresses set -e)
    # Get line numbers of all run_agent_with_mode calls
    local unguarded=""
    while IFS=: read -r linenum line; do
        # Skip comments
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        # Check if this line or next line has || guard
        local nextline
        nextline=$(sed -n "$((linenum+1))p" "$hype_sh")
        if echo "$line $nextline" | grep -q '|| '; then
            continue
        fi
        # Check if inside an 'if' condition (set -e doesn't fire in if)
        if echo "$line" | grep -q 'if run_agent_with_mode'; then
            continue
        fi
        unguarded="$unguarded\nLine $linenum: $line"
    done < <(grep -n 'run_agent_with_mode ' "$hype_sh")

    [ -z "$unguarded" ]
}

@test "hype.sh: run_interactive_agent uses -- before positional arg" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local func_block
    func_block=$(sed -n '/^run_interactive_agent()/,/^}/p' "$hype_sh")

    # Must have -- separator before positional arg (prevents --allowedTools consuming it)
    echo "$func_block" | grep -q '\-\- "Начни"'
}

@test "bin/hype: cmd_stop does NOT use system-wide pkill" {
    local hype_bin="$SCRIPTS_DIR/../../bin/hype"

    # Must NOT have pkill -f "claude" (kills all claude processes)
    ! grep -q 'pkill.*-f.*claude' "$hype_bin"
}

@test "bin/hype: cmd_stop uses collect_descendants for process tree" {
    local hype_bin="$SCRIPTS_DIR/../../bin/hype"

    grep -q 'collect_descendants' "$hype_bin"
}

@test "bin/hype: cmd_init health check skips if no .beads/" {
    local hype_bin="$SCRIPTS_DIR/../../bin/hype"

    # Health check in cmd_init must be conditional on .beads/ existing
    local init_block
    init_block=$(sed -n '/^cmd_init()/,/^}/p' "$hype_bin")

    echo "$init_block" | grep -q '\-d "\.beads"'
}

@test "bin/hype: cmd_wipe uses --limit 0 for bd list" {
    local hype_bin="$SCRIPTS_DIR/../../bin/hype"

    local wipe_block
    wipe_block=$(sed -n '/^cmd_wipe()/,/^}/p' "$hype_bin")

    # All bd list --json calls must have --limit 0
    local unguarded
    unguarded=$(echo "$wipe_block" | grep 'bd list.*--json' | grep -v '\-\-limit 0' || true)
    [ -z "$unguarded" ]
}

@test "bin/hype: no configure_flush_debounce (daemon removed)" {
    local hype_bin="$SCRIPTS_DIR/../../bin/hype"

    ! grep -q 'configure_flush_debounce' "$hype_bin"
}

@test "bin/hype: reset-phase legacy cleanup includes milestone:validating-done" {
    local hype_bin="$SCRIPTS_DIR/../../bin/hype"

    grep -q 'milestone:validating-done' "$hype_bin"
}

@test "bin/hype: reset-phase help lists DONE phase" {
    local hype_bin="$SCRIPTS_DIR/../../bin/hype"

    local help_block
    help_block=$(sed -n '/Available phases/,/Current phase/p' "$hype_bin")

    echo "$help_block" | grep -q 'DONE'
}

@test "bin/hype: cmd_status uses parse_utc_epoch (not manual date parsing)" {
    local hype_bin="$SCRIPTS_DIR/../../bin/hype"

    local status_block
    status_block=$(sed -n '/^cmd_status()/,/^}/p' "$hype_bin")

    echo "$status_block" | grep -q 'parse_utc_epoch'
    # Must NOT have manual date -j -f parsing
    ! echo "$status_block" | grep -q 'date -j -f'
}
