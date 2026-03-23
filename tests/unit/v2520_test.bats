#!/usr/bin/env bats
# tests/unit/v2520_test.bats
# Tests for v2.5.20: Dolt shutdown, cleanup UX, token cost tracking

load '../helpers/setup'

# =============================================================================
# Dolt shutdown on cleanup
# =============================================================================

@test "cleanup_iteration: stops Dolt server after cleanup" {
    local common_sh="$SCRIPTS_DIR/common.sh"
    [ -f "$common_sh" ]

    func_body=$(sed -n '/^cleanup_iteration()/,/^}/p' "$common_sh")
    echo "$func_body" | grep -q 'bd dolt stop'
}

@test "cleanup_iteration: bd dolt stop is after all bd operations" {
    # bd dolt stop must come AFTER bd_safe close/delete calls (needs server alive)
    local common_sh="$SCRIPTS_DIR/common.sh"
    [ -f "$common_sh" ]

    func_body=$(sed -n '/^cleanup_iteration()/,/^}/p' "$common_sh")
    # bd dolt stop should appear after the last bd_safe call
    local last_bd_safe_line last_dolt_stop_line
    last_bd_safe_line=$(echo "$func_body" | grep -n 'bd_safe' | tail -1 | cut -d: -f1)
    last_dolt_stop_line=$(echo "$func_body" | grep -n 'bd dolt stop' | tail -1 | cut -d: -f1)
    [ "$last_dolt_stop_line" -gt "$last_bd_safe_line" ]
}

# =============================================================================
# Cleanup prompt defaults to Y
# =============================================================================

@test "cmd_clear: prompt shows (Y/n) not (y/N)" {
    local hype_bin="$PROJECT_ROOT/bin/hype"
    [ -f "$hype_bin" ]

    # Get cmd_clear function body
    func_body=$(sed -n '/^cmd_clear()/,/^}/p' "$hype_bin")
    echo "$func_body" | grep -q '(Y/n)'
    # Should NOT have old default-N prompt
    ! echo "$func_body" | grep -q 'Continue? (y/N)'
}

@test "cmd_clear: cancels only on explicit N" {
    local hype_bin="$PROJECT_ROOT/bin/hype"
    [ -f "$hype_bin" ]

    func_body=$(sed -n '/^cmd_clear()/,/^}/p' "$hype_bin")
    # Should match N/n to cancel (not Y/y to proceed)
    echo "$func_body" | grep -q '\^\[Nn\]\$'
}

@test "hype.sh DONE: cleanup prompt shows (Y/n) not (y/N)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"
    [ -f "$hype_sh" ]

    # DONE block cleanup prompt
    grep -q 'Cleanup now? (Y/n)' "$hype_sh"
    ! grep -q 'Cleanup now? (y/N)' "$hype_sh"
}

@test "hype.sh DONE: cleanup cancels only on explicit N" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"
    [ -f "$hype_sh" ]

    # The DONE cleanup block should check for N, not Y
    # Find the cleanup prompt context
    local cleanup_block
    cleanup_block=$(grep -A5 'Cleanup now?' "$hype_sh")
    echo "$cleanup_block" | grep -q '\^\[Nn\]\$'
}

@test "cleanup_iteration: in-progress safety prompt stays (y/N)" {
    # The dangerous "destroy active work" prompt must stay default-N
    local common_sh="$SCRIPTS_DIR/common.sh"
    [ -f "$common_sh" ]

    func_body=$(sed -n '/^cleanup_iteration()/,/^}/p' "$common_sh")
    echo "$func_body" | grep -q 'Are you sure.*y/N'
}

# =============================================================================
# Token cost tracking
# =============================================================================

@test "run_claude_with_progress: extracts token usage to tokens.jsonl" {
    local common_sh="$SCRIPTS_DIR/common.sh"
    [ -f "$common_sh" ]

    func_body=$(sed -n '/^run_claude_with_progress()/,/^export -f run_claude_with_progress/p' "$common_sh")
    echo "$func_body" | grep -q 'tokens.jsonl'
}

