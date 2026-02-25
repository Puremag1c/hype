#!/usr/bin/env bats
# tests/unit/doctor_report_test.bats
# Unit tests for doctor.sh report functions (v2.3)

load '../helpers/setup'

# =============================================================================
# Helper: source doctor.sh functions into test environment
# =============================================================================

source_doctor_functions() {
    # Extract only the report functions block from doctor.sh
    local tmp_funcs="$TEST_TMPDIR/doctor_funcs.sh"
    sed -n '/^# === Report functions ===/,/^# === Gather context ===/p' "$SCRIPTS_DIR/doctor.sh" > "$tmp_funcs"

    # Set required variables before sourcing
    PROJECT_DIR="$TEST_PROJECT_DIR"
    CLAUDEV_DIR="$TEST_PROJECT_DIR/.hype"
    LOGS_DIR="$TEST_LOGS_DIR"
    HOME="${HOME}"
    mkdir -p "$CLAUDEV_DIR/logs"

    source "$tmp_funcs"
}

# =============================================================================
# sanitize_doctor_report tests
# =============================================================================

@test "sanitize_doctor_report: replaces HOME, PROJECT_DIR, API keys, Bearer tokens" {
    source_doctor_functions

    local test_file="$TEST_TMPDIR/report.md"
    cat > "$test_file" << EOF
Path: $HOME/some/path
Project: $TEST_PROJECT_DIR/src/main.go
Key: ANTHROPIC_API_KEY=some-secret-value-here
Standalone: sk-ant-abc123def456ghi789jkl012mno
Token: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.test
Normal: this should stay
EOF

    sanitize_doctor_report "$test_file"

    # HOME replaced with ~
    run grep -c "$HOME" "$test_file"
    [[ "$output" == "0" ]]
    run grep -c '~/some/path' "$test_file"
    [[ "$output" == "1" ]]

    # PROJECT_DIR replaced with $PROJECT
    run grep -c "$TEST_PROJECT_DIR" "$test_file"
    [[ "$output" == "0" ]]

    # API key redacted
    run grep -c '\[REDACTED\]' "$test_file"
    [[ "$output" -ge 1 ]]

    # sk-* key redacted
    run grep -c '\[REDACTED_KEY\]' "$test_file"
    [[ "$output" -ge 1 ]]

    # Bearer token redacted
    run grep -c 'Bearer \[REDACTED\]' "$test_file"
    [[ "$output" == "1" ]]
}

@test "sanitize_doctor_report: does not break normal content" {
    source_doctor_functions

    local test_file="$TEST_TMPDIR/report.md"
    cat > "$test_file" << 'EOF'
# Doctor Log
Date: 2026-02-11
Normal diagnostic output
bd stats shows 5 open tasks
No secrets here
EOF

    local before
    before=$(cat "$test_file")
    sanitize_doctor_report "$test_file"
    local after
    after=$(cat "$test_file")

    [[ "$before" == "$after" ]]
}

# =============================================================================
# check_gh_available tests
# =============================================================================

@test "check_gh_available: returns 1 without gh" {
    source_doctor_functions

    # Override PATH to exclude gh
    PATH="/usr/bin:/bin" run check_gh_available
    [[ "$status" -ne 0 ]]
}

# =============================================================================
# find_latest_doctor_log tests
# =============================================================================

@test "find_latest_doctor_log: finds fresh log, ignores old" {
    source_doctor_functions

    # Create an old log (touch with old timestamp)
    local old_file="$CLAUDEV_DIR/logs/doctor-20250101-120000.md"
    echo "old" > "$old_file"
    touch -t 202501011200 "$old_file"

    # Record timestamp before creating fresh log
    local since_ts
    since_ts=$(date +%s)
    sleep 1

    # Create a fresh log
    local fresh_file="$CLAUDEV_DIR/logs/doctor-20260211-150000.md"
    echo "fresh" > "$fresh_file"

    local result
    result=$(find_latest_doctor_log "$since_ts")
    [[ "$result" == "$fresh_file" ]]
}

# =============================================================================
# send_doctor_report tests
# =============================================================================

