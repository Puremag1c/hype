#!/usr/bin/env bash
#
# Hype Global Installer
# Устанавливает hype в ~/.hype/ для использования в любых проектах
#
# Использование:
#   curl -fsSL https://raw.githubusercontent.com/Puremag1c/hype/main/install.sh | bash
#

set -euo pipefail

HYPE_HOME="${HYPE_HOME:-$HOME/.hype}"
REPO_URL="https://github.com/Puremag1c/hype.git"

# === Colors ===

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}▸${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn()    { echo -e "${YELLOW}!${NC} $1"; }
error()   { echo -e "${RED}✗${NC} $1" >&2; }

# Retry with exponential backoff
retry() {
    local max_attempts=${RETRY_MAX:-3}
    local delay=${RETRY_DELAY:-2}
    local attempt=1
    local exit_code=0

    while [[ $attempt -le $max_attempts ]]; do
        if "$@"; then
            return 0
        else
            exit_code=$?
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            warn "Attempt $attempt failed, retrying in ${delay}s..."
            sleep $delay
            delay=$((delay * 2))
        fi

        attempt=$((attempt + 1))
    done

    return $exit_code
}

# Test network connectivity
check_network() {
    if curl -fsS --connect-timeout 5 https://github.com &>/dev/null; then
        return 0
    elif curl -fsS --connect-timeout 5 https://google.com &>/dev/null; then
        return 0
    else
        return 1
    fi
}

echo ""
echo "╔══════════════════════════════════════╗"
echo "║       Hype Global Installer       ║"
echo "╚══════════════════════════════════════╝"
echo ""

# === Fix permissions if needed ===
# If ~/.hype exists but is owned by root (from previous sudo install),
# fix ownership so git and other operations work correctly

if [[ -d "$HYPE_HOME" ]]; then
    if [[ ! -w "$HYPE_HOME" ]] || [[ -d "$HYPE_HOME/.git" && ! -w "$HYPE_HOME/.git" ]]; then
        warn "~/.hype has incorrect permissions (probably from previous sudo install)"
        info "Fixing permissions... (sudo password may be required)"

        if sudo chown -R "$(whoami)" "$HYPE_HOME"; then
            success "Permissions fixed"
        else
            error "Cannot fix permissions"
            echo "  Run manually: sudo chown -R $(whoami) ~/.hype"
            exit 1
        fi
    fi
fi

# === Определяем систему ===

OS="unknown"
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS="linux"
fi

# === Функции установки ===

install_homebrew() {
    if command -v brew &>/dev/null; then
        return
    fi

    info "Installing Homebrew..."

    if retry curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o /tmp/brew-install.sh; then
        if /bin/bash /tmp/brew-install.sh; then
            rm -f /tmp/brew-install.sh

            # Добавляем brew в PATH для текущей сессии
            if [[ -f "/opt/homebrew/bin/brew" ]]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
            elif [[ -f "/usr/local/bin/brew" ]]; then
                eval "$(/usr/local/bin/brew shellenv)"
            fi
            success "Homebrew installed"
        else
            rm -f /tmp/brew-install.sh
            error "Homebrew installation failed"
        fi
    else
        error "Could not download Homebrew installer"
    fi
}

install_with_brew() {
    local pkg=$1
    local cmd=${2:-$1}

    if ! command -v "$cmd" &>/dev/null; then
        info "Installing $pkg..."
        brew install "$pkg"
        success "$pkg installed"
    else
        success "$pkg already installed"
    fi
}

install_with_apt() {
    local pkg=$1
    local cmd=${2:-$1}

    if ! command -v "$cmd" &>/dev/null; then
        info "Installing $pkg..."
        sudo apt install -y "$pkg"
        success "$pkg installed"
    else
        success "$pkg already installed"
    fi
}

install_beads_macos() {
    if ! command -v bd &>/dev/null; then
        info "Installing beads..."
        brew install beads
        success "beads installed"
    else
        # Check if using outdated tap version
        if brew list bd &>/dev/null 2>&1; then
            info "Migrating from tap to homebrew-core..."
            brew uninstall bd 2>/dev/null || true
            brew untap steveyegge/beads 2>/dev/null || true
            brew install beads
            success "beads migrated to homebrew-core"
        else
            success "beads already installed"
        fi
    fi
}

install_beads_linux() {
    if ! command -v bd &>/dev/null; then
        if command -v brew &>/dev/null; then
            info "Installing beads via brew..."
            brew install beads
            success "beads installed"
        elif command -v go &>/dev/null; then
            info "Installing beads via go..."
            go install github.com/steveyegge/beads/cmd/bd@latest
            success "beads installed"
        else
            warn "Cannot install beads: need brew or go"
            echo "  See: https://github.com/steveyegge/beads"
        fi
    else
        # Check if using outdated tap version
        if command -v brew &>/dev/null && brew list bd &>/dev/null 2>&1; then
            info "Migrating from tap to homebrew-core..."
            brew uninstall bd 2>/dev/null || true
            brew untap steveyegge/beads 2>/dev/null || true
            brew install beads
            success "beads migrated to homebrew-core"
        else
            success "beads already installed"
        fi
    fi
}

install_claude_code() {
    if command -v claude &>/dev/null; then
        success "Claude Code already installed"
        return
    fi

    info "Installing Claude Code..."

    # Method 1: Official installer with retry
    if retry curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh; then
        if bash /tmp/claude-install.sh; then
            rm -f /tmp/claude-install.sh
            success "Claude Code installed"
            return
        fi
        rm -f /tmp/claude-install.sh
    fi

    # Method 2: Try with different DNS (if primary fails)
    info "Trying alternative method..."
    if curl --dns-servers 8.8.8.8,1.1.1.1 -fsSL https://claude.ai/install.sh 2>/dev/null | bash; then
        success "Claude Code installed"
        return
    fi

    # Method 3: npm fallback (if available)
    if command -v npm &>/dev/null; then
        info "Trying npm install..."
        if npm install -g @anthropic-ai/claude-code 2>/dev/null; then
            success "Claude Code installed via npm"
            return
        fi
    fi

    # All methods failed
    warn "Claude Code installation failed"
    echo ""
    echo "  Install manually:"
    echo "    macOS: brew install --cask claude"
    echo "    or:    https://claude.ai/download"
    echo ""
}

# Install gh and jq directly (for Linux without sudo/brew)
install_binaries_direct() {
    mkdir -p "$HOME/.local/bin"

    # Install jq
    if ! command -v jq &>/dev/null; then
        info "Downloading jq binary..."
        local jq_url="https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64"
        if curl -fsSL "$jq_url" -o "$HOME/.local/bin/jq"; then
            chmod +x "$HOME/.local/bin/jq"
            success "jq installed to ~/.local/bin/"
        else
            warn "Could not download jq"
        fi
    else
        success "jq already installed"
    fi

    # Install gh
    if ! command -v gh &>/dev/null; then
        info "Downloading gh binary..."
        # Get latest version
        local gh_version=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')
        if [[ -n "$gh_version" ]]; then
            local gh_url="https://github.com/cli/cli/releases/download/v${gh_version}/gh_${gh_version}_linux_amd64.tar.gz"
            if curl -fsSL "$gh_url" -o /tmp/gh.tar.gz; then
                tar -xzf /tmp/gh.tar.gz -C /tmp
                mv "/tmp/gh_${gh_version}_linux_amd64/bin/gh" "$HOME/.local/bin/"
                chmod +x "$HOME/.local/bin/gh"
                rm -rf /tmp/gh.tar.gz "/tmp/gh_${gh_version}_linux_amd64"
                success "gh installed to ~/.local/bin/"
            else
                warn "Could not download gh"
            fi
        else
            warn "Could not determine gh version"
        fi
    else
        success "gh already installed"
    fi
}

# === Step 1: Install/Update hype ===

echo "Step 1: Installing hype to $HYPE_HOME"
echo ""

# Check network before starting
if ! check_network; then
    error "No network connection. Please check your internet and try again."
    exit 1
fi

if [[ -d "$HYPE_HOME" ]]; then
    if [[ -d "$HYPE_HOME/.git" ]]; then
        info "Updating existing installation..."
        cd "$HYPE_HOME"
        if retry git pull --ff-only; then
            success "Updated to $(cat VERSION)"
        else
            warn "Update failed, using existing version"
        fi
    else
        warn "$HYPE_HOME exists but is not a git repo"
        info "Backing up and reinstalling..."
        mv "$HYPE_HOME" "$HYPE_HOME.backup.$(date +%s)"
        if retry git clone --depth 1 "$REPO_URL" "$HYPE_HOME"; then
            success "Installed $(cat "$HYPE_HOME/VERSION")"
        else
            error "Failed to clone hype repository"
            exit 1
        fi
    fi
else
    info "Cloning hype..."
    if retry git clone --depth 1 "$REPO_URL" "$HYPE_HOME"; then
        success "Installed $(cat "$HYPE_HOME/VERSION")"
    else
        error "Failed to clone hype repository"
        exit 1
    fi
fi

# === Step 2: Install dependencies ===

echo ""
echo "Step 2: Installing dependencies"
echo ""

if [[ "$OS" == "macos" ]]; then
    install_homebrew
    install_beads_macos
    install_with_brew "gh"
    install_with_brew "jq"
    install_claude_code

    # gitleaks optional
    if ! command -v gitleaks &>/dev/null; then
        info "Installing gitleaks (optional)..."
        brew install gitleaks 2>/dev/null || warn "gitleaks skipped"
    fi

elif [[ "$OS" == "linux" ]]; then
    # Check if we have sudo access
    has_sudo=false
    if command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
        has_sudo=true
    fi

    # Strategy: try apt with sudo, fallback to Homebrew, fallback to direct binaries
    if [[ "$has_sudo" = true ]] && command -v apt &>/dev/null; then
        info "Using apt (sudo available)..."
        sudo apt update -qq
        install_with_apt "gh"
        install_with_apt "jq"
    else
        # No sudo - use Homebrew on Linux or direct binaries
        if command -v brew &>/dev/null; then
            info "Using Homebrew (no sudo)..."
            install_with_brew "gh"
            install_with_brew "jq"
        else
            # Try to install Homebrew on Linux
            info "Installing Homebrew for Linux (no sudo required)..."
            if retry curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o /tmp/brew-install.sh; then
                # Homebrew installer on Linux doesn't need sudo
                NONINTERACTIVE=1 /bin/bash /tmp/brew-install.sh
                rm -f /tmp/brew-install.sh

                # Add to PATH
                if [[ -d "/home/linuxbrew/.linuxbrew" ]]; then
                    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
                fi

                if command -v brew &>/dev/null; then
                    success "Homebrew installed"
                    install_with_brew "gh"
                    install_with_brew "jq"
                else
                    # Homebrew failed, try direct binary downloads
                    install_binaries_direct
                fi
            else
                install_binaries_direct
            fi
        fi
    fi

    install_beads_linux
    install_claude_code

    # gitleaks (optional, try without sudo)
    if ! command -v gitleaks &>/dev/null; then
        if command -v go &>/dev/null; then
            info "Installing gitleaks via go..."
            go install github.com/gitleaks/gitleaks/v8@latest 2>/dev/null && success "gitleaks installed" || true
        elif [[ "$has_sudo" = true ]] && command -v snap &>/dev/null; then
            info "Installing gitleaks via snap..."
            sudo snap install gitleaks 2>/dev/null && success "gitleaks installed" || true
        fi
    else
        success "gitleaks already installed"
    fi
else
    error "Unknown OS: $OSTYPE"
    exit 1
fi

# === Step 3: Add to PATH ===

echo ""
echo "Step 3: Configuring PATH"
echo ""

add_to_path() {
    local shell_rc=$1

    if [[ -f "$shell_rc" ]]; then
        local changed=false

        # Add ~/.hype/bin
        if ! grep -q '.hype/bin' "$shell_rc"; then
            echo "" >> "$shell_rc"
            echo "# Hype" >> "$shell_rc"
            echo 'export PATH="$HOME/.hype/bin:$PATH"' >> "$shell_rc"
            changed=true
        fi

        # Add ~/.local/bin (for Claude Code)
        if ! grep -q '.local/bin' "$shell_rc"; then
            if [[ "$changed" == "false" ]]; then
                echo "" >> "$shell_rc"
                echo "# Hype" >> "$shell_rc"
            fi
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$shell_rc"
            changed=true
        fi

        if [[ "$changed" == "true" ]]; then
            success "Updated $shell_rc"
        else
            success "Already configured in $shell_rc"
        fi
    fi
}

# Fish shell uses different syntax
add_to_fish_path() {
    local fish_config="$HOME/.config/fish/config.fish"

    if [[ -f "$fish_config" ]]; then
        local changed=false

        if ! grep -q '.hype/bin' "$fish_config"; then
            echo "" >> "$fish_config"
            echo "# Hype" >> "$fish_config"
            echo 'fish_add_path $HOME/.hype/bin' >> "$fish_config"
            changed=true
        fi

        if ! grep -q '.local/bin' "$fish_config"; then
            if [[ "$changed" == "false" ]]; then
                echo "" >> "$fish_config"
                echo "# Hype" >> "$fish_config"
            fi
            echo 'fish_add_path $HOME/.local/bin' >> "$fish_config"
            changed=true
        fi

        if [[ "$changed" == "true" ]]; then
            success "Updated $fish_config"
        else
            success "Already configured in $fish_config"
        fi
    fi
}

# Add to all existing shell config files (don't guess - sudo may lose $SHELL)
[[ -f "$HOME/.zshrc" ]] && add_to_path "$HOME/.zshrc"
[[ -f "$HOME/.bashrc" ]] && add_to_path "$HOME/.bashrc"
[[ -f "$HOME/.bash_profile" ]] && add_to_path "$HOME/.bash_profile"
[[ -f "$HOME/.config/fish/config.fish" ]] && add_to_fish_path

# Add to current session
export PATH="$HYPE_HOME/bin:$HOME/.local/bin:$PATH"

# === Step 4: Verify ===

echo ""
echo "Step 4: Verifying installation"
echo ""

check_cmd() {
    local cmd=$1
    local name=${2:-$1}
    if command -v "$cmd" &>/dev/null; then
        success "$name"
        return 0
    else
        error "$name NOT INSTALLED"
        return 1
    fi
}

check_cmd "hype" "hype CLI"
check_cmd "bd" "beads"
check_cmd "gh" "GitHub CLI"
check_cmd "jq" "jq"

# Claude Code is optional (may fail due to network)
if command -v claude &>/dev/null; then
    success "Claude Code"
else
    warn "Claude Code (not installed - install manually: https://claude.ai/download)"
fi

if command -v gitleaks &>/dev/null; then
    success "gitleaks (optional)"
else
    info "gitleaks (optional, not installed)"
fi

# === Done ===

echo ""
echo "╔══════════════════════════════════════╗"
echo "║         Installation complete!       ║"
echo "╚══════════════════════════════════════╝"
echo ""
echo "To initialize a project:"
echo ""
echo "  cd your-project"
echo "  hype init"
echo ""
echo "Note: Restart your terminal or run:"
echo "  source ~/.zshrc  # or ~/.bashrc"
echo ""
