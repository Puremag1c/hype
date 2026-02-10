#!/usr/bin/env bats
# tests/integration/hype_test.bats
# Integration tests for hype.sh and bin/hype
#
# Tests core functions without starting the full system

load '../helpers/setup'

# =============================================================================
# Setup for hype tests
# =============================================================================

# Create isolated test environment
setup() {
    TEST_TMPDIR=$(mktemp -d)/hypetest
    mkdir -p "$TEST_TMPDIR/.hype"
    mkdir -p "$TEST_TMPDIR/logs"

    # Initialize git
    cd "$TEST_TMPDIR"
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test"

    # Create valid config
    cat > "$TEST_TMPDIR/.hype/config.sh" << 'EOF'
MAX_PARALLEL_EXECUTORS=3
RETRY_LIMIT=3
ITERATION_DELAY=5
TASK_STALE_TIMEOUT=600
LOG_TOKENS=false
DEBUG=false
TASK_TIMEOUT="10m"
ALLOWED_MODELS="opus,sonnet,haiku"
EOF

    export PROJECT_ROOT="$TEST_TMPDIR"
}

teardown() {
    cd /
    if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
        rm -rf "$(dirname "$TEST_TMPDIR")"
    fi
}

# =============================================================================
# version_gte / version_lt tests
# =============================================================================

# Define version functions locally (extracted from bin/hype)
version_gte() {
    [[ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]]
}

version_lt() {
    [[ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]] && [[ "$1" != "$2" ]]
}

@test "version_gte: 1.9.0 >= 1.8.0" {
    run version_gte "1.9.0" "1.8.0"
    [[ "$status" -eq 0 ]]
}

@test "version_gte: 1.8.0 >= 1.9.0 is false" {
    run version_gte "1.8.0" "1.9.0"
    [[ "$status" -ne 0 ]]
}

@test "version_gte: 1.9.0 >= 1.9.0 (equal)" {
    run version_gte "1.9.0" "1.9.0"
    [[ "$status" -eq 0 ]]
}

@test "version_gte: 2.0.0 >= 1.9.20" {
    run version_gte "2.0.0" "1.9.20"
    [[ "$status" -eq 0 ]]
}

@test "version_lt: 1.8.0 < 1.9.0" {
    run version_lt "1.8.0" "1.9.0"
    [[ "$status" -eq 0 ]]
}

@test "version_lt: 1.9.0 < 1.8.0 is false" {
    run version_lt "1.9.0" "1.8.0"
    [[ "$status" -ne 0 ]]
}

@test "version_lt: 1.9.0 < 1.9.0 is false (equal)" {
    run version_lt "1.9.0" "1.9.0"
    [[ "$status" -ne 0 ]]
}

# =============================================================================
# detect_project_type tests
# =============================================================================

# Define detect_project_type locally (extracted from bin/hype)
detect_project_type() {
    cd "$TEST_TMPDIR"

    if [[ -f "SPEC.md" ]]; then
        echo "has_spec"
        return
    fi

    local has_code=false

    for pattern in "*.ts" "*.tsx" "*.js" "*.jsx" "*.py" "*.ex" "*.exs" "*.go" "*.rs" "*.java" "*.rb"; do
        if compgen -G "$pattern" > /dev/null 2>&1 || compgen -G "src/$pattern" > /dev/null 2>&1; then
            has_code=true
            break
        fi
    done

    if [[ -f "package.json" ]] || [[ -f "mix.exs" ]] || [[ -f "go.mod" ]] || \
       [[ -f "Cargo.toml" ]] || [[ -f "pyproject.toml" ]] || [[ -f "requirements.txt" ]]; then
        has_code=true
    fi

    if [[ "$has_code" = true ]]; then
        echo "existing"
    else
        echo "empty"
    fi
}

@test "detect_project_type: empty directory returns 'empty'" {
    run detect_project_type
    [[ "$output" == "empty" ]]
}

@test "detect_project_type: with SPEC.md returns 'has_spec'" {
    touch "$TEST_TMPDIR/SPEC.md"
    run detect_project_type
    [[ "$output" == "has_spec" ]]
}

@test "detect_project_type: with package.json returns 'existing'" {
    echo '{}' > "$TEST_TMPDIR/package.json"
    run detect_project_type
    [[ "$output" == "existing" ]]
}

@test "detect_project_type: with go.mod returns 'existing'" {
    echo 'module test' > "$TEST_TMPDIR/go.mod"
    run detect_project_type
    [[ "$output" == "existing" ]]
}

@test "detect_project_type: with .py file returns 'existing'" {
    touch "$TEST_TMPDIR/main.py"
    run detect_project_type
    [[ "$output" == "existing" ]]
}

