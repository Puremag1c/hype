#!/usr/bin/env bats
# tests/unit/deps_test.bats
# Tests for dependency management (deps.conf, version_compare, check_dep_versions)

load '../helpers/setup'

# =============================================================================
# deps.conf format tests
# =============================================================================

@test "deps: deps.conf exists" {
    [[ -f "$PROJECT_ROOT/deps.conf" ]]
}

@test "deps: deps.conf has correct format (7 pipe-separated fields per line)" {
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        local field_count
        field_count=$(echo "$line" | awk -F'|' '{print NF}')
        [[ "$field_count" -eq 7 ]] || {
            echo "Bad line (expected 7 fields, got $field_count): $line" >&2
            return 1
        }
    done < "$PROJECT_ROOT/deps.conf"
}

@test "deps: deps.conf includes beads as required" {
    grep -q '^beads|bd|.*|true$' "$PROJECT_ROOT/deps.conf"
}

@test "deps: beads has max_version ceiling (controlled upgrades)" {
    local beads_line
    beads_line=$(grep '^beads|' "$PROJECT_ROOT/deps.conf")
    local max_version
    max_version=$(echo "$beads_line" | cut -d'|' -f5)
    [[ -n "$max_version" ]]
}

@test "deps: claude has min_version set" {
    local claude_line
    claude_line=$(grep '^claude|' "$PROJECT_ROOT/deps.conf")
    local min_version
    min_version=$(echo "$claude_line" | cut -d'|' -f4)
    [[ -n "$min_version" ]]
}

@test "deps: deps.conf includes gitleaks as optional" {
    grep -q '^gitleaks|.*|false$' "$PROJECT_ROOT/deps.conf"
}

# =============================================================================
# version_compare tests (source bin/hype functions)
# =============================================================================

# We can't source bin/hype directly (it runs case at end), so test via grep + inline

@test "deps: bin/hype defines version_compare function" {
    grep -q '^version_compare()' "$PROJECT_ROOT/bin/hype"
}

@test "deps: bin/hype defines get_dep_version function" {
    grep -q '^get_dep_version()' "$PROJECT_ROOT/bin/hype"
}

@test "deps: bin/hype defines check_dep_versions function" {
    grep -q '^check_dep_versions()' "$PROJECT_ROOT/bin/hype"
}

@test "deps: bin/hype defines update_dependencies function" {
    grep -q '^update_dependencies()' "$PROJECT_ROOT/bin/hype"
}

@test "deps: version_compare uses sort -V" {
    local func_block
    func_block=$(sed -n '/^version_compare()/,/^}/p' "$PROJECT_ROOT/bin/hype")
    echo "$func_block" | grep -q 'sort -V'
}

@test "deps: check_dep_versions reads DEPS_CONF" {
    local func_block
    func_block=$(sed -n '/^check_dep_versions()/,/^}/p' "$PROJECT_ROOT/bin/hype")
    echo "$func_block" | grep -q 'DEPS_CONF'
}

@test "deps: cmd_update supports --no-deps flag" {
    local func_block
    func_block=$(sed -n '/^cmd_update()/,/^}/p' "$PROJECT_ROOT/bin/hype")
    echo "$func_block" | grep -q '\-\-no-deps'
}

@test "deps: cmd_update calls update_dependencies" {
    local func_block
    func_block=$(sed -n '/^cmd_update()/,/^}/p' "$PROJECT_ROOT/bin/hype")
    echo "$func_block" | grep -q 'update_dependencies'
}

@test "deps: update calls cmd_update with args" {
    grep -q 'update) shift; cmd_update "\$@"' "$PROJECT_ROOT/bin/hype"
}

# =============================================================================
# version_compare logic tests (inline implementation)
# =============================================================================

# Test version_compare by reimplementing the same logic
_version_compare() {
    local v1="$1" v2="$2"
    if [[ "$v1" == "$v2" ]]; then echo 0; return; fi
    local sorted
    sorted=$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -1)
    if [[ "$sorted" == "$v1" ]]; then echo -1; else echo 1; fi
}

@test "deps: version_compare equal returns 0" {
    local result
    result=$(_version_compare "1.2.3" "1.2.3")
    [[ "$result" == "0" ]]
}

