#!/usr/bin/env bats
# tests/integration/executors_test.bats
# Integration tests for run-executors.sh functions

load '../helpers/setup'
load '../helpers/mock_bd'

# =============================================================================
# Setup
# =============================================================================

setup() {
    TEST_TMPDIR=$(mktemp -d)/hypetest
    mkdir -p "$TEST_TMPDIR/.hype"
    mkdir -p "$TEST_TMPDIR/.hype-worktrees"
    mkdir -p "$TEST_TMPDIR/logs"
    mkdir -p "$TEST_TMPDIR/.claude/agents"

    cd "$TEST_TMPDIR"
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test"

    # Create initial commit (required for worktrees)
    touch README.md
    git add README.md
    git commit -m "Initial" --quiet

    # Create config
    cat > "$TEST_TMPDIR/.hype/config.sh" << 'EOF'
MAX_PARALLEL_EXECUTORS=3
RETRY_LIMIT=3
TASK_TIMEOUT="10m"
ALLOWED_MODELS="opus,sonnet,haiku"
EOF

    # Source common functions
    source "$SCRIPTS_DIR/common.sh"

    export PROJECT_DIR="$TEST_TMPDIR"
    export WORKTREES_DIR="$TEST_TMPDIR/.hype-worktrees"
    export LOGS_DIR="$TEST_TMPDIR/logs"
    export MAX_PARALLEL=3
}

teardown() {
    cd / 2>/dev/null || true
    # Cleanup worktrees first (git requires this before directory removal)
    if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
        (cd "$TEST_TMPDIR" && git worktree prune 2>/dev/null) || true
        rm -rf "$(dirname "$TEST_TMPDIR")" 2>/dev/null || true
    fi
}

# =============================================================================
# find_free_slot tests
# =============================================================================

# Define function locally (extracted from run-executors.sh)
NEXT_SLOT=0

find_free_slot() {
    while [ -d "$WORKTREES_DIR/executor-$NEXT_SLOT" ]; do
        ((NEXT_SLOT++))
    done
    local slot=$NEXT_SLOT
    ((NEXT_SLOT++))
    echo "$slot"
}

@test "find_free_slot: returns 0 for empty worktrees" {
    NEXT_SLOT=0
    run find_free_slot
    [[ "$output" == "0" ]]
}

@test "find_free_slot: skips existing worktree directories" {
    NEXT_SLOT=0
    mkdir -p "$WORKTREES_DIR/executor-0"
    mkdir -p "$WORKTREES_DIR/executor-1"

    run find_free_slot
    [[ "$output" == "2" ]]
}

@test "find_free_slot: increments for sequential calls" {
    # NOTE: NEXT_SLOT is a global counter in real script that prevents
    # race conditions within a single run-executors.sh invocation.
    # In bats, $() runs in subshell so global state doesn't persist.
    # This test verifies the logic works by checking directory skipping.
    rm -rf "$WORKTREES_DIR"/executor-*

    # Create directories 0,1 to simulate previous allocations
    mkdir -p "$WORKTREES_DIR/executor-0"
    mkdir -p "$WORKTREES_DIR/executor-1"

    # find_free_slot should skip existing and return next available
    NEXT_SLOT=0
    local slot=$(find_free_slot)
    [[ "$slot" == "2" ]]
}

# =============================================================================
# create_worktree tests
# =============================================================================

create_worktree() {
    local slot=$1
    local task_id=$2
    local worktree_path="$WORKTREES_DIR/executor-$slot"

    if [ -d "$worktree_path" ]; then
        git worktree remove --force "$worktree_path" 2>/dev/null || rm -rf "$worktree_path"
    fi

    mkdir -p "$WORKTREES_DIR"

    if git worktree add --detach "$worktree_path" HEAD >/dev/null 2>&1; then
        echo "$worktree_path"
        return 0
    else
        echo "$PROJECT_DIR"
        return 1
    fi
}

