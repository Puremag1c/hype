#!/usr/bin/env bats
# tests/unit/v237_test.bats
# Tests for v2.3.7: bd_safe auto-recovery, heal-before-dispatch, executor restrictions

load '../helpers/setup'

# =============================================================================
# P0: bd_safe write auto-recovery
# =============================================================================

@test "bd_safe: auto-recovery block exists for write operations" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    # Must detect write failures (update/close/create/sync)
    grep -q 'update|close|create|sync' "$common_sh"
}

@test "bd_safe: retries failed write after daemon health check" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    # Must have retry logic after daemon probe
    local recovery_block
    recovery_block=$(sed -n '/Auto-recovery for failed write/,/Release lock/p' "$common_sh")

    # Must probe daemon health
    echo "$recovery_block" | grep -q 'bd list --limit 1'

    # Must attempt daemon restart
    echo "$recovery_block" | grep -q 'daemon restart'

    # Must retry the command
    echo "$recovery_block" | grep -q 'timeout_cmd.*bd.*"$@"'
}

@test "bd_safe: logs warning on write failure" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local recovery_block
    recovery_block=$(sed -n '/Auto-recovery for failed write/,/Release lock/p' "$common_sh")

    # Must log WARN with command info
    echo "$recovery_block" | grep -q 'WARN.*bd.*failed'
}

@test "bd_safe: logs recovery success" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local recovery_block
    recovery_block=$(sed -n '/Auto-recovery for failed write/,/Release lock/p' "$common_sh")

    echo "$recovery_block" | grep -q 'recovered after retry'
}

@test "bd_safe: logs error on retry failure" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local recovery_block
    recovery_block=$(sed -n '/Auto-recovery for failed write/,/Release lock/p' "$common_sh")

    echo "$recovery_block" | grep -q 'ERROR.*retry failed'
}

@test "bd_safe: does NOT retry read operations (list, show)" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    # The case statement only matches write operations
    local case_block
    case_block=$(sed -n '/Auto-recovery for failed write/,/esac/p' "$common_sh")

    # Only update|close|create|sync — no list, show, etc.
    echo "$case_block" | grep -q 'update|close|create|sync)'

    # Must NOT contain list or show in the case pattern
    ! echo "$case_block" | grep -q 'list|show'
}

@test "bd_safe: releases lock AFTER retry (not before)" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    # Get line numbers for retry and lock release
    local retry_line lock_line
    retry_line=$(grep -n 'recovered after retry' "$common_sh" | head -1 | cut -d: -f1)
    lock_line=$(grep -n 'Release lock' "$common_sh" | head -1 | cut -d: -f1)

    # Lock release must come after retry
    [ "$retry_line" -lt "$lock_line" ]
}

# =============================================================================
# P1: heal_stuck_tasks before dispatch_phase
# =============================================================================

@test "hype.sh: heal_stuck_tasks runs BEFORE dispatch_phase" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Get line numbers in main loop
    local heal_line dispatch_line
    heal_line=$(grep -n 'heal_stuck_tasks' "$hype_sh" | grep -v '^[0-9]*:heal_stuck_tasks()' | grep -v '#' | head -1 | cut -d: -f1)
    dispatch_line=$(grep -n 'dispatch_phase.*phase.*phase_json' "$hype_sh" | grep -v 'function\|#' | head -1 | cut -d: -f1)

    # heal must run before dispatch
    [ "$heal_line" -lt "$dispatch_line" ]
}

@test "hype.sh: in_progress_cache shared between heal and check_stale" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # v2.3.9: Cache is extracted from tick-cache.json (not bd_safe)
    local cache_line heal_line stale_line
    cache_line=$(grep -n 'in_progress_cache=.*tick-cache' "$hype_sh" | head -1 | cut -d: -f1)
    heal_line=$(grep -n 'heal_stuck_tasks.*in_progress_cache' "$hype_sh" | grep -v '^[0-9]*:heal_stuck_tasks()' | head -1 | cut -d: -f1)
    stale_line=$(grep -n 'check_stale_tasks.*in_progress_cache' "$hype_sh" | head -1 | cut -d: -f1)

    # Order: cache → heal → stale
    [ "$cache_line" -lt "$heal_line" ]
    [ "$heal_line" -lt "$stale_line" ]
}

