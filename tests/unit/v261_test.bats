#!/usr/bin/env bats
# tests/unit/v261_test.bats
# Tests for v2.6.1: coder lint step, tester-ci agent, completion version grep

load '../helpers/setup'

# =============================================================================
# Coder lint step (coder.md section 7.5)
# =============================================================================

@test "coder.md: has lint step before test step" {
    local coder="$AGENTS_DIR/coder.md"

    # Lint step must exist
    grep -q 'Запусти линтер' "$coder"

    # Lint must come BEFORE tests
    local lint_line test_line
    lint_line=$(grep -n 'Запусти линтер' "$coder" | head -1 | cut -d: -f1)
    test_line=$(grep -n 'Запусти тесты' "$coder" | head -1 | cut -d: -f1)
    [ "$lint_line" -lt "$test_line" ]
}

@test "coder.md: lint detects Python (ruff/black)" {
    local coder="$AGENTS_DIR/coder.md"

    grep -q 'ruff check --fix' "$coder"
    grep -q 'ruff format' "$coder"
    grep -q 'black' "$coder"
}

@test "coder.md: lint detects Elixir (mix format)" {
    local coder="$AGENTS_DIR/coder.md"

    grep -q 'mix format' "$coder"
}

@test "coder.md: lint detects JS/TS (eslint/npm run lint)" {
    local coder="$AGENTS_DIR/coder.md"

    grep -q 'npm run lint' "$coder"
    grep -q 'eslint' "$coder"
}

@test "coder.md: lint detects Rust (cargo clippy)" {
    local coder="$AGENTS_DIR/coder.md"

    grep -q 'cargo clippy' "$coder"
}

@test "coder.md: lint detects Go (go vet)" {
    local coder="$AGENTS_DIR/coder.md"

    grep -q 'go vet' "$coder"
}

@test "coder.md: lint auto-commits fixes" {
    local coder="$AGENTS_DIR/coder.md"

    grep -q 'style: auto-fix lint issues' "$coder"
}

@test "coder.md: lint warns about manual fixes" {
    local coder="$AGENTS_DIR/coder.md"

    grep -q 'авто-исправить' "$coder"
}

# =============================================================================
# Tester CI agent
# =============================================================================

@test "tester-ci.md: agent file exists" {
    [ -f "$AGENTS_DIR/tester-ci.md" ]
}

@test "tester-ci.md: uses haiku model" {
    grep -q 'model: haiku' "$AGENTS_DIR/tester-ci.md"
}

@test "tester-ci.md: checks for .github/workflows" {
    grep -q '.github/workflows' "$AGENTS_DIR/tester-ci.md"
}

@test "tester-ci.md: checks gh auth" {
    grep -q 'gh auth status' "$AGENTS_DIR/tester-ci.md"
}

@test "tester-ci.md: uses gh run watch" {
    grep -q 'gh run watch' "$AGENTS_DIR/tester-ci.md"
}

@test "tester-ci.md: creates P0 bug on failure" {
    grep -q 'priority=0' "$AGENTS_DIR/tester-ci.md"
    grep -q 'SMOKE.*CI' "$AGENTS_DIR/tester-ci.md"
}

@test "tester-ci.md: checks for duplicate bugs" {
    grep -q 'OPEN_BUG' "$AGENTS_DIR/tester-ci.md"
}

@test "tester-ci.md: saves evidence" {
    grep -q '.hype/evidence/ci' "$AGENTS_DIR/tester-ci.md"
}

@test "run-testers.sh: ci tester included for all project types" {
    local script="$SCRIPTS_DIR/run-testers.sh"

    # All project types must include ci
    grep -A1 'web)' "$script" | grep -q 'ci'
    grep -A1 'api)' "$script" | grep -q 'ci'
    grep -A1 'cli)' "$script" | grep -q 'ci'
    grep -A1 'library)' "$script" | grep -q 'ci'
}

@test "run-testers.sh: ci tester NOT in playwright sequential group" {
    local script="$SCRIPTS_DIR/run-testers.sh"

    # ci must NOT be in the functional|visual case (sequential Playwright)
    ! grep -A2 'functional|visual)' "$script" | grep -q 'ci'
}

# =============================================================================
# Completion version grep fix
# =============================================================================

@test "completion.md: version grep includes *.py" {
    grep -q 'include="\*.py"' "$AGENTS_DIR/completion.md"
}

@test "completion.md: version grep includes *.exs" {
    grep -q 'include="\*.exs"' "$AGENTS_DIR/completion.md"
}

@test "completion.md: version grep includes *.yaml" {
    grep -q 'include="\*.yaml"' "$AGENTS_DIR/completion.md"
}

@test "completion.md: version grep includes *.cfg" {
    grep -q 'include="\*.cfg"' "$AGENTS_DIR/completion.md"
}

@test "completion.md: version grep excludes __pycache__" {
    grep 'grep -rn.*CURRENT' "$AGENTS_DIR/completion.md" | grep -q '__pycache__'
}

@test "completion.md: detects __version__ in Python packages" {
    grep -q '__version__' "$AGENTS_DIR/completion.md"
}

@test "completion.md: checks pubspec.yaml" {
    grep -q 'pubspec.yaml' "$AGENTS_DIR/completion.md"
}

@test "completion.md: checks Chart.yaml" {
    grep -q 'Chart.yaml' "$AGENTS_DIR/completion.md"
}

@test "completion.md: update instructions for __init__.py" {
    grep -q '__init__.py' "$AGENTS_DIR/completion.md"
}
