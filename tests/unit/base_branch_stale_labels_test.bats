#!/usr/bin/env bats
# tests/unit/base_branch_stale_labels_test.bats
# Tests for #24: base branch detection + stale labels filter
#
# Bug 1 (claudev-n6r): origin/main hardcoded → detached HEAD on non-main projects
# Bug 2 (claudev-qdq): tick-cache jq filters missing status != "closed"

load '../helpers/setup'

# =============================================================================
# Bug 1: get_base_branch() function
# =============================================================================

@test "get_base_branch: function exists and is exported" {
    local common_sh="$SCRIPTS_DIR/common.sh"
    grep -q 'get_base_branch()' "$common_sh"
    grep -q 'export -f get_base_branch' "$common_sh"
}

@test "get_base_branch: respects BASE_BRANCH config override" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    # Function should check BASE_BRANCH first
    local fn_block
    fn_block=$(sed -n '/^get_base_branch()/,/^}/p' "$common_sh")

    echo "$fn_block" | grep -q 'BASE_BRANCH'
}

@test "get_base_branch: uses symbolic-ref as second priority" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local fn_block
    fn_block=$(sed -n '/^get_base_branch()/,/^}/p' "$common_sh")

    echo "$fn_block" | grep -q 'symbolic-ref'
    echo "$fn_block" | grep -q 'rev-parse --verify'
}

@test "get_base_branch: probes main, master, develop" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local fn_block
    fn_block=$(sed -n '/^get_base_branch()/,/^}/p' "$common_sh")

    echo "$fn_block" | grep -q 'main'
    echo "$fn_block" | grep -q 'master'
    echo "$fn_block" | grep -q 'develop'
}

@test "get_base_branch: has fallback to main" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    local fn_block
    fn_block=$(sed -n '/^get_base_branch()/,/^}/p' "$common_sh")

    # Last echo should be "main" as fallback
    local last_echo
    last_echo=$(echo "$fn_block" | grep 'echo "main"' | tail -1)
    [ -n "$last_echo" ]
}

# =============================================================================
# Bug 1: run-seniors.sh uses get_base_branch
# =============================================================================

@test "run-seniors.sh: no hardcoded origin/main" {
    local seniors_sh="$SCRIPTS_DIR/run-seniors.sh"

    # Should NOT contain literal origin/main (except in comments)
    ! grep -v '^#' "$seniors_sh" | grep -v '^\s*#' | grep -q 'origin/main'
}

@test "run-seniors.sh: build_review_context uses get_base_branch" {
    local seniors_sh="$SCRIPTS_DIR/run-seniors.sh"

    local fn_block
    fn_block=$(sed -n '/^build_review_context()/,/^}/p' "$seniors_sh")

    echo "$fn_block" | grep -q 'get_base_branch'
    echo "$fn_block" | grep -q 'base_branch'
}

@test "run-seniors.sh: preflight_check uses get_base_branch" {
    local seniors_sh="$SCRIPTS_DIR/run-seniors.sh"

    local fn_block
    fn_block=$(sed -n '/^preflight_check()/,/^}/p' "$seniors_sh")

    echo "$fn_block" | grep -q 'get_base_branch'
    echo "$fn_block" | grep -q 'base_branch'
}

# =============================================================================
# Bug 1: run-merge-queue.sh uses get_base_branch
# =============================================================================

@test "run-merge-queue.sh: uses get_base_branch instead of inline symbolic-ref" {
    local merge_sh="$SCRIPTS_DIR/run-merge-queue.sh"

    # merge_task should call get_base_branch
    local fn_block
    fn_block=$(sed -n '/^merge_task()/,/^}/p' "$merge_sh")

    echo "$fn_block" | grep -q 'get_base_branch'
}

@test "run-merge-queue.sh: no inline symbolic-ref for base branch" {
    local merge_sh="$SCRIPTS_DIR/run-merge-queue.sh"

    # Should NOT have inline symbolic-ref detection (replaced by get_base_branch)
    local fn_block
    fn_block=$(sed -n '/^merge_task()/,/^}/p' "$merge_sh")

    ! echo "$fn_block" | grep -q 'symbolic-ref refs/remotes/origin/HEAD'
}

# =============================================================================
# Bug 1: coder.md uses BASE_BRANCH variable
# =============================================================================

@test "coder.md: documents BASE_BRANCH in context variables" {
    local coder_md="$AGENTS_DIR/coder.md"

    grep -q 'BASE_BRANCH' "$coder_md"
}

@test "coder.md: uses BASE_BRANCH variable instead of hardcoded main" {
    local coder_md="$AGENTS_DIR/coder.md"

    # Should reference origin/${BASE_BRANCH} not origin/main
    grep -q 'origin/\${BASE_BRANCH}' "$coder_md"

    # No bare origin/main in code blocks
    ! grep -v '^#' "$coder_md" | grep -v 'origin/\${BASE_BRANCH}' | grep -q 'origin/main'
}

