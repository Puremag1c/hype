#!/bin/bash
# core/scripts/run-testers.sh
# Запускает Tester агентов параллельно для SMOKE_TEST фазы.
# Testers выбираются по типу проекта из SPEC.md.
#
# Testers by project type:
#   - web: functional, visual, api
#   - api: functional, api
#   - cli: functional, cli
#   - library: functional, regression
#
# Использование: ./scripts/run-testers.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

PROJECT_DIR=$(pwd)
LOGS_DIR="$PROJECT_DIR/logs"
CONFIG_FILE="$PROJECT_DIR/.hype/config.sh"

# Load config
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

TESTER_TIMEOUT="${TESTER_TIMEOUT:-10m}"
SMOKE_TEST_TIMEOUT="${SMOKE_TEST_TIMEOUT:-15m}"
# bd_safe is provided by common.sh with flock serialization

mkdir -p "$LOGS_DIR"
mkdir -p "$PROJECT_DIR/.hype/evidence"

log() {
    local level=$1
    local msg=$2
    local color="" reset="\033[0m" gray="\033[90m"
    # HYPE brand colors (neon pink gradient)
    local hype_colored="\033[38;2;255;0;102mH\033[38;2;255;51;153mY\033[38;2;255;102;204mP\033[38;2;204;255;0mE\033[0m"

    case "$level" in
        INFO)  color="\033[32m" ;;  # green
        WARN)  color="\033[33m" ;;  # yellow
        ERROR) color="\033[31m" ;;  # red
    esac

    printf "${gray}%s${reset} [${hype_colored} SMOKE] ${color}%s${reset}: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [HYPE SMOKE] $level: $msg" >> "$LOGS_DIR/hype.log"
}

# Parse YAML value: strip comments, quotes, whitespace
# Handles: '""  # comment' -> '', 'value  # comment' -> 'value', '"quoted"' -> 'quoted'
parse_yaml_value() {
    echo "$1" | sed -e 's/#.*//' -e 's/"//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Get project type from SPEC.md
get_project_type() {
    if [ ! -f "$PROJECT_DIR/SPEC.md" ]; then
        echo "web"  # default
        return
    fi

    local type
    type=$(grep -A1 "Type:" "$PROJECT_DIR/SPEC.md" 2>/dev/null | tail -1 | sed 's/^[- ]*//' | tr '[:upper:]' '[:lower:]' | tr -d ' ')

    case "$type" in
        web|api|cli|library) echo "$type" ;;
        *) echo "web" ;;  # default to web
    esac
}

# Get testers for project type
# Note: backend runs for all types, playwright testers (functional, visual) listed separately
get_testers_for_type() {
    local type=$1
    case "$type" in
        web)      echo "backend api functional visual" ;;
        api)      echo "backend api functional" ;;
        cli)      echo "backend cli functional" ;;
        library)  echo "backend regression functional" ;;
        *)        echo "backend functional" ;;
    esac
}

# Check if Playwright MCP is available (for visual tester)
check_playwright_mcp() {
    # Check if .mcp.json mentions playwright
    if [ -f "$PROJECT_DIR/.mcp.json" ] && grep -q "playwright" "$PROJECT_DIR/.mcp.json" 2>/dev/null; then
        return 0
    fi

    # Check global MCP config
    if [ -f "$HOME/.config/claude/mcp.json" ] && grep -q "playwright" "$HOME/.config/claude/mcp.json" 2>/dev/null; then
        return 0
    fi

    return 1
}