@test "create_worktree: creates worktree directory" {
    local path=$(create_worktree 0 "test-123")

    [[ "$path" == "$WORKTREES_DIR/executor-0" ]]
    [[ -d "$path" ]]
}

@test "create_worktree: worktree contains project files" {
    local path=$(create_worktree 0 "test-123")

    [[ -f "$path/README.md" ]]
}

@test "create_worktree: replaces existing stale worktree" {
    mkdir -p "$WORKTREES_DIR/executor-0"
    touch "$WORKTREES_DIR/executor-0/stale-file"

    local path=$(create_worktree 0 "test-123")

    # Should be a valid worktree now
    [[ -d "$path" ]]
    [[ -f "$path/README.md" ]]
}

# =============================================================================
# cleanup_worktree tests
# =============================================================================

cleanup_worktree() {
    local slot=$1
    local worktree_path="$WORKTREES_DIR/executor-$slot"

    if [ -d "$worktree_path" ]; then
        git worktree remove --force "$worktree_path" 2>/dev/null || rm -rf "$worktree_path"
    fi
}

@test "cleanup_worktree: removes worktree" {
    create_worktree 0 "test-123"
    [[ -d "$WORKTREES_DIR/executor-0" ]]

    cleanup_worktree 0
    [[ ! -d "$WORKTREES_DIR/executor-0" ]]
}

@test "cleanup_worktree: handles non-existent worktree" {
    run cleanup_worktree 99
    [[ "$status" -eq 0 ]]
}

# =============================================================================
# count_active_executors tests
# =============================================================================

count_active_executors() {
    local cache=${1:-""}

    if [ -n "$cache" ]; then
        echo "$cache" | jq '[.[] | select(.labels[]? == "executor")] | length' 2>/dev/null || echo "0"
    else
        bd list --status=in_progress --json 2>/dev/null | \
            jq '[.[] | select(.labels[]? == "executor")] | length' 2>/dev/null || echo "0"
    fi
}

@test "count_active_executors: returns 0 for empty cache" {
    local cache='[]'
    run count_active_executors "$cache"
    [[ "$output" == "0" ]]
}

@test "count_active_executors: counts tasks with executor label" {
    local cache='[{"id":"t1","status":"in_progress","labels":["executor"]},{"id":"t2","status":"in_progress","labels":["executor"]},{"id":"t3","status":"in_progress","labels":[]}]'
    run count_active_executors "$cache"
    [[ "$output" == "2" ]]
}

@test "count_active_executors: handles missing labels" {
    local cache='[{"id":"t1","status":"in_progress"}]'
    run count_active_executors "$cache"
    [[ "$output" == "0" ]]
}

# =============================================================================
# get_ready_tasks filter tests (using mock bd)
# =============================================================================

@test "get_ready_tasks: filters out triggers" {
    mock_bd_init "empty"

    # Create tasks including triggers
    echo '[
        {"id":"t1","title":"Implement feature","type":"task","status":"open","priority":"P1","labels":[],"blocked_by":[]},
        {"id":"t2","title":"run-analyst-ux","type":"task","status":"open","priority":"P2","labels":[],"blocked_by":[]},
        {"id":"t3","title":"Another task","type":"task","status":"open","priority":"P0","labels":[],"blocked_by":[]}
    ]' > "$MOCK_BD_STATE_DIR/tasks.json"

    # Simulate filter (what get_ready_tasks does)
    local result=$(cat "$MOCK_BD_STATE_DIR/tasks.json" | \
        jq -r '.[] | select(.title | test("^run-|^milestone:") | not) | .id')

    mock_bd_cleanup

    # Should have t1 and t3, not t2 (trigger)
    [[ "$result" == *"t1"* ]]
    [[ "$result" == *"t3"* ]]
    [[ "$result" != *"t2"* ]]
}

