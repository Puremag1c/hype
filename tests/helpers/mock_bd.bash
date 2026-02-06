#!/usr/bin/env bash
# tests/helpers/mock_bd.bash
# Mock for `bd` command for unit testing without real beads

# Mock state directory
export MOCK_BD_STATE_DIR=""
export MOCK_BD_FIXTURE=""

# Initialize mock bd
# Usage: mock_bd_init [fixture_name]
# fixture_name: name of fixture file in tests/fixtures/tasks/ (without .json)
mock_bd_init() {
    local fixture="${1:-empty}"

    MOCK_BD_STATE_DIR=$(mktemp -d)
    MOCK_BD_FIXTURE="$fixture"

    # Copy fixture to mock state
    local fixture_path="$PROJECT_ROOT/tests/fixtures/tasks/${fixture}.json"
    if [[ -f "$fixture_path" ]]; then
        cp "$fixture_path" "$MOCK_BD_STATE_DIR/tasks.json"
    else
        echo "[]" > "$MOCK_BD_STATE_DIR/tasks.json"
    fi

    # Create call log
    : > "$MOCK_BD_STATE_DIR/calls.log"

    # Export bd function that uses mock
    export -f bd
}

# Cleanup mock bd
mock_bd_cleanup() {
    if [[ -n "$MOCK_BD_STATE_DIR" && -d "$MOCK_BD_STATE_DIR" ]]; then
        rm -rf "$MOCK_BD_STATE_DIR"
    fi
    unset MOCK_BD_STATE_DIR MOCK_BD_FIXTURE
}

# Mock bd command
# Supports: list, show, stats, update, close, create, ready, blocked
bd() {
    local cmd="$1"
    shift

    # Log the call
    echo "bd $cmd $*" >> "$MOCK_BD_STATE_DIR/calls.log"

    case "$cmd" in
        list)
            _mock_bd_list "$@"
            ;;
        show)
            _mock_bd_show "$@"
            ;;
        stats)
            _mock_bd_stats "$@"
            ;;
        update)
            _mock_bd_update "$@"
            ;;
        close)
            _mock_bd_close "$@"
            ;;
        create)
            _mock_bd_create "$@"
            ;;
        ready)
            _mock_bd_ready "$@"
            ;;
        blocked)
            _mock_bd_blocked "$@"
            ;;
        sync)
            # No-op for tests
            echo "✓ Synced (mock)"
            ;;
        dep)
            # No-op for tests
            echo "✓ Dependency updated (mock)"
            ;;
        delete)
            # No-op for tests
            echo "✓ Deleted (mock)"
            ;;
        admin)
            # No-op for tests
            echo "✓ Admin command (mock)"
            ;;
        *)
            echo "Mock bd: unknown command '$cmd'" >&2
            return 1
            ;;
    esac
}

# Internal: bd list
_mock_bd_list() {
    local json_output=false
    local status_filter=""
    local limit=""
    local show_all=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json_output=true ;;
            --status=*) status_filter="${1#--status=}" ;;
            --limit=*) limit="${1#--limit=}" ;;
            --all) show_all=true ;;
        esac
        shift
    done

    local tasks
    tasks=$(cat "$MOCK_BD_STATE_DIR/tasks.json")

    # Filter by status if specified
    if [[ -n "$status_filter" ]]; then
        tasks=$(echo "$tasks" | jq "[.[] | select(.status == \"$status_filter\")]")
    fi

    # Filter closed unless --all
    if [[ "$show_all" != "true" ]]; then
        tasks=$(echo "$tasks" | jq '[.[] | select(.status != "closed")]')
    fi

    if [[ "$json_output" == "true" ]]; then
        echo "$tasks"
    else
        # Human-readable format
        echo "$tasks" | jq -r '.[] | "○ \(.id) [\(.priority)] [\(.type)] - \(.title)"'
    fi
}

# Internal: bd show
_mock_bd_show() {
    local task_id=""
    local json_output=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json_output=true ;;
            -*) ;;
            *) task_id="$1" ;;
        esac
        shift
    done

    local task
    task=$(cat "$MOCK_BD_STATE_DIR/tasks.json" | jq "[.[] | select(.id == \"$task_id\")]")

    if [[ "$json_output" == "true" ]]; then
        echo "$task"
    else
        echo "$task" | jq -r '.[0] | "○ \(.id) · \(.title)   [\(.priority) · \(.status | ascii_upcase)]\n\nDESCRIPTION\n\(.description // "No description")"'
    fi
}

# Internal: bd stats
_mock_bd_stats() {
    local tasks
    tasks=$(cat "$MOCK_BD_STATE_DIR/tasks.json")

    local open closed in_progress
    open=$(echo "$tasks" | jq '[.[] | select(.status == "open")] | length')
    closed=$(echo "$tasks" | jq '[.[] | select(.status == "closed")] | length')
    in_progress=$(echo "$tasks" | jq '[.[] | select(.status == "in_progress")] | length')

    echo "📊 Project Statistics"
    echo "Open: $open"
    echo "In Progress: $in_progress"
    echo "Closed: $closed"
}

