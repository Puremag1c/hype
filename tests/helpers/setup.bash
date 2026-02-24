#!/usr/bin/env bash
# tests/helpers/setup.bash
# Common setup/teardown for bats tests

# Project root (tests are in $PROJECT_ROOT/tests/)
export PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
export CORE_DIR="$PROJECT_ROOT/core"
export SCRIPTS_DIR="$CORE_DIR/scripts"
export AGENTS_DIR="$CORE_DIR/agents"

# Source common.sh functions
# shellcheck source=../../core/scripts/common.sh
source "$SCRIPTS_DIR/common.sh"

# Temporary directories for test isolation
export TEST_TMPDIR=""
export TEST_PROJECT_DIR=""
export TEST_LOGS_DIR=""

# Setup function: called before each test
setup() {
    # Create isolated temp directory for each test
    TEST_TMPDIR=$(mktemp -d)
    TEST_PROJECT_DIR="$TEST_TMPDIR/project"
    TEST_LOGS_DIR="$TEST_TMPDIR/logs"

    mkdir -p "$TEST_PROJECT_DIR"
    mkdir -p "$TEST_LOGS_DIR"
    mkdir -p "$TEST_PROJECT_DIR/.hype"

    # Initialize minimal git repo for tests that need it
    git -C "$TEST_PROJECT_DIR" init --quiet 2>/dev/null || true
    git -C "$TEST_PROJECT_DIR" config user.email "test@example.com" 2>/dev/null || true
    git -C "$TEST_PROJECT_DIR" config user.name "Test User" 2>/dev/null || true

    # Export for use in tests
    export TEST_TMPDIR TEST_PROJECT_DIR TEST_LOGS_DIR
}

# Teardown function: called after each test
teardown() {
    # Cleanup temp directory
    if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

# Helper: create a test file with content
# Usage: create_test_file "path/to/file" "content"
create_test_file() {
    local file_path="$1"
    local content="$2"
    local full_path="$TEST_PROJECT_DIR/$file_path"

    mkdir -p "$(dirname "$full_path")"
    echo "$content" > "$full_path"
}

# Helper: create minimal hype config
# Usage: create_test_config
create_test_config() {
    cat > "$TEST_PROJECT_DIR/.hype/config.sh" << 'EOF'
MAX_PARALLEL_CODERS=2
RETRY_LIMIT=2
TASK_TIMEOUT="5m"
ALLOWED_MODELS="opus,sonnet,haiku"
EOF
}

# Helper: assert file exists
# Usage: assert_file_exists "path/to/file"
assert_file_exists() {
    local file_path="$1"
    local full_path="$TEST_PROJECT_DIR/$file_path"

    if [[ ! -f "$full_path" ]]; then
        echo "Expected file to exist: $file_path" >&2
        return 1
    fi
}

# Helper: assert file contains pattern
# Usage: assert_file_contains "path/to/file" "pattern"
assert_file_contains() {
    local file_path="$1"
    local pattern="$2"
    local full_path="$TEST_PROJECT_DIR/$file_path"

    if ! grep -q "$pattern" "$full_path" 2>/dev/null; then
        echo "Expected file '$file_path' to contain: $pattern" >&2
        echo "Actual content:" >&2
        cat "$full_path" >&2
        return 1
    fi
}

# Helper: run script from project
# Usage: run_script "scripts/common.sh" [args...]
run_script() {
    local script="$1"
    shift
    bash "$SCRIPTS_DIR/$script" "$@"
}

# Helper: skip slow tests in CI
# Usage: skip_if_ci "reason"
skip_if_ci() {
    if [[ -n "${CI:-}" ]]; then
        skip "$1 (CI)"
    fi
}

# Helper: skip tests that need daemon sync timing
# These are flaky in CI due to timing issues
skip_if_flaky() {
    if [[ -n "${CI:-}" ]]; then
        skip "Flaky in CI - timing dependent"
    fi
}