# Run single tester
run_tester() {
    local tester=$1
    local project_type=$2
    local bd_cache=$3  # Cached bd list --json (v1.9.0+)
    local trigger_task="run-tester-$tester"
    local agent_file=".claude/agents/tester-$tester.md"
    local task_id=""

    # Cleanup function - ensures task is closed on any exit
    _tester_cleanup() {
        if [ -n "$task_id" ]; then
            local status
            status=$(bd_safe show "$task_id" --json 2>/dev/null | jq -r 'if type == "array" then .[0].status else .status end' 2>/dev/null || echo "unknown")
            if [ "$status" != "closed" ]; then
                log "WARN" "Cleanup: closing tester-$tester task $task_id"
                bd_safe close "$task_id" --reason="Tester cleanup (abnormal exit)" >/dev/null 2>&1 || true
            fi
        fi
    }

    log "INFO" "Starting tester-$tester"

    # Find trigger task from cache
    task_id=$(echo "$bd_cache" | jq -r ".[] | select(.title == \"$trigger_task\") | .id" | head -1)

    if [ -z "$task_id" ]; then
        log "WARN" "No trigger task for tester-$tester"
        return 0
    fi

    # Set trap for cleanup (after task_id is set)
    trap _tester_cleanup EXIT INT TERM

    # Claim trigger task
    if ! bd_safe update "$task_id" --status=in_progress >/dev/null 2>&1; then
        log "INFO" "Trigger $trigger_task already claimed"
        trap - EXIT INT TERM  # Clear trap - not our task
        task_id=""  # Prevent cleanup
        return 0
    fi

    # Check if agent file exists
    if [ ! -f "$agent_file" ]; then
        log "WARN" "Agent file not found: $agent_file"
        bd_safe close "$task_id" --reason="Agent file not found" >/dev/null 2>&1
        return 0
    fi

    # Special check for visual tester - skip if no Playwright
    if [ "$tester" = "visual" ]; then
        if ! check_playwright_mcp; then
            log "WARN" "Playwright MCP not available, skipping visual tester"
            mkdir -p "$PROJECT_DIR/.hype/evidence/visual"
            echo "Skipped: Playwright MCP not available" > "$PROJECT_DIR/.hype/evidence/visual/skipped.txt"
            bd_safe close "$task_id" --reason="Skipped: Playwright MCP not available" >/dev/null 2>&1
            return 0
        fi
    fi

    # Prepare prompt
    local output_file="$LOGS_DIR/tester-$tester.log"
    local tester_prompt
    tester_prompt=$(cat "$agent_file" 2>/dev/null)

    # Read SPEC.md for context
    local spec_content
    spec_content=$(cat "$PROJECT_DIR/SPEC.md" 2>/dev/null || echo "SPEC.md not found")

    # Use testing.yaml values (set by read_testing_config), fallback to SPEC.md
    local build_cmd start_cmd test_url server_managed
    build_cmd="${TESTING_BUILD_CMD:-}"
    start_cmd="${TESTING_START_CMD:-}"
    test_url="${TESTING_URL:-http://localhost:3000}"
    server_managed="${SERVER_MANAGED:-false}"

    local full_prompt="$tester_prompt

---
TESTER: $tester
TRIGGER_TASK: $task_id
PROJECT_ROOT: $PROJECT_DIR
PROJECT_TYPE: $project_type
BUILD_CMD: $build_cmd
START_CMD: $start_cmd
TEST_URL: $test_url
SERVER_MANAGED: $server_managed

## Important
If SERVER_MANAGED=true, the dev server is ALREADY RUNNING at TEST_URL.
Do NOT start your own server. Just run tests against the existing server.

## SPEC.md:
$spec_content"

    # Determine model for tester
    local tester_model
    case "$tester" in
        visual)     tester_model=$(map_model "${MODEL_TESTER_VISUAL:-opus}") ;;
        functional) tester_model=$(map_model "${MODEL_TESTER_FUNCTIONAL:-sonnet}") ;;
        regression) tester_model=$(map_model "${MODEL_TESTER_REGRESSION:-sonnet}") ;;
        backend)    tester_model=$(map_model "${MODEL_TESTER_BACKEND:-sonnet}") ;;
        *)          tester_model=$(map_model "${MODEL_TESTERS:-haiku}") ;;
    esac

    # Run tester with real-time progress logging
    # Use || to prevent set -e from killing script on timeout/failure
    local exit_code=0
    run_claude_with_progress "$full_prompt" "$tester_model" "$TESTER_TIMEOUT" "$output_file" "TESTER $tester" "$LOGS_DIR" || exit_code=$?

    if [ $exit_code -ne 0 ]; then
        if [ $exit_code -eq 124 ]; then
            log "WARN" "Tester $tester timeout"
            bd_safe update "$task_id" --status=open --notes="Timeout at $(date '+%Y-%m-%d %H:%M:%S')" >/dev/null 2>&1
        else
            log "ERROR" "Tester $tester failed (exit: $exit_code)"
            bd_safe update "$task_id" --status=open --notes="Failed (exit: $exit_code)" >/dev/null 2>&1
        fi
        return 0
    fi

    # Note: tester should close its own trigger task
    # But verify it's closed
    local task_status
    # bd show returns array, not object
    task_status=$(bd_safe show "$task_id" --json 2>/dev/null | jq -r 'if type == "array" then .[0].status else .status end' 2>/dev/null || echo "unknown")
    if [ "$task_status" != "closed" ]; then
        log "WARN" "Tester $tester didn't close trigger, closing now"
        bd_safe close "$task_id" --reason="Tester completed (auto-closed)" >/dev/null 2>&1
    fi

    # Clear trap and task_id to prevent double-close on normal exit
    trap - EXIT INT TERM
    task_id=""

    log "INFO" "Tester $tester completed"
}