@test "hype.sh: only ONE in_progress_cache fetch in main loop" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Extract main loop (from "while [ \$cycle" to "done")
    local main_loop
    main_loop=$(sed -n '/while \[ \$cycle/,/^    done$/p' "$hype_sh")

    # v2.3.9: Count in_progress_cache assignments from tick-cache
    local count
    count=$(echo "$main_loop" | grep 'in_progress_cache=.*tick-cache' | wc -l | tr -d ' ')

    [ "$count" -eq 1 ]
}

# =============================================================================
# P2: executor.md restricts bd create
# =============================================================================

@test "executor.md: has explicit bd create restriction" {
    local executor_md="$CORE_DIR/agents/executor.md"

    grep -q 'НИКОГДА не создавай новые задачи.*bd create' "$executor_md"
}

@test "executor.md: allows bd create exception for rebase conflicts" {
    local executor_md="$CORE_DIR/agents/executor.md"

    # Rule mentions rebase as exception
    grep -q 'rebase' "$executor_md" | head -1

    # The actual bd create in the rebase section still exists
    grep -q 'bd create.*Resolve rebase conflict' "$executor_md"
}

# =============================================================================
# v2.3.9: File-based milestones (replaced bd tasks)
# =============================================================================

@test "common.sh: milestone functions are file-based (no bd calls)" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    # _milestone_file returns .hype/milestone-{name} path
    local func_body
    func_body=$(sed -n '/^_milestone_file()/,/^}/p' "$common_sh")
    echo "$func_body" | grep -q 'milestone-'

    # has_milestone checks file existence (not bd)
    func_body=$(sed -n '/^has_milestone()/,/^}/p' "$common_sh")
    echo "$func_body" | grep -q '\[ -f '
    ! echo "$func_body" | grep -q 'bd_safe'

    # ensure_milestone writes file (not bd create)
    func_body=$(sed -n '/^ensure_milestone()/,/^}/p' "$common_sh")
    echo "$func_body" | grep -q 'echo.*>.*\$mfile'
    ! echo "$func_body" | grep -q 'bd_safe'

    # delete_milestone uses rm -f (not bd)
    func_body=$(sed -n '/^delete_milestone()/,/^}/p' "$common_sh")
    echo "$func_body" | grep -q 'rm -f'
    ! echo "$func_body" | grep -q 'bd_safe'
}

@test "common.sh: delete_all_milestones globs .hype/milestone-*" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local func_body
    func_body=$(sed -n '/^delete_all_milestones()/,/^}/p' "$common_sh")
    echo "$func_body" | grep -q 'milestone-\*'
    ! echo "$func_body" | grep -q 'bd_safe'
}

@test "common.sh: milestone functions use HYPE_DIR with .hype default" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local func_body
    func_body=$(sed -n '/^_milestone_file()/,/^}/p' "$common_sh")
    echo "$func_body" | grep -q 'HYPE_DIR:-.hype'
}

# =============================================================================
# v2.3.9: tick-cache.json
# =============================================================================

@test "detect-phase.sh: writes tick-cache.json after bd list" {
    local detect_sh="$SCRIPTS_DIR/detect-phase.sh"

    # Must write ALL_TASKS_JSON to tick-cache
    grep -q 'tick-cache.json' "$detect_sh"
    grep -q 'ALL_TASKS_JSON.*tick-cache' "$detect_sh"
}