@test "run_claude_with_progress: extracts total_cost_usd from result" {
    local common_sh="$SCRIPTS_DIR/common.sh"
    [ -f "$common_sh" ]

    func_body=$(sed -n '/^run_claude_with_progress()/,/^export -f run_claude_with_progress/p' "$common_sh")
    echo "$func_body" | grep -q 'total_cost_usd'
}

@test "run_claude_with_progress: extracts token counts from result" {
    local common_sh="$SCRIPTS_DIR/common.sh"
    [ -f "$common_sh" ]

    func_body=$(sed -n '/^run_claude_with_progress()/,/^export -f run_claude_with_progress/p' "$common_sh")
    echo "$func_body" | grep -q 'input_tokens'
    echo "$func_body" | grep -q 'output_tokens'
    echo "$func_body" | grep -q 'cache_read_input_tokens'
}

@test "run_claude_with_progress: token extraction before raw_output cleanup" {
    local common_sh="$SCRIPTS_DIR/common.sh"
    [ -f "$common_sh" ]

    func_body=$(sed -n '/^run_claude_with_progress()/,/^export -f run_claude_with_progress/p' "$common_sh")
    # tokens.jsonl extraction must appear BEFORE the final rm -f "$raw_output" (not the trap one)
    local tokens_line rm_line
    tokens_line=$(echo "$func_body" | grep -n 'tokens.jsonl' | head -1 | cut -d: -f1)
    # Get the LAST rm -f "$raw_output" (the real cleanup, not the trap)
    rm_line=$(echo "$func_body" | grep -n 'rm -f "$raw_output"' | tail -1 | cut -d: -f1)
    [ "$tokens_line" -lt "$rm_line" ]
}

@test "generate_iteration_stats: reads tokens.jsonl (not chars/4 estimate)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"
    [ -f "$hype_sh" ]

    func_body=$(sed -n '/^generate_iteration_stats()/,/^}/p' "$hype_sh")
    echo "$func_body" | grep -q 'tokens.jsonl'
    echo "$func_body" | grep -q 'total_cost'
    # Should NOT have old estimate
    ! echo "$func_body" | grep -q 'estimated_tokens'
    ! echo "$func_body" | grep -q 'chars.*4'
}

@test "generate_iteration_stats: report has Token Usage section" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"
    [ -f "$hype_sh" ]

    func_body=$(sed -n '/^generate_iteration_stats()/,/^}/p' "$hype_sh")
    echo "$func_body" | grep -q 'Token Usage'
    echo "$func_body" | grep -q 'total_cost'
    echo "$func_body" | grep -q 'Agent calls'
}

# =============================================================================
# Beads runtime cleanup (dirty git status prevention)
# =============================================================================

@test "cleanup_iteration: cleans beads runtime files" {
    local common_sh="$SCRIPTS_DIR/common.sh"
    [ -f "$common_sh" ]

    func_body=$(sed -n '/^cleanup_iteration()/,/^}/p' "$common_sh")
    echo "$func_body" | grep -q 'dolt-server.lock'
    echo "$func_body" | grep -q 'dolt-server.log'
    echo "$func_body" | grep -q 'dolt-server.pid'
    echo "$func_body" | grep -q '.beads-credential-key'
    echo "$func_body" | grep -q 'backup'
}

@test "cleanup_iteration: restores metadata.json from git" {
    local common_sh="$SCRIPTS_DIR/common.sh"
    [ -f "$common_sh" ]

    func_body=$(sed -n '/^cleanup_iteration()/,/^}/p' "$common_sh")
    echo "$func_body" | grep -q 'git.*checkout.*metadata.json'
}

@test "cleanup_iteration: cleans tokens.jsonl" {
    local common_sh="$SCRIPTS_DIR/common.sh"
    [ -f "$common_sh" ]

    func_body=$(sed -n '/^cleanup_iteration()/,/^}/p' "$common_sh")
    echo "$func_body" | grep -q 'tokens.jsonl'
}