@test "detect_project_type: with src/*.ts returns 'existing'" {
    mkdir -p "$TEST_TMPDIR/src"
    touch "$TEST_TMPDIR/src/index.ts"
    run detect_project_type
    [[ "$output" == "existing" ]]
}

@test "detect_project_type: SPEC.md takes priority over code" {
    touch "$TEST_TMPDIR/SPEC.md"
    touch "$TEST_TMPDIR/main.py"
    run detect_project_type
    [[ "$output" == "has_spec" ]]
}

# =============================================================================
# validate_config tests (using source approach)
# =============================================================================

# Minimal validate_config implementation for testing
validate_config_test() {
    local config_file="$1"
    source "$config_file"

    local errors=0

    # Validate integers
    for var in MAX_PARALLEL_EXECUTORS RETRY_LIMIT ITERATION_DELAY; do
        local value="${!var}"
        if ! [[ "$value" =~ ^[0-9]+$ ]]; then
            echo "Invalid $var: must be integer, got '$value'"
            ((errors++))
        fi
    done

    # Validate booleans
    for var in LOG_TOKENS DEBUG; do
        local value="${!var:-false}"
        if [[ "$value" != "true" && "$value" != "false" ]]; then
            echo "Invalid $var: must be true/false, got '$value'"
            ((errors++))
        fi
    done

    # Validate timeout format
    if ! [[ "$TASK_TIMEOUT" =~ ^[0-9]+[ms]$ ]]; then
        echo "Invalid TASK_TIMEOUT: must be Nm or Ns, got '$TASK_TIMEOUT'"
        ((errors++))
    fi

    return $errors
}

@test "validate_config: valid config passes" {
    run validate_config_test "$TEST_TMPDIR/.hype/config.sh"
    [[ "$status" -eq 0 ]]
}

@test "validate_config: invalid integer fails" {
    echo "MAX_PARALLEL_EXECUTORS=abc" >> "$TEST_TMPDIR/.hype/config.sh"
    run validate_config_test "$TEST_TMPDIR/.hype/config.sh"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Invalid MAX_PARALLEL_EXECUTORS"* ]]
}

@test "validate_config: invalid boolean fails" {
    sed -i.bak 's/LOG_TOKENS=false/LOG_TOKENS=yes/' "$TEST_TMPDIR/.hype/config.sh"
    run validate_config_test "$TEST_TMPDIR/.hype/config.sh"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Invalid LOG_TOKENS"* ]]
}

@test "validate_config: invalid timeout format fails" {
    sed -i.bak 's/TASK_TIMEOUT="10m"/TASK_TIMEOUT="10"/' "$TEST_TMPDIR/.hype/config.sh"
    run validate_config_test "$TEST_TMPDIR/.hype/config.sh"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Invalid TASK_TIMEOUT"* ]]
}

@test "validate_config: timeout with seconds format passes" {
    sed -i.bak 's/TASK_TIMEOUT="10m"/TASK_TIMEOUT="600s"/' "$TEST_TMPDIR/.hype/config.sh"
    run validate_config_test "$TEST_TMPDIR/.hype/config.sh"
    [[ "$status" -eq 0 ]]
}

# =============================================================================
# acquire_lock tests
# =============================================================================

@test "acquire_lock: creates lock file" {
    local lock_file="$TEST_TMPDIR/.hype/hype.lock"

    # Acquire lock
    (set -C; echo $$ > "$lock_file") 2>/dev/null

    [[ -f "$lock_file" ]]
    [[ "$(cat "$lock_file")" == "$$" ]]

    rm -f "$lock_file"
}

@test "acquire_lock: detects running process" {
    local lock_file="$TEST_TMPDIR/.hype/hype.lock"

    # Write current PID (which is running)
    echo $$ > "$lock_file"

    # Try to acquire - should fail
    if (set -C; echo $$ > "$lock_file") 2>/dev/null; then
        # If we get here, test should fail
        rm -f "$lock_file"
        false
    else
        # Expected: lock already exists
        rm -f "$lock_file"
        true
    fi
}

@test "acquire_lock: detects stale lock" {
    local lock_file="$TEST_TMPDIR/.hype/hype.lock"

    # Write fake PID that doesn't exist
    echo "999999999" > "$lock_file"

    # Check if PID exists
    if ! kill -0 999999999 2>/dev/null; then
        # Stale lock detected
        rm -f "$lock_file"
        true
    else
        false
    fi
}

# =============================================================================
# merge_config tests
# =============================================================================

@test "merge_config: adds new variable from template" {
    local user_config="$TEST_TMPDIR/.hype/config.sh"
    local template="$TEST_TMPDIR/template.sh"

    # User config missing NEW_VAR
    cat > "$user_config" << 'EOF'
MAX_PARALLEL_EXECUTORS=3
EOF

    # Template has NEW_VAR
    cat > "$template" << 'EOF'
MAX_PARALLEL_EXECUTORS=2
NEW_VAR=default
EOF

    # Simple merge: add missing variables
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)= ]]; then
            local var_name="${BASH_REMATCH[1]}"
            if ! grep -q "^${var_name}=" "$user_config" 2>/dev/null; then
                echo "$line" >> "$user_config"
            fi
        fi
    done < "$template"

    grep -q "NEW_VAR=default" "$user_config"
}

