#!/usr/bin/env bats
# tests/unit/timezone_test.bats
# Tests for UTC timestamp parsing (v2.5.4 — GitHub #18 timezone bug)

load '../helpers/setup'

# =============================================================================
# parse_utc_epoch function tests
# =============================================================================

@test "tz: parse_utc_epoch defined and exported in common.sh" {
    grep -q '^parse_utc_epoch()' "$SCRIPTS_DIR/common.sh"
    grep -q 'export -f parse_utc_epoch' "$SCRIPTS_DIR/common.sh"
}

@test "tz: parse_utc_epoch uses TZ=UTC" {
    local body
    body=$(sed -n '/^parse_utc_epoch()/,/^}/p' "$SCRIPTS_DIR/common.sh")
    echo "$body" | grep -q 'TZ=UTC'
}

@test "tz: parse_utc_epoch parses Z-suffix timestamps correctly" {
    # Known timestamp: 2026-01-01T00:00:00Z = 1767225600
    local result
    result=$(parse_utc_epoch "2026-01-01T00:00:00Z")
    [[ "$result" -eq 1767225600 ]]
}

@test "tz: parse_utc_epoch strips milliseconds" {
    local with_ms without_ms
    with_ms=$(parse_utc_epoch "2026-01-01T00:00:00.123456Z")
    without_ms=$(parse_utc_epoch "2026-01-01T00:00:00Z")
    [[ "$with_ms" -eq "$without_ms" ]]
}

@test "tz: parse_utc_epoch strips +offset" {
    # Input has +03:00 but we strip it and parse as UTC
    # This matches pre-Dolt behavior where offset was explicit
    local result
    result=$(parse_utc_epoch "2026-01-01T00:00:00+03:00")
    [[ "$result" -eq 1767225600 ]]
}

@test "tz: parse_utc_epoch returns 0 for empty input" {
    local result
    result=$(parse_utc_epoch "")
    [[ "$result" -eq 0 ]]
}

# =============================================================================
# Behavioral: timezone-forcing tests (reproduces GitHub #18)
# These run parse_utc_epoch under non-UTC timezone to catch the exact bug
# =============================================================================

@test "tz: parse_utc_epoch gives same result under TZ=Europe/Moscow" {
    local utc_result msk_result
    utc_result=$(TZ=UTC parse_utc_epoch "2026-01-01T12:00:00Z")
    msk_result=$(TZ=Europe/Moscow parse_utc_epoch "2026-01-01T12:00:00Z")
    [[ "$utc_result" -eq "$msk_result" ]]
}

@test "tz: parse_utc_epoch gives same result under TZ=US/Pacific" {
    local utc_result pst_result
    utc_result=$(TZ=UTC parse_utc_epoch "2026-06-15T08:30:00Z")
    pst_result=$(TZ=US/Pacific parse_utc_epoch "2026-06-15T08:30:00Z")
    [[ "$utc_result" -eq "$pst_result" ]]
}

@test "tz: parse_utc_epoch gives same result under TZ=Asia/Tokyo (+9)" {
    local utc_result jst_result
    utc_result=$(TZ=UTC parse_utc_epoch "2026-03-10T23:59:59Z")
    jst_result=$(TZ=Asia/Tokyo parse_utc_epoch "2026-03-10T23:59:59Z")
    [[ "$utc_result" -eq "$jst_result" ]]
}

@test "tz: age calculation is correct under non-UTC timezone" {
    # Simulate what reset_stale_tasks does: now - task_epoch
    local task_ts="2026-01-01T12:00:00Z"
    # Known epoch for this timestamp: 1767268800
    local expected_epoch=1767268800

    local msk_epoch
    msk_epoch=$(TZ=Europe/Moscow parse_utc_epoch "$task_ts")

    # The epoch must match regardless of local timezone
    [[ "$msk_epoch" -eq "$expected_epoch" ]]
}

# =============================================================================
# All date parsing uses parse_utc_epoch (no raw date commands)
# =============================================================================

@test "tz: reset_stale_tasks uses parse_utc_epoch" {
    local body
    body=$(sed -n '/^reset_stale_tasks()/,/^}/p' "$SCRIPTS_DIR/common.sh")
    echo "$body" | grep -q 'parse_utc_epoch'
    ! echo "$body" | grep -q 'date -j'
}

@test "tz: hype.sh heal_stuck_tasks uses parse_utc_epoch" {
    local body
    body=$(sed -n '/^heal_stuck_tasks()/,/^}/p' "$SCRIPTS_DIR/hype.sh")
    echo "$body" | grep -q 'parse_utc_epoch'
    ! echo "$body" | grep -q 'date -j'
}

@test "tz: no raw date -jf parsing in hype.sh" {
    ! grep -q 'date -jf.*%Y-%m-%dT' "$SCRIPTS_DIR/hype.sh"
}

@test "tz: no raw date -j -f parsing outside parse_utc_epoch in common.sh" {
    # Only parse_utc_epoch should have date -j -f
    local count
    count=$(grep -c 'date -j.*%Y-%m-%dT' "$SCRIPTS_DIR/common.sh")
    [[ "$count" -eq 1 ]]  # Only inside parse_utc_epoch
}

# =============================================================================
# get_ready_tasks excludes needs-review (v2.5.4 — prevent re-claim)
# =============================================================================

@test "tz: get_ready_tasks excludes needs-review tasks" {
    grep -q 'needs-review' "$SCRIPTS_DIR/run-coders.sh"
    local func_block
    func_block=$(sed -n '/^get_ready_tasks()/,/^}/p' "$SCRIPTS_DIR/run-coders.sh")
    echo "$func_block" | grep -q 'needs-review'
}