@test "bin/hype: update_beads_gitignore covers dolt-server runtime files" {
    local hype_bin="$PROJECT_ROOT/bin/hype"
    [ -f "$hype_bin" ]

    func_body=$(sed -n '/^update_beads_gitignore()/,/^}/p' "$hype_bin")
    echo "$func_body" | grep -q 'dolt-server.lock'
    echo "$func_body" | grep -q 'dolt-server.pid'
    echo "$func_body" | grep -q '.beads-credential-key'
    echo "$func_body" | grep -q 'backup/'
}

@test "bin/hype: cmd_init calls update_beads_gitignore" {
    local hype_bin="$PROJECT_ROOT/bin/hype"
    [ -f "$hype_bin" ]

    # cmd_init has nested braces, so use line range between cmd_init and next cmd_ function
    local start_line end_line
    start_line=$(grep -n '^cmd_init()' "$hype_bin" | head -1 | cut -d: -f1)
    end_line=$(awk "NR>$start_line && /^cmd_[a-z]/{print NR; exit}" "$hype_bin")
    sed -n "${start_line},${end_line}p" "$hype_bin" | grep -q 'update_beads_gitignore'
}

@test "hype.sh DONE: shows cost summary before cleanup prompt" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"
    [ -f "$hype_sh" ]

    # Cost display should appear in the DONE block
    grep -q 'iter_cost' "$hype_sh"
    grep -q 'iter_calls' "$hype_sh"

    # Cost should be before cleanup prompt
    local cost_line cleanup_line
    cost_line=$(grep -n 'iter_cost' "$hype_sh" | head -1 | cut -d: -f1)
    cleanup_line=$(grep -n 'Cleanup now?' "$hype_sh" | head -1 | cut -d: -f1)
    [ "$cost_line" -lt "$cleanup_line" ]
}

# =============================================================================
# Gitignore auto-commit tests (v2.5.21)
# =============================================================================

@test "bin/hype: commit_gitignore_changes function defined" {
    local hype_bin="$PROJECT_ROOT/bin/hype"
    grep -q '^commit_gitignore_changes()' "$hype_bin"
}

@test "bin/hype: commit_gitignore_changes checks git diff" {
    local hype_bin="$PROJECT_ROOT/bin/hype"
    local func_block
    func_block=$(sed -n '/^commit_gitignore_changes()/,/^}/p' "$hype_bin")
    echo "$func_block" | grep -q 'git diff'
    echo "$func_block" | grep -q '.gitignore'
}

@test "bin/hype: cmd_init calls commit_gitignore_changes" {
    local hype_bin="$PROJECT_ROOT/bin/hype"
    local start_line end_line
    start_line=$(grep -n '^cmd_init()' "$hype_bin" | head -1 | cut -d: -f1)
    end_line=$(awk "NR>$start_line && /^cmd_[a-z]/{print NR; exit}" "$hype_bin")
    sed -n "${start_line},${end_line}p" "$hype_bin" | grep -q 'commit_gitignore_changes'
}

@test "bin/hype: cmd_upgrade calls commit_gitignore_changes" {
    local hype_bin="$PROJECT_ROOT/bin/hype"
    local start_line end_line
    start_line=$(grep -n '^cmd_upgrade()' "$hype_bin" | head -1 | cut -d: -f1)
    end_line=$(awk "NR>$start_line && /^cmd_[a-z]/{print NR; exit}" "$hype_bin")
    sed -n "${start_line},${end_line}p" "$hype_bin" | grep -q 'commit_gitignore_changes'
}

@test "bin/hype: update_gitignore adds .claude/ entry" {
    local hype_bin="$PROJECT_ROOT/bin/hype"
    local func_block
    func_block=$(sed -n '/^update_gitignore()/,/^}/p' "$hype_bin")
    echo "$func_block" | grep -q '\.claude/'
}

@test "bin/hype: update_gitignore uses exact line match (grep -qxF)" {
    local hype_bin="$PROJECT_ROOT/bin/hype"
    local func_block
    func_block=$(sed -n '/^update_gitignore()/,/^}/p' "$hype_bin")
    echo "$func_block" | grep -q 'grep -qxF'
}