# Internal: bd update
_mock_bd_update() {
    local task_id=""
    local new_status=""
    local new_notes=""
    local add_label=""
    local remove_label=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --status=*) new_status="${1#--status=}" ;;
            --status) new_status="$2"; shift ;;
            --notes=*) new_notes="${1#--notes=}" ;;
            --notes) new_notes="$2"; shift ;;
            --add-label=*) add_label="${1#--add-label=}" ;;
            --add-label) add_label="$2"; shift ;;
            --remove-label=*) remove_label="${1#--remove-label=}" ;;
            --remove-label) remove_label="$2"; shift ;;
            --claim) ;;  # Ignore for mock
            -*) ;;
            *) task_id="$1" ;;
        esac
        shift
    done

    # Update task in JSON
    local tasks
    tasks=$(cat "$MOCK_BD_STATE_DIR/tasks.json")

    if [[ -n "$new_status" ]]; then
        tasks=$(echo "$tasks" | jq "map(if .id == \"$task_id\" then .status = \"$new_status\" else . end)")
    fi

    if [[ -n "$new_notes" ]]; then
        tasks=$(echo "$tasks" | jq "map(if .id == \"$task_id\" then .notes = \"$new_notes\" else . end)")
    fi

    echo "$tasks" > "$MOCK_BD_STATE_DIR/tasks.json"
    echo "✓ Updated issue: $task_id"
}

# Internal: bd close
_mock_bd_close() {
    local task_ids=()
    local reason=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --reason=*) reason="${1#--reason=}" ;;
            --reason) reason="$2"; shift ;;
            -*) ;;
            *) task_ids+=("$1") ;;
        esac
        shift
    done

    local tasks
    tasks=$(cat "$MOCK_BD_STATE_DIR/tasks.json")

    for task_id in "${task_ids[@]}"; do
        tasks=$(echo "$tasks" | jq "map(if .id == \"$task_id\" then .status = \"closed\" else . end)")
        echo "✓ Closed: $task_id"
    done

    echo "$tasks" > "$MOCK_BD_STATE_DIR/tasks.json"
}

# Internal: bd create
_mock_bd_create() {
    local title=""
    local type="task"
    local priority="2"
    local labels=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --title=*) title="${1#--title=}" ;;
            --title) title="$2"; shift ;;
            --type=*) type="${1#--type=}" ;;
            --type) type="$2"; shift ;;
            --priority=*) priority="${1#--priority=}" ;;
            --priority) priority="$2"; shift ;;
            --labels=*) labels="${1#--labels=}" ;;
            --labels) labels="$2"; shift ;;
        esac
        shift
    done

    # Generate mock ID
    local new_id="mock-$(date +%s)-$RANDOM"

    # Create new task
    local new_task
    new_task=$(jq -n \
        --arg id "$new_id" \
        --arg title "$title" \
        --arg type "$type" \
        --arg priority "P$priority" \
        --arg labels "$labels" \
        '{
            id: $id,
            title: $title,
            type: $type,
            priority: $priority,
            status: "open",
            labels: (if $labels != "" then ($labels | split(",")) else [] end),
            description: "",
            notes: ""
        }')

    # Add to tasks
    local tasks
    tasks=$(cat "$MOCK_BD_STATE_DIR/tasks.json")
    tasks=$(echo "$tasks" | jq ". + [$new_task]")
    echo "$tasks" > "$MOCK_BD_STATE_DIR/tasks.json"

    echo "Created: $new_id"
}

# Internal: bd ready
_mock_bd_ready() {
    local tasks
    tasks=$(cat "$MOCK_BD_STATE_DIR/tasks.json")

    # Filter: open tasks with no blockers (simplified for mock)
    local ready
    ready=$(echo "$tasks" | jq '[.[] | select(.status == "open" and (.blocked_by | length == 0))]')

    echo "📋 Ready work:"
    echo "$ready" | jq -r '.[] | "  [\(.priority)] \(.id): \(.title)"'
}

# Internal: bd blocked
_mock_bd_blocked() {
    local tasks
    tasks=$(cat "$MOCK_BD_STATE_DIR/tasks.json")

    # Filter: tasks with blockers
    local blocked
    blocked=$(echo "$tasks" | jq '[.[] | select(.blocked_by | length > 0)]')

    echo "🚫 Blocked work:"
    echo "$blocked" | jq -r '.[] | "  \(.id): \(.title) (blocked by: \(.blocked_by | join(", ")))"'
}

# Helper: get list of bd calls made during test
# Usage: mock_bd_calls
mock_bd_calls() {
    cat "$MOCK_BD_STATE_DIR/calls.log"
}

# Helper: assert bd was called with specific args
# Usage: assert_bd_called "update task-123 --status=in_progress"
assert_bd_called() {
    local expected="$1"
    if ! grep -q "$expected" "$MOCK_BD_STATE_DIR/calls.log" 2>/dev/null; then
        echo "Expected bd call not found: $expected" >&2
        echo "Actual calls:" >&2
        cat "$MOCK_BD_STATE_DIR/calls.log" >&2
        return 1
    fi
}

# Helper: assert bd was NOT called
# Usage: assert_bd_not_called "delete"
assert_bd_not_called() {
    local unexpected="$1"
    if grep -q "$unexpected" "$MOCK_BD_STATE_DIR/calls.log" 2>/dev/null; then
        echo "Unexpected bd call found: $unexpected" >&2
        echo "Actual calls:" >&2
        cat "$MOCK_BD_STATE_DIR/calls.log" >&2
        return 1
    fi
}

export -f bd mock_bd_init mock_bd_cleanup mock_bd_calls assert_bd_called assert_bd_not_called
export -f _mock_bd_list _mock_bd_show _mock_bd_stats _mock_bd_update _mock_bd_close _mock_bd_create _mock_bd_ready _mock_bd_blocked