# Create tester trigger tasks if they don't exist
create_tester_triggers() {
    local testers=$1
    local bd_cache=$2  # Cached bd list --json (v1.9.0+)

    for tester in $testers; do
        local trigger_title="run-tester-$tester"
        if ! echo "$bd_cache" | jq -e ".[] | select(.title == \"$trigger_title\")" > /dev/null 2>&1; then
            bd_safe create --title="$trigger_title" --type=task --priority=0 --label=trigger >/dev/null 2>&1
            log "INFO" "Created trigger: $trigger_title"
        fi
    done
}

# Ensure testing config exists (.hype/testing.yaml)
# If not, create P0 task for Opus to fill it
ensure_testing_config() {
    local config_file="$PROJECT_DIR/.hype/testing.yaml"
    local project_type=$1

    # For library/cli - testing config is optional
    if [ "$project_type" = "library" ]; then
        log "INFO" "Library project - testing config optional"
        return 0
    fi

    # Check if testing.yaml exists
    if [ ! -f "$config_file" ]; then
        log "ERROR" "Missing .hype/testing.yaml"
        bd_safe create --title="Create testing configuration" \
            --type=bug --priority=0 \
            --label=model:opus \
            --description="Analyze the project and create .hype/testing.yaml

## Task
1. Examine project files (package.json, pyproject.toml, go.mod, mix.exs, etc.)
2. Determine the correct commands for this project
3. Create .hype/testing.yaml with this structure:

\`\`\`yaml
# .hype/testing.yaml - Testing configuration
# type: web|api|cli|library
# build_command: command to prepare fresh code (REQUIRED for most projects!)
# start_command: command to start the dev server
# health_check: endpoint to verify server is ready
type: web
build_command: npm run build
start_command: npm run dev
test_url: http://localhost:3000
health_check: /
startup_timeout: 30
\`\`\`

## CRITICAL: Build Command
Build runs BEFORE EVERY smoke test to ensure fresh code. Without it, testers may see OLD code!

### By Language:
- **Python (with venv)**: \`build_command: .venv/bin/pip install -e .\` (editable install = changes visible immediately)
- **Python (script only)**: Can omit if running \`python script.py\` directly (not a package)
- **Node.js**: \`build_command: npm run build\` or \`npm ci\`
- **Go**: \`build_command: go build -o ./bin/app\`
- **Elixir**: \`build_command: mix deps.get && mix compile\`
- **Rust**: \`build_command: cargo build --release\`

### Start Command:
- **Python**: \`.venv/bin/python -m module\` or \`.venv/bin/uvicorn app:app\`
- **Node.js**: \`npm run dev\` or \`node dist/index.js\`
- **Go**: \`./bin/app\` (run compiled binary)

## WARNING: System Python
If using system python (not venv), changes to source code are INVISIBLE!
System python reads from /Library/Frameworks/... or /usr/lib/..., NOT your project.
ALWAYS use venv: \`.venv/bin/python\`

done_when: .hype/testing.yaml exists with valid, tested commands" >/dev/null 2>&1

        echo "SMOKE_TEST: NEEDS_CONFIG"
        return 1
    fi

    # Validate required fields
    local start_cmd
    start_cmd=$(grep "^start_command:" "$config_file" 2>/dev/null | cut -d: -f2- | sed 's/^[ ]*//')

    if [ -z "$start_cmd" ]; then
        log "ERROR" "testing.yaml missing start_command"
        return 1
    fi

    log "INFO" "Testing config valid: $config_file"
    return 0
}

# Read testing config
read_testing_config() {
    local config_file="$PROJECT_DIR/.hype/testing.yaml"
    local raw_val

    # Export config values for use in other functions (parsed to handle comments/quotes)
    raw_val=$(grep "^type:" "$config_file" 2>/dev/null | cut -d: -f2- || echo "web")
    TESTING_TYPE=$(parse_yaml_value "$raw_val")
    [ -z "$TESTING_TYPE" ] && TESTING_TYPE="web"

    raw_val=$(grep "^build_command:" "$config_file" 2>/dev/null | cut -d: -f2- || echo "")
    TESTING_BUILD_CMD=$(parse_yaml_value "$raw_val")

    raw_val=$(grep "^start_command:" "$config_file" 2>/dev/null | cut -d: -f2- || echo "")
    TESTING_START_CMD=$(parse_yaml_value "$raw_val")

    raw_val=$(grep "^test_url:" "$config_file" 2>/dev/null | cut -d: -f2- || echo "http://localhost:3000")
    TESTING_URL=$(parse_yaml_value "$raw_val")
    [ -z "$TESTING_URL" ] && TESTING_URL="http://localhost:3000"

    raw_val=$(grep "^health_check:" "$config_file" 2>/dev/null | cut -d: -f2- || echo "/")
    TESTING_HEALTH=$(parse_yaml_value "$raw_val")
    [ -z "$TESTING_HEALTH" ] && TESTING_HEALTH="/"

    raw_val=$(grep "^startup_timeout:" "$config_file" 2>/dev/null | cut -d: -f2- || echo "30")
    TESTING_TIMEOUT=$(parse_yaml_value "$raw_val")
    [ -z "$TESTING_TIMEOUT" ] && TESTING_TIMEOUT="30"

    export TESTING_TYPE TESTING_BUILD_CMD TESTING_START_CMD TESTING_URL TESTING_HEALTH TESTING_TIMEOUT
}

# Start dev server (single instance for all testers)
start_dev_server() {
    local start_cmd="$TESTING_START_CMD"
    local test_url="$TESTING_URL"
    local health_path="$TESTING_HEALTH"
    local timeout="$TESTING_TIMEOUT"

    if [ -z "$start_cmd" ]; then
        log "WARN" "No start_command, testers will manage their own servers"
        return 0
    fi

    log "INFO" "Starting dev server: $start_cmd"

    # Start server in background
    eval "$start_cmd" > "$LOGS_DIR/dev-server.log" 2>&1 &
    DEV_SERVER_PID=$!
    echo "$DEV_SERVER_PID" > "$PROJECT_DIR/.hype/server.pid"

    # Wait for server to be ready
    local health_url="${test_url}${health_path}"
    local waited=0

    log "INFO" "Waiting for server at $health_url (timeout: ${timeout}s)"

    while [ $waited -lt "$timeout" ]; do
        if curl -s -o /dev/null -w "%{http_code}" "$health_url" 2>/dev/null | grep -qE "^[23]"; then
            log "INFO" "Server ready (PID: $DEV_SERVER_PID)"
            export DEV_SERVER_PID
            return 0
        fi
        sleep 1
        ((waited++))
    done

    log "ERROR" "Server failed to start within ${timeout}s"
    kill $DEV_SERVER_PID 2>/dev/null || true

    # Create P0 bug for server failure
    bd_safe create --title="SMOKE: [Server] Dev server failed to start" \
        --type=bug --priority=0 \
        --description="## Start Command
$start_cmd

## Health Check
URL: $health_url
Timeout: ${timeout}s

## Server Log
\`\`\`
$(tail -50 "$LOGS_DIR/dev-server.log" 2>/dev/null || echo "No log available")
\`\`\`

## Context
Dev server failed to respond to health check within timeout.
Check if the start command is correct and the server starts properly." >/dev/null 2>&1
    return 1
}

# Stop dev server
stop_dev_server() {
    local pid_file="$PROJECT_DIR/.hype/server.pid"

    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            log "INFO" "Stopping dev server (PID: $pid)"
            kill "$pid" 2>/dev/null || true
            sleep 1
            # Force kill if still running
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$pid_file"
    fi

    # Also kill by port as fallback
    local test_port
    test_port=$(echo "$TESTING_URL" | grep -oE ':[0-9]+' | tr -d ':')
    test_port=${test_port:-3000}

    if lsof -ti:"$test_port" >/dev/null 2>&1; then
        lsof -ti:"$test_port" | xargs kill -9 2>/dev/null || true
    fi
}

# Run build command before testing
run_build() {
    local build_cmd
    # First try testing.yaml, fallback to SPEC.md
    build_cmd="${TESTING_BUILD_CMD:-}"
    if [ -z "$build_cmd" ]; then
        build_cmd=$(grep -A1 "Build command" "$PROJECT_DIR/SPEC.md" 2>/dev/null | tail -1 | sed 's/^[- ]*//' || echo "")
    fi

    # Skip if no build command or placeholder
    # Note: validate_testing_config() already checks for Python package issues
    if [ -z "$build_cmd" ] || [[ "$build_cmd" == *"["* ]]; then
        log "INFO" "No build command specified, skipping build step"
        return 0
    fi

    log "INFO" "Building project: $build_cmd"

    # Run build with timeout
    if ! timeout_cmd "5m" bash -c "$build_cmd" > "$LOGS_DIR/build.log" 2>&1; then
        log "ERROR" "Build failed! See $LOGS_DIR/build.log"
        # Create P0 bug for build failure
        bd_safe create --title="SMOKE: [Build] Build command failed" \
            --type=bug --priority=0 \
            --description="## Build Command
$build_cmd

## Error
\`\`\`
$(tail -50 "$LOGS_DIR/build.log")
\`\`\`

## Context
Build failed before SMOKE_TEST could run. Fix build errors first." >/dev/null 2>&1
        return 1
    fi

    log "INFO" "Build completed successfully"
    return 0
}

# Main
main() {
    # Visual separation
    echo ""
    echo "" >> "$LOGS_DIR/hype.log"

    # Health check: verify bd daemon is responsive before starting
    # Prevents hanging if daemon is frozen (common failure mode)
    if ! bd_safe stats >/dev/null 2>&1; then
        log "ERROR" "Beads daemon unresponsive! Attempting restart..."
        timeout_cmd 10s bd daemon restart . >/dev/null 2>&1 || true
        sleep 2
        if ! bd_safe stats >/dev/null 2>&1; then
            log "FATAL" "Beads daemon failed to recover. Run: pkill -9 -f 'bd daemon' && bd daemon start"
            return 1
        fi
        log "INFO" "Beads daemon recovered"
    fi

    # Get project type first
    local project_type
    project_type=$(get_project_type)
    log "INFO" "Project type: $project_type"

    # Ensure testing config exists (for web/api projects)
    if ! ensure_testing_config "$project_type"; then
        log "WARN" "SMOKE_TEST: missing testing configuration - task created"
        return 0  # Task created, hype.sh will route to IMPLEMENTATION
    fi

    # Read testing config
    read_testing_config

    # Kill any existing process on test port
    stop_dev_server

    # Run build first to ensure fresh artifacts
    if ! run_build; then
        log "WARN" "SMOKE_TEST: build failed - task created"
        return 0  # Task created, hype.sh will route to IMPLEMENTATION
    fi

    # Start dev server (single instance for all testers)
    local server_started=false
    if [ -n "$TESTING_START_CMD" ]; then
        if start_dev_server; then
            server_started=true
            export SERVER_MANAGED=true  # Tell testers not to start their own
        else
            log "WARN" "SMOKE_TEST: server failed to start - task created"
            return 0  # Task created, hype.sh will route to IMPLEMENTATION
        fi
    fi

    # Get testers for this type
    local testers
    testers=$(get_testers_for_type "$project_type")
    log "INFO" "SMOKE TEST: $testers"

    # Cache bd list at start (v1.9.0 optimization)
    local bd_cache
    bd_cache=$(bd_safe list --json 2>/dev/null || echo "[]")

    # Create trigger tasks (pass cache)
    create_tester_triggers "$testers" "$bd_cache"

    # Refresh cache after creating triggers
    bd_cache=$(bd_safe list --json 2>/dev/null || echo "[]")

    # Check that triggers exist (using cache)
    local missing=0
    for tester in $testers; do
        if ! echo "$bd_cache" | jq -e ".[] | select(.title == \"run-tester-$tester\")" > /dev/null 2>&1; then
            log "WARN" "Trigger task run-tester-$tester not found"
            ((missing++)) || true
        fi
    done

    # Run testers - Playwright testers (functional, visual) run sequentially to avoid MCP conflicts
    # Non-Playwright testers (backend, api, cli, regression) run in parallel
    local parallel_pids=""
    local playwright_testers=""

    for tester in $testers; do
        case "$tester" in
            functional|visual)
                # Queue for sequential execution
                playwright_testers="$playwright_testers $tester"
                ;;
            *)
                # Run in parallel
                run_tester "$tester" "$project_type" "$bd_cache" &
                parallel_pids="$parallel_pids $!"
                ;;
        esac
    done

    # Run Playwright testers sequentially (avoid MCP conflicts)
    for tester in $playwright_testers; do
        log "INFO" "Running $tester (sequential - Playwright)"
        run_tester "$tester" "$project_type" "$bd_cache"
    done

    # Wait for parallel testers
    for pid in $parallel_pids; do
        wait "$pid" 2>/dev/null || true
    done

    # Stop dev server
    if [ "$server_started" = true ]; then
        stop_dev_server
    fi

    # Refresh cache for post-test checks (single bd call instead of 3)
    local post_cache
    post_cache=$(bd_safe list --status=open --json 2>/dev/null || echo "[]")

    # Post-process regression tasks: increment regress:N counter (script-driven, not LLM)
    # Testers add "regression" label when reopening/creating regression bugs.
    # We increment the counter here so it's reliable and not dependent on LLM accuracy.
    local regression_ids
    regression_ids=$(echo "$post_cache" | jq -r '.[] | select((.labels // []) | index("regression")) | .id' 2>/dev/null || true)
    for reg_id in $regression_ids; do
        local reg_json reg_count
        reg_json=$(bd_safe show "$reg_id" --json 2>/dev/null || echo "[]")
        reg_count=$(get_counter_value "$reg_json" "regress")
        ((reg_count++))
        set_counter_label "$reg_id" "regress" "$reg_count"
        log "INFO" "Regression counter: $reg_id → regress:$reg_count"
    done

    # Check completion
    local open_triggers
    open_triggers=$(echo "$post_cache" | jq '[.[] | select(.title | startswith("run-tester-"))] | length' 2>/dev/null || echo "0")

    if [ "$open_triggers" -eq 0 ]; then
        log "INFO" "All testers completed"
    else
        log "WARN" "Some testers still open ($open_triggers remaining)"
    fi

    # Check for P0 bugs created by testers
    local p0_bugs p0_titles
    p0_bugs=$(echo "$post_cache" | jq '[.[] | select(.priority == 0)] | length' 2>/dev/null || echo "0")
    p0_titles=$(echo "$post_cache" | jq -r '.[] | select(.priority == 0) | "- \(.title)"' 2>/dev/null || echo "None")

    if [ "$p0_bugs" -gt 0 ]; then
        log "WARN" "SMOKE TEST FAILED: $p0_bugs P0 bug(s) found"
        log "INFO" "System will return to IMPLEMENTATION to fix P0 bugs"
    else
        log "INFO" "SMOKE TEST PASSED: No P0 bugs found"
    fi

    # Generate summary report (using cached data)
    cat > "$PROJECT_DIR/.hype/evidence/smoke-test-report.md" << EOF
# Smoke Test Report
Generated: $(date)
Project Type: $project_type

## Testers Run
$(echo "$testers" | tr ' ' '\n' | sed 's/^/- /')

## Evidence Directories
$(ls -d "$PROJECT_DIR/.hype/evidence"/*/ 2>/dev/null | sed 's/^/- /' || echo "None")

## P0 Bugs Found
${p0_titles:-None}

## Result
$([ "$p0_bugs" -eq 0 ] && echo "**PASSED**" || echo "**FAILED** - $p0_bugs P0 bug(s) require fixing")
EOF

    log "INFO" "SMOKE TEST FINISHED"
}

main "$@"