# =============================================================================
# Bug 1: ops.md uses BASE_BRANCH variable
# =============================================================================

@test "ops.md: uses BASE_BRANCH variable" {
    local ops_md="$AGENTS_DIR/ops.md"

    grep -q 'origin/\${BASE_BRANCH}' "$ops_md"
    ! grep -q 'origin/main' "$ops_md"
}

# =============================================================================
# Bug 1: run-coders.sh passes BASE_BRANCH in prompt context
# =============================================================================

@test "run-coders.sh: passes BASE_BRANCH in coder prompt" {
    local coders_sh="$SCRIPTS_DIR/run-coders.sh"

    grep -q 'BASE_BRANCH' "$coders_sh"
    grep -q 'get_base_branch' "$coders_sh"
}

# =============================================================================
# Bug 1: config template has BASE_BRANCH
# =============================================================================

@test "config template: has BASE_BRANCH setting" {
    local template="$PROJECT_ROOT/templates/config.template.sh"

    grep -q 'BASE_BRANCH=' "$template"
}

# =============================================================================
# Bug 1: no origin/main in core scripts (except test/changelog files)
# =============================================================================

@test "no hardcoded origin/main in core scripts" {
    # Check all .sh files in core/scripts/ (excluding comments)
    local violations=""
    for f in "$SCRIPTS_DIR"/*.sh; do
        local base
        base=$(basename "$f")
        # Skip files that might legitimately reference origin/main for HYPE's own repo
        if grep -v '^\s*#' "$f" | grep -q 'origin/main'; then
            violations="$violations $base"
        fi
    done

    if [ -n "$violations" ]; then
        echo "Files with hardcoded origin/main:$violations" >&2
        return 1
    fi
}

# =============================================================================
# Bug 2: Stale labels filter — all 7 jq filters have status != "closed"
# =============================================================================

@test "hype.sh: check_and_route_troubleshoot filters closed tasks" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local fn_block
    fn_block=$(sed -n '/^check_and_route_troubleshoot()/,/^}/p' "$hype_sh")

    # The troubleshoot_ids jq filter should exclude closed
    echo "$fn_block" | grep 'troubleshoot_ids' | grep -q 'status.*!=.*closed'
}

@test "hype.sh: check_problems blocked_count filters closed tasks" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local fn_block
    fn_block=$(sed -n '/^check_problems_and_consult_manager()/,/^}/p' "$hype_sh")

    echo "$fn_block" | grep 'blocked_count' | grep -q 'status.*!=.*closed'
}

@test "hype.sh: check_problems retry_limit_count filters closed tasks" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local fn_block
    fn_block=$(sed -n '/^check_problems_and_consult_manager()/,/^}/p' "$hype_sh")

    echo "$fn_block" | grep 'retry_limit_count' | grep -q 'status.*!=.*closed'
}

@test "hype.sh: call_manager blocked_ids filters closed tasks" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local fn_block
    fn_block=$(sed -n '/^call_manager_for_problems()/,/^}/p' "$hype_sh")

    echo "$fn_block" | grep 'blocked_ids=' | grep -q 'status.*!=.*closed'
}

@test "hype.sh: call_manager retry_ids filters closed tasks" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local fn_block
    fn_block=$(sed -n '/^call_manager_for_problems()/,/^}/p' "$hype_sh")

    echo "$fn_block" | grep 'retry_ids=' | grep -q 'status.*!=.*closed'
}

@test "hype.sh: generate_iteration_stats blocked count filters closed tasks" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local fn_block
    fn_block=$(sed -n '/^generate_iteration_stats()/,/^}/p' "$hype_sh")

    echo "$fn_block" | grep 'blocked=' | grep -q 'status.*!=.*closed'
}

@test "hype.sh: generate_iteration_stats blocked_details filters closed tasks" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    local fn_block
    fn_block=$(sed -n '/^generate_iteration_stats()/,/^}/p' "$hype_sh")

    echo "$fn_block" | grep 'blocked_details=' | grep -q 'status.*!=.*closed'
}

# =============================================================================
# Integration: all tick-cache label filters have status guard
# =============================================================================

@test "all tick-cache jq label filters in hype.sh have status guard" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Find all jq expressions that filter by labels from tick-cache/bd_cache
    # Pattern: select(.labels[]? ...) without preceding select(.status != "closed")
    # We check that every select(.labels[]? | startswith("blocked:")) has status guard
    local violations=0

    # Check: blocked: label filters
    while IFS= read -r line; do
        local lineno content
        lineno=$(echo "$line" | cut -d: -f1)
        content=$(echo "$line" | cut -d: -f2-)

        # Skip if already has status filter
        if echo "$content" | grep -q 'status.*!=.*closed'; then
            continue
        fi

        # Skip if it's in detect-phase.sh or not label-related
        echo "Line $lineno missing status guard: $content" >&2
        ((violations++)) || true
    done < <(grep -n 'select(.labels\[\]\? | startswith("blocked:")' "$hype_sh" || true)

    [ "$violations" -eq 0 ]
}