@test "detect-phase.sh: uses _check_milestone with file fallback to bd" {
    local detect_sh="$SCRIPTS_DIR/detect-phase.sh"

    # Must check file first
    grep -q 'milestone-.*echo 1.*return' "$detect_sh"
    # Must fall back to bd task labels for backward compat (≤v2.3.8)
    grep -q 'ALL_TASKS_JSON.*milestone:' "$detect_sh"
}

@test "detect-phase.sh: empty bd response guard (prevents phase regression)" {
    local detect_sh="$SCRIPTS_DIR/detect-phase.sh"

    # If TOTAL==0 but milestones exist → ERROR (not PLANNING)
    grep -q 'milestones exist.*daemon returned empty' "$detect_sh"
    grep -q 'output_json "ERROR"' "$detect_sh"
}

@test "hype.sh: exports HYPE_DIR for milestone functions" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    grep -q 'export HYPE_DIR=' "$hype_sh"
}

@test "hype.sh: dispatch_phase reads tick-cache for IMPLEMENTATION" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # IMPLEMENTATION dispatch should NOT have bd_safe list
    local impl_block
    impl_block=$(sed -n '/^        IMPLEMENTATION)/,/;;$/p' "$hype_sh")
    ! echo "$impl_block" | grep -q 'bd_safe list'
}

@test "hype.sh: dispatch_phase reads tick-cache for SMOKE_TEST" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local smoke_block
    smoke_block=$(sed -n '/^        SMOKE_TEST)/,/;;$/p' "$hype_sh")

    # tick-cache reads exist
    echo "$smoke_block" | grep -q 'tick-cache.json'

    # No bd_safe list
    ! echo "$smoke_block" | grep -q 'bd_safe list'
}

@test "hype.sh: dispatch_phase reads tick-cache for SMOKE_REVIEW" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local smoke_review_block
    smoke_review_block=$(sed -n '/^        SMOKE_REVIEW)/,/;;$/p' "$hype_sh")

    echo "$smoke_review_block" | grep -q 'tick-cache.json'
    ! echo "$smoke_review_block" | grep -q 'bd_safe list'
}

@test "hype.sh: dispatch_phase reads tick-cache for USER_REVIEW" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local user_block
    user_block=$(sed -n '/^        USER_REVIEW)/,/;;$/p' "$hype_sh")

    echo "$user_block" | grep -q 'tick-cache.json'
    ! echo "$user_block" | grep -q 'bd_safe list'
}

@test "hype.sh: FINAL_REVIEW keeps bd_safe for post-agent checks" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # FINAL_REVIEW must still use bd_safe list (post-agent, needs fresh data)
    local final_block
    final_block=$(sed -n '/^        FINAL_REVIEW)/,/;;$/p' "$hype_sh")
    echo "$final_block" | grep -q 'bd_safe list'
}

@test "hype.sh: heal reads from tick-cache in main loop" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Main loop extracts in_progress from tick-cache
    grep -q 'jq.*in_progress.*tick-cache.json' "$hype_sh"
}

@test "hype.sh: check_and_route_troubleshoot reads tick-cache" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local func_body
    func_body=$(sed -n '/^check_and_route_troubleshoot()/,/^}/p' "$hype_sh")
    echo "$func_body" | grep -q 'tick-cache.json'
    ! echo "$func_body" | grep -q 'bd_safe list'
}

@test "hype.sh: check_problems_and_consult_manager reads tick-cache" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local func_body
    func_body=$(sed -n '/^check_problems_and_consult_manager()/,/^}/p' "$hype_sh")
    echo "$func_body" | grep -q 'tick-cache.json'
    ! echo "$func_body" | grep -q 'bd_safe list'
}

@test "hype.sh: generate_iteration_stats reads tick-cache" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local func_body
    func_body=$(sed -n '/^generate_iteration_stats()/,/^}/p' "$hype_sh")
    echo "$func_body" | grep -q 'tick-cache.json'
    ! echo "$func_body" | grep -q 'bd_safe list'
}
