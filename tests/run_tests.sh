#!/usr/bin/env bash
# tests/run_tests.sh
# Main test runner for HYPE
#
# Usage:
#   ./tests/run_tests.sh           # Run all tests
#   ./tests/run_tests.sh unit      # Run only unit tests
#   ./tests/run_tests.sh integration  # Run only integration tests
#   ./tests/run_tests.sh e2e       # Run only e2e tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors (disabled in CI)
if [[ -t 1 && -z "${CI:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

log_info() { echo -e "${BLUE}ℹ${NC} $*"; }
log_success() { echo -e "${GREEN}✓${NC} $*"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $*"; }
log_error() { echo -e "${RED}✗${NC} $*"; }

# Check and install bats if needed
ensure_bats() {
    if command -v bats &>/dev/null; then
        log_success "bats found: $(bats --version)"
        return 0
    fi

    log_warn "bats not found, installing..."

    # Try homebrew first (macOS)
    if command -v brew &>/dev/null; then
        log_info "Installing via homebrew..."
        brew install bats-core
        if command -v bats &>/dev/null; then
            log_success "bats installed via homebrew"
            return 0
        fi
    fi

    # Try apt (Debian/Ubuntu)
    if command -v apt-get &>/dev/null; then
        log_info "Installing via apt..."
        sudo apt-get update && sudo apt-get install -y bats
        if command -v bats &>/dev/null; then
            log_success "bats installed via apt"
            return 0
        fi
    fi

    # Fallback: install from source
    log_info "Installing bats from source..."
    local bats_tmp
    bats_tmp=$(mktemp -d)

    git clone --depth 1 https://github.com/bats-core/bats-core.git "$bats_tmp/bats-core"
    sudo "$bats_tmp/bats-core/install.sh" /usr/local

    # Install helpers
    git clone --depth 1 https://github.com/bats-core/bats-support.git "$bats_tmp/bats-support"
    sudo mkdir -p /usr/local/lib/bats-support
    sudo cp -r "$bats_tmp/bats-support/"* /usr/local/lib/bats-support/

    git clone --depth 1 https://github.com/bats-core/bats-assert.git "$bats_tmp/bats-assert"
    sudo mkdir -p /usr/local/lib/bats-assert
    sudo cp -r "$bats_tmp/bats-assert/"* /usr/local/lib/bats-assert/

    rm -rf "$bats_tmp"

    if command -v bats &>/dev/null; then
        log_success "bats installed from source"
        return 0
    fi

    log_error "Failed to install bats"
    return 1
}

# Run tests in a directory
run_test_suite() {
    local suite="$1"
    local test_dir="$SCRIPT_DIR/$suite"

    if [[ ! -d "$test_dir" ]]; then
        log_warn "No $suite tests found"
        return 0
    fi

    local test_files
    test_files=$(find "$test_dir" -name "*.bats" 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$test_files" -eq 0 ]]; then
        log_warn "No .bats files in $suite/"
        return 0
    fi

    echo ""
    log_info "Running $suite tests ($test_files file(s))..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    bats --tap "$test_dir"
}

main() {
    local suite="${1:-all}"

    echo ""
    echo "╔═══════════════════════════════════════╗"
    echo "║         HYPE Test Runner              ║"
    echo "╚═══════════════════════════════════════╝"
    echo ""

    # Ensure bats is installed
    ensure_bats || exit 1

    # Change to project root for consistent paths
    cd "$PROJECT_ROOT"

    # Track results
    local failed=0

    case "$suite" in
        unit)
            run_test_suite "unit" || failed=1
            ;;
        integration)
            run_test_suite "integration" || failed=1
            ;;
        e2e)
            run_test_suite "e2e" || failed=1
            ;;
        all)
            run_test_suite "unit" || failed=1
            run_test_suite "integration" || failed=1
            run_test_suite "e2e" || failed=1
            ;;
        *)
            log_error "Unknown test suite: $suite"
            echo "Usage: $0 [unit|integration|e2e|all]"
            exit 1
            ;;
    esac

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ $failed -eq 0 ]]; then
        log_success "All tests passed!"
        exit 0
    else
        log_error "Some tests failed"
        exit 1
    fi
}

main "$@"
