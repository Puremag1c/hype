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

    # Cache is created before heal
    local cache_line heal_line stale_line
    cache_line=$(grep -n 'in_progress_cache=.*bd_safe list' "$hype_sh" | grep -v 'impl_cache\|function\|heal_stuck' | head -1 | cut -d: -f1)
    heal_line=$(grep -n 'heal_stuck_tasks.*in_progress_cache' "$hype_sh" | grep -v '^[0-9]*:heal_stuck_tasks()' | head -1 | cut -d: -f1)
    stale_line=$(grep -n 'check_stale_tasks.*in_progress_cache' "$hype_sh" | head -1 | cut -d: -f1)

    # Order: cache → heal → stale
    [ "$cache_line" -lt "$heal_line" ]
    [ "$heal_line" -lt "$stale_line" ]
}

@test "hype.sh: only ONE in_progress_cache fetch in main loop (excluding impl_cache)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Extract main loop (from "while [ \$cycle" to "done")
    local main_loop
    main_loop=$(sed -n '/while \[ \$cycle/,/^    done$/p' "$hype_sh")

    # Count in_progress_cache assignments (not impl_cache)
    local count
    count=$(echo "$main_loop" | grep 'in_progress_cache=.*bd_safe' | wc -l | tr -d ' ')

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