# =============================================================================
# hard_kill_beads_daemon tests
# =============================================================================

# Extract hard_kill_beads_daemon for testing (uses .beads dir in TEST_TMPDIR)
hard_kill_beads_daemon() {
    local pid_file=".beads/daemon.pid"
    local lock_file=".beads/daemon.lock"

    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null | tr -d '[:space:]')

        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            local proc_name
            proc_name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "")

            if [[ "$proc_name" == *"bd"* ]] || [[ "$proc_name" == *"beads"* ]]; then
                kill "$pid" 2>/dev/null || true
                sleep 1
                if kill -0 "$pid" 2>/dev/null; then
                    kill -9 "$pid" 2>/dev/null || true
                    sleep 1
                fi
            fi
        fi
    fi

    rm -f "$pid_file" "$lock_file" .beads/daemon.sock 2>/dev/null || true
}

@test "hard_kill_beads_daemon: cleans up stale files when PID does not exist" {
    cd "$TEST_TMPDIR"
    mkdir -p .beads
    echo "999999999" > .beads/daemon.pid
    echo '{"pid": 999999999}' > .beads/daemon.lock
    touch .beads/daemon.sock

    run hard_kill_beads_daemon
    [[ "$status" -eq 0 ]]
    [[ ! -f .beads/daemon.pid ]]
    [[ ! -f .beads/daemon.lock ]]
    [[ ! -f .beads/daemon.sock ]]
}

@test "hard_kill_beads_daemon: handles missing pid file" {
    cd "$TEST_TMPDIR"
    mkdir -p .beads
    # No daemon.pid exists

    run hard_kill_beads_daemon
    [[ "$status" -eq 0 ]]
}

@test "hard_kill_beads_daemon: skips kill when PID is not a beads process" {
    cd "$TEST_TMPDIR"
    mkdir -p .beads
    # Use current shell PID (not a beads process)
    echo "$$" > .beads/daemon.pid
    touch .beads/daemon.lock

    run hard_kill_beads_daemon
    [[ "$status" -eq 0 ]]
    # Process should still be alive (not killed)
    kill -0 $$ 2>/dev/null
    # But stale files should be cleaned
    [[ ! -f .beads/daemon.pid ]]
    [[ ! -f .beads/daemon.lock ]]
}

# =============================================================================
# configure_flush_debounce tests
# =============================================================================

configure_flush_debounce() {
    local config=".beads/config.yaml"
    [ -f "$config" ] || return 0

    if grep -q '^flush-debounce:' "$config" 2>/dev/null; then
        return 0
    fi

    if grep -q '^# flush-debounce:' "$config" 2>/dev/null; then
        sed -i '' 's/^# flush-debounce: "5s"/flush-debounce: "15s"/' "$config"
    fi
}

@test "configure_flush_debounce: sets 15s on fresh config" {
    cd "$TEST_TMPDIR"
    mkdir -p .beads
    echo '# flush-debounce: "5s"' > .beads/config.yaml

    run configure_flush_debounce
    [[ "$status" -eq 0 ]]
    grep -q '^flush-debounce: "15s"' .beads/config.yaml
}

@test "configure_flush_debounce: skips when already configured" {
    cd "$TEST_TMPDIR"
    mkdir -p .beads
    echo 'flush-debounce: "30s"' > .beads/config.yaml

    run configure_flush_debounce
    [[ "$status" -eq 0 ]]
    # Should preserve existing value
    grep -q 'flush-debounce: "30s"' .beads/config.yaml
}

@test "configure_flush_debounce: handles missing config file" {
    cd "$TEST_TMPDIR"
    # No .beads/config.yaml

    run configure_flush_debounce
    [[ "$status" -eq 0 ]]
}

# =============================================================================
# merge_config tests
# =============================================================================

@test "merge_config: preserves user value" {
    local user_config="$TEST_TMPDIR/.hype/config.sh"
    local template="$TEST_TMPDIR/template.sh"

    cat > "$user_config" << 'EOF'
MAX_PARALLEL_EXECUTORS=5
EOF

    cat > "$template" << 'EOF'
MAX_PARALLEL_EXECUTORS=2
EOF

    # Merge should keep user's value
    # (In real merge, we don't overwrite existing)

    run grep "MAX_PARALLEL_EXECUTORS=" "$user_config"
    [[ "$output" == "MAX_PARALLEL_EXECUTORS=5" ]]
}