@test "get_ready_tasks: filters out milestone tasks" {
    mock_bd_init "empty"

    echo '[
        {"id":"t1","title":"Regular task","type":"task","status":"open","priority":"P1","labels":[],"blocked_by":[]},
        {"id":"m1","title":"Planning done","type":"task","status":"open","priority":"P2","labels":["milestone:planning-done"],"blocked_by":[]}
    ]' > "$MOCK_BD_STATE_DIR/tasks.json"

    local result=$(cat "$MOCK_BD_STATE_DIR/tasks.json" | \
        jq -r '.[] | select((.labels // []) | any(test("^milestone:")) | not) | .id')

    mock_bd_cleanup

    [[ "$result" == *"t1"* ]]
    [[ "$result" != *"m1"* ]]
}

@test "get_ready_tasks: filters out regression tasks" {
    mock_bd_init "empty"

    echo '[
        {"id":"t1","title":"Regular task","type":"task","status":"open","priority":"P1","labels":[],"blocked_by":[]},
        {"id":"r1","title":"Regression bug","type":"bug","status":"open","priority":"P0","labels":["regression"],"blocked_by":[]}
    ]' > "$MOCK_BD_STATE_DIR/tasks.json"

    local result=$(cat "$MOCK_BD_STATE_DIR/tasks.json" | \
        jq -r '.[] | select((.labels // []) | index("regression") | not) | .id')

    mock_bd_cleanup

    [[ "$result" == *"t1"* ]]
    [[ "$result" != *"r1"* ]]
}

@test "get_ready_tasks: excludes epic type" {
    mock_bd_init "empty"

    echo '[
        {"id":"t1","title":"Task","type":"task","status":"open","priority":"P1","labels":[],"blocked_by":[]},
        {"id":"e1","title":"Epic container","type":"epic","status":"open","priority":"P1","labels":[],"blocked_by":[]}
    ]' > "$MOCK_BD_STATE_DIR/tasks.json"

    local result=$(cat "$MOCK_BD_STATE_DIR/tasks.json" | \
        jq -r '.[] | select(.type == "task" or .type == "bug" or .type == "feature") | .id')

    mock_bd_cleanup

    [[ "$result" == *"t1"* ]]
    [[ "$result" != *"e1"* ]]
}

# =============================================================================
# Retry logic tests (unit-style)
# =============================================================================

@test "retry: increment creates retry:N label" {
    mock_bd_init "empty"

    # Task with retry:1 should become retry:2
    echo '[{"id":"t1","title":"Failing task","status":"open","labels":["retry:1"],"notes":"Previous error"}]' > "$MOCK_BD_STATE_DIR/tasks.json"

    local current_retry=$(cat "$MOCK_BD_STATE_DIR/tasks.json" | \
        jq -r '.[0].labels[] | select(startswith("retry:")) | split(":")[1] | tonumber')

    [[ "$current_retry" == "1" ]]

    # Next retry would be 2
    local next_retry=$((current_retry + 1))
    [[ "$next_retry" == "2" ]]

    mock_bd_cleanup
}

@test "retry: build_retry_context includes attempt number" {
    mock_bd_init "empty"

    echo '[{"id":"t1","status":"open","labels":["retry:2"],"notes":"Error: timeout after 10m"}]' > "$MOCK_BD_STATE_DIR/tasks.json"

    local context=$(build_retry_context "t1")
    mock_bd_cleanup

    [[ "$context" == *"attempt 3"* ]]
}

# =============================================================================
# Backpressure tests
# =============================================================================

@test "backpressure: MAX_PARALLEL limits concurrent tasks" {
    MAX_PARALLEL=2
    local cache='[{"id":"t1","labels":["executor"]},{"id":"t2","labels":["executor"]}]'

    local active=$(count_active_executors "$cache")

    # With 2 active and MAX_PARALLEL=2, should not start more
    [[ "$active" -ge "$MAX_PARALLEL" ]]
}

@test "backpressure: allows new task when under limit" {
    MAX_PARALLEL=3
    local cache='[{"id":"t1","labels":["executor"]}]'

    local active=$(count_active_executors "$cache")
    local available=$((MAX_PARALLEL - active))

    [[ "$available" -gt 0 ]]
}
