#!/usr/bin/env bats
# tests/unit/worktree_symlinks_test.bats
# Pattern tests for worktree symlinks (GH #26)

load '../helpers/setup'

# =============================================================================
# setup_worktree_links function exists and has correct structure
# =============================================================================

@test "create_worktree: setup_worktree_links called after git worktree add" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # Extract create_worktree function
    local func_block
    func_block=$(sed -n '/^create_worktree/,/^}/p' "$coders_sh")

    # setup_worktree_links must appear after git worktree add
    local add_line link_line
    add_line=$(echo "$func_block" | grep -n 'git worktree add --detach' | head -1 | cut -d: -f1)
    link_line=$(echo "$func_block" | grep -n 'setup_worktree_links' | head -1 | cut -d: -f1)

    [ -n "$add_line" ]
    [ -n "$link_line" ]
    [ "$link_line" -gt "$add_line" ]
}

@test "setup_worktree_links: symlinks known build dirs" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # Extract setup_worktree_links function
    local func_block
    func_block=$(sed -n '/^setup_worktree_links/,/^}/p' "$coders_sh")

    # Must include all expected dirs
    echo "$func_block" | grep -q 'deps'
    echo "$func_block" | grep -q '_build'
    echo "$func_block" | grep -q 'node_modules'
    echo "$func_block" | grep -q '\.venv'
    echo "$func_block" | grep -q 'venv'
    echo "$func_block" | grep -q 'vendor'
    echo "$func_block" | grep -q 'target'
}

@test "setup_worktree_links: checks dir exists before symlinking" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # Extract setup_worktree_links function
    local func_block
    func_block=$(sed -n '/^setup_worktree_links/,/^}/p' "$coders_sh")

    # Must have -d guard (dir exists in project)
    echo "$func_block" | grep -q '\[ -d '
}

@test "setup_worktree_links: does not overwrite existing dir" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # Extract setup_worktree_links function
    local func_block
    func_block=$(sed -n '/^setup_worktree_links/,/^}/p' "$coders_sh")

    # Must have ! -e guard (don't overwrite existing)
    echo "$func_block" | grep -q '\[ ! -e '
}

@test "setup_worktree_links: called on retry path too" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # Extract create_worktree function
    local func_block
    func_block=$(sed -n '/^create_worktree/,/^}/p' "$coders_sh")

    # Must have two setup_worktree_links calls (primary + retry)
    local call_count
    call_count=$(echo "$func_block" | grep -c 'setup_worktree_links')
    [ "$call_count" -eq 2 ]
}

@test "cleanup_worktree: no special symlink handling needed" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    # Extract cleanup_worktree function
    local func_block
    func_block=$(sed -n '/^cleanup_worktree/,/^}/p' "$coders_sh")

    # cleanup_worktree should NOT reference setup_worktree_links
    # (symlinks are handled by rm -rf / git worktree remove)
    ! echo "$func_block" | grep -q 'setup_worktree_links'
}
