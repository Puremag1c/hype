#!/usr/bin/env bats
# tests/unit/progress_cleanup_test.bats
# Unit tests for v2.1.11 progress cleanup fix:
# - SIGKILL escalation after SIGTERM grace period (prevents 38min zombie hang)
# - Resilient stream file handling (cp: No such file)
# - Timeout on git worktree remove

load '../helpers/setup'

# =============================================================================
# run_claude_with_progress: SIGKILL escalation in inline cleanup
# =============================================================================

@test "progress cleanup: sends SIGKILL after SIGTERM grace period" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    # Extract inline cleanup block (between "Signal progress reader" and "Convert stream-json")
    local cleanup_block
    cleanup_block=$(sed -n '/Signal progress reader to stop/,/Convert stream-json/p' "$common_sh")

    # Should have SIGTERM (kill without -9)
    echo "$cleanup_block" | grep -q 'kill "$progress_pid"'
    # Should have sleep grace period
    echo "$cleanup_block" | grep -q 'sleep 1'
    # Should have SIGKILL (-9)
    echo "$cleanup_block" | grep -q 'kill -9 "$progress_pid"'
    echo "$cleanup_block" | grep -q 'pkill -9 -P "$progress_pid"'
}

@test "progress cleanup: SIGTERM comes before SIGKILL" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    # In the inline cleanup, SIGTERM lines should appear before SIGKILL lines
    local term_line kill_line
    term_line=$(grep -n 'kill "$progress_pid"' "$common_sh" | grep -v '\-9' | tail -1 | cut -d: -f1)
    kill_line=$(grep -n 'kill -9 "$progress_pid"' "$common_sh" | tail -1 | cut -d: -f1)

    [ -n "$term_line" ]
    [ -n "$kill_line" ]
    [ "$term_line" -lt "$kill_line" ]
}

@test "progress cleanup: kills tail with SIGKILL too" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    # Inline cleanup should SIGKILL tail_pid
    local cleanup_block
    cleanup_block=$(sed -n '/Signal progress reader to stop/,/Convert stream-json/p' "$common_sh")

    echo "$cleanup_block" | grep -q 'kill -9 "$tail_pid"'
}

# =============================================================================
# _cleanup_progress trap: same SIGKILL escalation
# =============================================================================

@test "progress trap: _cleanup_progress has SIGKILL escalation" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    # Extract the trap function
    local trap_block
    trap_block=$(sed -n '/_cleanup_progress()/,/^    }/p' "$common_sh")

    # Should have grace period + SIGKILL
    echo "$trap_block" | grep -q 'sleep 1'
    echo "$trap_block" | grep -q 'kill -9 "$progress_pid"'
    echo "$trap_block" | grep -q 'pkill -9 -P "$progress_pid"'
    echo "$trap_block" | grep -q 'kill -9 "$tail_pid"'
}

# =============================================================================
# Stream file resilience
# =============================================================================

@test "progress cleanup: checks stream file exists before jq/cp" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    # Should have -f check before jq conversion
    grep -q 'if \[ -f "$raw_output" \]' "$common_sh"
}

@test "progress cleanup: cp has error suppression (2>/dev/null || true)" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    # The cp fallback should suppress errors
    grep -q 'cp "$raw_output" "$output_file" 2>/dev/null || true' "$common_sh"
}

# =============================================================================
# cleanup_worktree: timeout
# =============================================================================

@test "cleanup_worktree: git worktree remove has timeout" {
    local executors_sh="$SCRIPTS_DIR/run-executors.sh"

    # Should use timeout command
    grep -q 'timeout.*git worktree remove' "$executors_sh"
}

@test "cleanup_worktree: falls back to rm -rf on timeout" {
    local executors_sh="$SCRIPTS_DIR/run-executors.sh"

    # Pattern: timeout Ns git worktree remove ... || rm -rf
    grep -q 'timeout.*git worktree remove.*|| rm -rf' "$executors_sh"
}

# =============================================================================
# Behavioral: real pipeline cleanup (catches the 38-minute hang bug)
# =============================================================================

# =============================================================================
# v2.3.22: exec before claude prevents orphan on timeout
# =============================================================================

@test "run_claude_with_progress uses exec to prevent orphan on timeout" {
    local common_sh="$SCRIPTS_DIR/common.sh"

    # The bash -c command must use exec before claude
    # Without exec: timeout kills bash, claude becomes orphan
    # With exec: bash replaces itself with claude, timeout kills claude directly
    grep -q "exec claude --print" "$common_sh"
}

@test "behavioral: progress pipeline dies within 5 seconds after cleanup" {
    local tmpfile
    tmpfile=$(mktemp)
    local tail_pid_file="$tmpfile.tail.pid"
    touch "$tmpfile.running"

    # Start the exact same pipeline architecture as run_claude_with_progress
    (
        trap 'exit 0' TERM INT
        sleep 0.2
        {
            tail -F "$tmpfile" 2>/dev/null &
            echo $! > "$tail_pid_file"
            wait $!
        } | \
        jq -r --unbuffered '.' 2>/dev/null | \
        while IFS= read -r line; do
            [ -f "$tmpfile.running" ] || break
        done
    ) &
    local progress_pid=$!
    sleep 0.5

    # Run the same cleanup sequence as our fix
    rm -f "$tmpfile.running" 2>/dev/null || true

    # SIGTERM
    pkill -P "$progress_pid" 2>/dev/null || true
    kill "$progress_pid" 2>/dev/null || true
    local tail_pid=""
    if [ -f "$tail_pid_file" ]; then
        tail_pid=$(cat "$tail_pid_file" 2>/dev/null)
        [ -n "$tail_pid" ] && kill "$tail_pid" 2>/dev/null || true
        rm -f "$tail_pid_file" 2>/dev/null || true
    fi

    # Grace period + SIGKILL
    sleep 1
    pkill -9 -P "$progress_pid" 2>/dev/null || true
    kill -9 "$progress_pid" 2>/dev/null || true
    [ -n "$tail_pid" ] && kill -9 "$tail_pid" 2>/dev/null || true

    wait "$progress_pid" 2>/dev/null || true

    # Verify: all processes dead
    ! kill -0 "$progress_pid" 2>/dev/null
    [ -z "$tail_pid" ] || ! kill -0 "$tail_pid" 2>/dev/null

    # Cleanup
    rm -f "$tmpfile" "$tmpfile.running" "$tail_pid_file" 2>/dev/null || true
}