@test "deps: version_compare less returns -1" {
    local result
    result=$(_version_compare "0.54.0" "0.55.0")
    [[ "$result" == "-1" ]]
}

@test "deps: version_compare greater returns 1" {
    local result
    result=$(_version_compare "0.57.0" "0.56.99")
    [[ "$result" == "1" ]]
}

@test "deps: version_compare handles two-segment versions" {
    local result
    result=$(_version_compare "1.6" "1.7")
    [[ "$result" == "-1" ]]
}

@test "deps: update_dependencies handles claude specially" {
    local func_block
    func_block=$(sed -n '/^update_dependencies()/,/^}/p' "$PROJECT_ROOT/bin/hype")
    echo "$func_block" | grep -q 'claude update'
}

@test "deps: update_dependencies does NOT continue after claude update (version check)" {
    local func_block
    func_block=$(sed -n '/^update_dependencies()/,/^}/p' "$PROJECT_ROOT/bin/hype")
    # The claude block should NOT have 'continue' — falls through to version check
    local claude_block
    claude_block=$(echo "$func_block" | sed -n '/cmd.*==.*claude/,/fi/p')
    ! echo "$claude_block" | grep -q 'continue'
}

@test "deps: update_dependencies uses sudo claude update for root-owned binary" {
    local func_block
    func_block=$(sed -n '/^update_dependencies()/,/^}/p' "$PROJECT_ROOT/bin/hype")
    echo "$func_block" | grep -q 'sudo claude update'
}

@test "deps: claude has no brew_pkg in deps.conf (uses own updater)" {
    local claude_line
    claude_line=$(grep '^claude|' "$PROJECT_ROOT/deps.conf")
    local brew_pkg
    brew_pkg=$(echo "$claude_line" | cut -d'|' -f6)
    [[ -z "$brew_pkg" ]]
}

@test "deps: check_dep_versions has fallback for missing deps.conf" {
    local func_block
    func_block=$(sed -n '/^check_dep_versions()/,/^}/p' "$PROJECT_ROOT/bin/hype")
    echo "$func_block" | grep -q 'check_deps_fallback'
}

@test "deps: help text mentions --no-deps" {
    grep -q '\-\-no-deps' "$PROJECT_ROOT/bin/hype"
}

# =============================================================================
# bin/hype daemon-free tests (v2.5.3 — daemon removed in beads v0.50)
# =============================================================================

@test "bin/hype: no bd daemon calls" {
    ! grep -q 'bd daemon' "$PROJECT_ROOT/bin/hype"
}

@test "bin/hype: cmd_init uses bd list health probe" {
    local func_block
    func_block=$(sed -n '/^cmd_init()/,/^}/p' "$PROJECT_ROOT/bin/hype")
    echo "$func_block" | grep -q 'bd list --limit 1'
}

@test "bin/hype: cmd_start uses bd list health probe" {
    local func_block
    func_block=$(sed -n '/^cmd_start()/,/^}/p' "$PROJECT_ROOT/bin/hype")
    echo "$func_block" | grep -q 'bd list --limit 1'
}

@test "run-testers.sh: no bd daemon calls" {
    ! grep -q 'bd daemon' "$SCRIPTS_DIR/run-testers.sh"
}

@test "docs/troubleshooting.md: no bd daemon calls" {
    ! grep -q 'bd daemon' "$PROJECT_ROOT/docs/troubleshooting.md"
}

# =============================================================================
# Manager tool restrictions (v2.5.3 — prevent code writing)
# =============================================================================

@test "run_interactive_agent uses --allowedTools" {
    local func_block
    func_block=$(sed -n '/^run_interactive_agent()/,/^}/p' "$SCRIPTS_DIR/hype.sh")
    echo "$func_block" | grep -q '\-\-allowedTools'
}

@test "run_interactive_agent does NOT allow Edit tool" {
    local func_block
    func_block=$(sed -n '/^run_interactive_agent()/,/^}/p' "$SCRIPTS_DIR/hype.sh")
    ! echo "$func_block" | grep -q 'Edit'
}

@test "run_interactive_agent allows Read and Grep" {
    local func_block
    func_block=$(sed -n '/^run_interactive_agent()/,/^}/p' "$SCRIPTS_DIR/hype.sh")
    echo "$func_block" | grep -q 'Read'
    echo "$func_block" | grep -q 'Grep'
}