@test "send_doctor_report: extracts title from Reported Symptom" {
    source_doctor_functions

    local test_file="$TEST_TMPDIR/report.md"
    cat > "$test_file" << 'EOF'
# Doctor Log

## Reported Symptom
Tasks stuck in CODING phase for 30 minutes

## Collected Data
...
EOF

    # Mock gh to capture args
    gh() {
        echo "CALLED: $*"
    }
    export -f gh

    run send_doctor_report "$test_file"
    [[ "$output" == *"Tasks stuck in CODING phase for 30 minutes"* ]]
}

@test "send_doctor_report: fallback title when section missing" {
    source_doctor_functions

    local test_file="$TEST_TMPDIR/report.md"
    cat > "$test_file" << 'EOF'
# Doctor Log
No symptom section here
EOF

    # Mock gh to capture args
    gh() {
        echo "CALLED: $*"
    }
    export -f gh

    run send_doctor_report "$test_file"
    [[ "$output" == *"Doctor report"* ]]
}

# =============================================================================
# Source pattern tests
# =============================================================================

@test "doctor.sh: all 5 report functions exist" {
    local doctor="$SCRIPTS_DIR/doctor.sh"
    grep -q '^sanitize_doctor_report()' "$doctor"
    grep -q '^check_gh_available()' "$doctor"
    grep -q '^find_latest_doctor_log()' "$doctor"
    grep -q '^save_report_output()' "$doctor"
    grep -q '^send_doctor_report()' "$doctor"
}

@test "doctor.sh: hardcoded repo is Puremag1c/hype" {
    local doctor="$SCRIPTS_DIR/doctor.sh"
    grep -q 'Puremag1c/hype' "$doctor"
}

@test "doctor.sh: all claude calls use --allowedTools" {
    local doctor="$SCRIPTS_DIR/doctor.sh"
    # Every 'claude' invocation inside run_doctor must include --allowedTools
    # Extract lines with 'claude --model' (actual agent calls, not help/version checks)
    local claude_calls
    claude_calls=$(grep -c 'claude --model.*--allowedTools\|claude.*--print.*--allowedTools\|claude.*--allowedTools.*--model' "$doctor")
    # There should be exactly 2 calls: report-only (--print) and interactive
    [[ "$claude_calls" -ge 2 ]]
}

@test "doctor.sh: allowedTools includes safe bd commands" {
    local doctor="$SCRIPTS_DIR/doctor.sh"
    grep -q 'Bash(bd list:\*)' "$doctor"
    grep -q 'Bash(bd show:\*)' "$doctor"
    grep -q 'Bash(bd stats:\*)' "$doctor"
    grep -q 'Bash(bd blocked:\*)' "$doctor"
    grep -q 'Bash(bd info:\*)' "$doctor"
    grep -q 'Bash(bd doctor:\*)' "$doctor"
}

@test "doctor.sh: allowedTools includes Write for doctor-log" {
    local doctor="$SCRIPTS_DIR/doctor.sh"
    local allowed_block
    allowed_block=$(sed -n "/local allowed_tools=/,/^$/p" "$doctor")
    echo "$allowed_block" | grep -q 'Write'
}

@test "doctor.sh: allowedTools includes bd runtime-fix commands" {
    local doctor="$SCRIPTS_DIR/doctor.sh"
    local allowed_block
    allowed_block=$(sed -n "/local allowed_tools=/,/^$/p" "$doctor")
    echo "$allowed_block" | grep -q 'bd update'
    echo "$allowed_block" | grep -q 'bd close'
    echo "$allowed_block" | grep -q 'bd admin'
}

@test "doctor.sh: allowedTools does NOT include destructive commands" {
    local doctor="$SCRIPTS_DIR/doctor.sh"
    local allowed_block
    allowed_block=$(sed -n "/local allowed_tools=/,/^$/p" "$doctor")
    ! echo "$allowed_block" | grep -q 'pkill'
    ! echo "$allowed_block" | grep -q 'rm '
    ! echo "$allowed_block" | grep -q 'git reset'
    ! echo "$allowed_block" | grep -q 'git push'
}