@test "bin/hype: update_beads_gitignore uses exact line match (grep -qxF)" {
    local hype_bin="$PROJECT_ROOT/bin/hype"
    local func_block
    func_block=$(sed -n '/^update_beads_gitignore()/,/^}/p' "$hype_bin")
    echo "$func_block" | grep -q 'grep -qxF'
}

# =============================================================================
# GH #41: Parasitic database protection
# =============================================================================

@test "setup_worktree_links: symlinks .beads/ to worktree (GH #41)" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"
    local func_block
    func_block=$(sed -n '/^setup_worktree_links()/,/^}/p' "$coders_sh")
    echo "$func_block" | grep -q '\.beads'
    echo "$func_block" | grep -q 'ln -sf'
}

@test "coder.md: prohibits bd init (GH #41)" {
    grep -q 'bd init' "$PROJECT_ROOT/core/agents/coder.md"
    grep -q 'НИКОГДА.*bd init' "$PROJECT_ROOT/core/agents/coder.md"
}

@test "check_beads: validates metadata.json dolt_database pointer (GH #41)" {
    local common_sh="$SCRIPTS_DIR/common.sh"
    local func_block
    func_block=$(sed -n '/^check_beads()/,/^}/p' "$common_sh")
    echo "$func_block" | grep -q 'dolt_database'
    echo "$func_block" | grep -q 'metadata.json'
}

# =============================================================================
# GH #42: VALIDATING/REPORTING infinite loop fixes
# =============================================================================

@test "hype.sh: VALIDATING 3x timeout auto-skips (no P0 bug creation) (GH #42)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"
    # Must NOT create P0 bug on VALIDATING timeout
    local validating_block
    validating_block=$(sed -n '/VALIDATING.*attempt/,/;;/p' "$hype_sh")
    ! echo "$validating_block" | grep -q 'VALIDATING incomplete.*creating blocker'
    # Must auto-skip with ensure_milestone
    echo "$validating_block" | grep -q 'Validation skipped'
}

@test "hype.sh: check_and_create_done_milestone uses has_milestone (GH #42)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"
    local func_block
    func_block=$(sed -n '/^check_and_create_done_milestone()/,/^}/p' "$hype_sh")
    echo "$func_block" | grep -q 'has_milestone.*validating-done'
    # Must NOT grep logs for VALIDATING: PASSED (comments don't count)
    ! echo "$func_block" | grep -v '^[[:space:]]*#' | grep -q 'VALIDATING: PASSED'
}

@test "hype.sh: generate_iteration_stats checks validating skip (GH #42)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"
    local func_block
    func_block=$(sed -n '/^generate_iteration_stats()/,/^}/p' "$hype_sh")
    echo "$func_block" | grep -q 'validating_reason'
    echo "$func_block" | grep -q 'VALIDATING skipped'
}

@test "qa.md: test commands use timeout 5m (GH #42)" {
    grep -q 'timeout 5m' "$PROJECT_ROOT/core/agents/qa.md"
}

# =============================================================================
# GH #45: TASK_STALE_TIMEOUT derived from TASK_TIMEOUT
# =============================================================================

@test "hype.sh: TASK_STALE_TIMEOUT derived from TASK_TIMEOUT (GH #45)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"
    local func_block
    func_block=$(sed -n '/^validate_config()/,/^}/p' "$hype_sh")
    # Must compute stale timeout from task timeout
    echo "$func_block" | grep -q 'TASK_STALE_TIMEOUT='
    echo "$func_block" | grep -q 'timeout_num'
    # Must NOT validate TASK_STALE_TIMEOUT as config param
    ! echo "$func_block" | grep -q 'validate_int.*TASK_STALE_TIMEOUT'
}

@test "hype.sh: TASK_STALE_TIMEOUT exported for subshells (GH #45)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"
    grep -q 'export TASK_STALE_TIMEOUT' "$hype_sh"
}

@test "config template: no TASK_STALE_TIMEOUT param (GH #45)" {
    ! grep -q '^TASK_STALE_TIMEOUT=' "$PROJECT_ROOT/templates/config.template.sh"
}
