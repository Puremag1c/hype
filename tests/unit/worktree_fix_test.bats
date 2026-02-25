#!/usr/bin/env bats
# tests/unit/worktree_fix_test.bats
# Pattern tests for worktree prune+retry fix (#19)

load '../helpers/setup'

# =============================================================================
# Fix 1: Worktree creation has prune + retry
# =============================================================================

@test "create_worktree: runs git worktree prune before git worktree add" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    local prune_line add_line
    prune_line=$(grep -n 'git worktree prune' "$coders_sh" | head -1 | cut -d: -f1)
    add_line=$(grep -n 'git worktree add --detach' "$coders_sh" | head -1 | cut -d: -f1)

    [ -n "$prune_line" ]
    [ -n "$add_line" ]
    # Prune must come before first add
    [ "$prune_line" -lt "$add_line" ]
}

@test "create_worktree: has retry logic after first failure" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # Should have "retrying" log message
    grep -q 'Worktree creation failed.*retrying' "$coders_sh"

    # Should have sleep before retry
    local create_block
    create_block=$(sed -n '/^create_worktree/,/^}/p' "$coders_sh")
    echo "$create_block" | grep -q 'sleep 1'
}

@test "create_worktree: second prune before retry attempt" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # Extract create_worktree function
    local func_block
    func_block=$(sed -n '/^create_worktree/,/^}/p' "$coders_sh")

    # Should have two git worktree prune calls
    local prune_count
    prune_count=$(echo "$func_block" | grep -c 'git worktree prune')
    [ "$prune_count" -eq 2 ]
}

@test "create_worktree: captures stderr for diagnostic logging" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # Should capture stderr into variable for logging
    grep -q 'wt_stderr=.*git worktree add' "$coders_sh"
}

@test "create_worktree: fallback message mentions retry" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    grep -q 'Failed to create worktree.*after retry' "$coders_sh"
}

# =============================================================================
# Fix 2: Safety net — no 3-retry loop
# =============================================================================

@test "coder safety net: no 3-attempt retry loop" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # Extract run_coder function (from function start to next function)
    local func_block
    func_block=$(sed -n '/^run_coder/,/^run_auditor\|^main/p' "$coders_sh")

    # Should NOT have the old "attempt -lt 3" retry loop
    ! echo "$func_block" | grep -q 'attempt -lt 3'
    ! echo "$func_block" | grep -q 'attempt/3'
}

@test "coder safety net: uses fallback split strategy" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # Should have combined op with fallback to remove-coder only
    grep -q 'Combined label update failed.*trying remove-coder only' "$coders_sh"
}

@test "auditor safety net: no 3-attempt retry loop" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # Extract run_auditor function
    local func_block
    func_block=$(sed -n '/^run_auditor/,/^main/p' "$coders_sh")

    # Should NOT have the old retry loop
    ! echo "$func_block" | grep -q 'attempt -lt 3'
    ! echo "$func_block" | grep -q 'attempt/3'
}

@test "auditor safety net: uses fallback split strategy" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # Extract run_auditor function
    local func_block
    func_block=$(sed -n '/^run_auditor/,/^main/p' "$coders_sh")

    echo "$func_block" | grep -q 'Combined label update failed'
    echo "$func_block" | grep -q 'remove-label=coder'
}
