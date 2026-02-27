#!/usr/bin/env bats
# tests/unit/reflexing_milestone_test.bats
# Tests for REFLEXING→TESTING infinite loop fix

load '../helpers/setup'

# =============================================================================
# REFLEXING sets testing-done milestone when no open tasks remain
# =============================================================================

@test "REFLEXING: checks post_reflexing_open count after QA triage" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Extract REFLEXING case block
    local case_block
    case_block=$(sed -n '/^        REFLEXING)/,/;;$/p' "$hype_sh")

    # Must query open tasks (excluding triggers) after triage
    echo "$case_block" | grep -q 'post_reflexing_open'
    echo "$case_block" | grep -q 'status=open AND NOT label=trigger'
}

@test "REFLEXING: sets milestone:testing-done when 0 open tasks" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Extract REFLEXING case block
    local case_block
    case_block=$(sed -n '/^        REFLEXING)/,/;;$/p' "$hype_sh")

    # Must call ensure_milestone when post_reflexing_open == 0
    echo "$case_block" | grep -q 'ensure_milestone "milestone:testing-done"'
}

@test "REFLEXING: milestone guard checks post_reflexing_open -eq 0" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Extract REFLEXING case block
    local case_block
    case_block=$(sed -n '/^        REFLEXING)/,/;;$/p' "$hype_sh")

    # Must have the -eq 0 guard (only set milestone when truly zero tasks)
    echo "$case_block" | grep -q 'post_reflexing_open.*-eq 0'
}

@test "REFLEXING: uses bd_safe for post-triage query (not raw bd)" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Extract REFLEXING case block
    local case_block
    case_block=$(sed -n '/^        REFLEXING)/,/;;$/p' "$hype_sh")

    # Must use bd_safe (not raw bd) for the query
    echo "$case_block" | grep 'post_reflexing_open' | grep -q 'bd_safe query'
}

@test "REFLEXING: post-triage query uses --limit 0" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Extract REFLEXING case block
    local case_block
    case_block=$(sed -n '/^        REFLEXING)/,/;;$/p' "$hype_sh")

    # Must use --limit 0 to get all results
    echo "$case_block" | grep 'post_reflexing_open' | grep -q '\-\-limit 0'
}

@test "REFLEXING: post-triage query has jq fallback" {
    local hype_sh="$SCRIPTS_DIR/hype.sh"

    # Extract REFLEXING case block
    local case_block
    case_block=$(sed -n '/^        REFLEXING)/,/;;$/p' "$hype_sh")

    # Must have fallback (|| echo "0") for pipeline safety
    echo "$case_block" | grep 'post_reflexing_open' | grep -q '|| echo "0"'
}
