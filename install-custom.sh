#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Custom OpenClaw Installer — builds from Rita5fr/openclaw fork
# Installs all prerequisites (Node.js 22+, Git, pnpm) automatically
# Usage:  curl -fsSL https://raw.githubusercontent.com/Rita5fr/openclaw/main/install-custom.sh | bash
# ─────────────────────────────────────────────────────────────
set -euo pipefail

REPO="https://github.com/Rita5fr/openclaw.git"
BRANCH="${OPENCLAW_BRANCH:-main}"
INSTALL_DIR="${OPENCLAW_INSTALL_DIR:-$HOME/.openclaw-src}"
BIN_DIR="${OPENCLAW_BIN_DIR:-$HOME/.local/bin}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { printf "${CYAN}▸${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}✔${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}⚠${NC} %s\n" "$*"; }
fail()  { printf "${RED}✖ %s${NC}\n" "$*" >&2; exit 1; }

# ── Detect OS ────────────────────────────────────────────────
detect_os() {
  case "$(uname -s)" in
    Linux*)  OS="linux" ;;
    Darwin*) OS="macos" ;;
    *)       fail "Unsupported OS: $(uname -s). This installer supports Linux and macOS." ;;
  esac
  info "Detected OS: $OS"
}

is_root() { [[ "$(id -u)" -eq 0 ]]; }

run_sudo() {
  if is_root; then
    "$@"
  else
    sudo "$@"
  fi
}

# ── Install Homebrew (macOS) ─────────────────────────────────
install_homebrew() {
  if [[ "$OS" != "macos" ]]; then return 0; fi
  if command -v brew &>/dev/null; then
    ok "Homebrew already installed"
    return 0
  fi
  info "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if [[ -f "/opt/homebrew/bin/brew" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -f "/usr/local/bin/brew" ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
  ok "Homebrew installed"
}

# ── Install Git ──────────────────────────────────────────────
install_git() {
  if command -v git &>/dev/null; then
    ok "Git $(git --version | awk '{print $3}')"
    return 0
  fi
  info "Installing Git..."
  if [[ "$OS" == "macos" ]]; then
    brew install git
  elif [[ "$OS" == "linux" ]]; then
    if command -v apt-get &>/dev/null; then
      run_sudo apt-get update -qq
      run_sudo apt-get install -y -qq git
    elif command -v dnf &>/dev/null; then
      run_sudo dnf install -y -q git
    elif command -v yum &>/dev/null; then
      run_sudo yum install -y -q git
    elif command -v pacman &>/dev/null; then
      run_sudo pacman -Sy --noconfirm git
    else
      fail "No supported package manager found. Install git manually."
    fi
  fi
  ok "Git installed"
}

# ── Install Node.js 22+ ─────────────────────────────────────
install_node() {
  if command -v node &>/dev/null; then
    local node_major
    node_major=$(node -e "console.log(process.versions.node.split('.')[0])")
    if [[ "$node_major" -ge 22 ]]; then
      ok "Node.js $(node -v)"
      return 0
    fi
    info "Node.js $(node -v) found but need >= 22, upgrading..."
  else
    info "Node.js not found, installing..."
  fi

  if [[ "$OS" == "macos" ]]; then
    brew install node@22
    brew link node@22 --overwrite --force 2>/dev/null || true
  elif [[ "$OS" == "linux" ]]; then
    # Install build tools first
    if command -v apt-get &>/dev/null; then
      run_sudo apt-get update -qq
      run_sudo apt-get install -y -qq curl ca-certificates gnupg build-essential
      # NodeSource setup
      local tmp
      tmp="$(mktemp)"
      curl -fsSL https://deb.nodesource.com/setup_22.x -o "$tmp"
      run_sudo bash "$tmp"
      run_sudo apt-get install -y -qq nodejs
      rm -f "$tmp"
    elif command -v dnf &>/dev/null; then
      run_sudo dnf install -y -q gcc-c++ make
      local tmp
      tmp="$(mktemp)"
      curl -fsSL https://rpm.nodesource.com/setup_22.x -o "$tmp"
      run_sudo bash "$tmp"
      run_sudo dnf install -y -q nodejs
      rm -f "$tmp"
    elif command -v yum &>/dev/null; then
      run_sudo yum install -y -q gcc-c++ make
      local tmp
      tmp="$(mktemp)"
      curl -fsSL https://rpm.nodesource.com/setup_22.x -o "$tmp"
      run_sudo bash "$tmp"
      run_sudo yum install -y -q nodejs
      rm -f "$tmp"
    elif command -v pacman &>/dev/null; then
      run_sudo pacman -Sy --noconfirm nodejs npm
    else
      fail "No supported package manager. Install Node.js 22+ manually: https://nodejs.org"
    fi
  fi

  # Verify
  if ! command -v node &>/dev/null; then
    fail "Node.js installation failed. Install manually: https://nodejs.org"
  fi
  local installed_major
  installed_major=$(node -e "console.log(process.versions.node.split('.')[0])")
  if [[ "$installed_major" -lt 22 ]]; then
    fail "Node.js >= 22 required but got $(node -v). Install manually."
  fi
  ok "Node.js $(node -v)"
}

# ── Install pnpm ─────────────────────────────────────────────
install_pnpm() {
  if command -v pnpm &>/dev/null; then
    ok "pnpm $(pnpm -v)"
    return 0
  fi
  info "Installing pnpm..."
  if command -v corepack &>/dev/null; then
    corepack enable 2>/dev/null || true
    corepack prepare pnpm@10 --activate 2>/dev/null || true
    hash -r 2>/dev/null || true
  fi
  if ! command -v pnpm &>/dev/null; then
    npm install -g pnpm@10
    hash -r 2>/dev/null || true
  fi
  if ! command -v pnpm &>/dev/null; then
    fail "pnpm installation failed. Run: npm install -g pnpm@10"
  fi
  ok "pnpm $(pnpm -v)"
}

# ── Fix npm permissions (Linux) ──────────────────────────────
fix_npm_permissions() {
  if [[ "$OS" != "linux" ]]; then return 0; fi
  if is_root; then return 0; fi

  local npm_prefix
  npm_prefix="$(npm config get prefix 2>/dev/null || true)"
  if [[ -z "$npm_prefix" ]]; then return 0; fi
  if [[ -w "$npm_prefix" || -w "$npm_prefix/lib" ]]; then return 0; fi

  info "Configuring npm for user-local installs..."
  mkdir -p "$HOME/.npm-global"
  npm config set prefix "$HOME/.npm-global"

  local path_line='export PATH="$HOME/.npm-global/bin:$PATH"'
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [[ -f "$rc" ]] && ! grep -q ".npm-global" "$rc" 2>/dev/null; then
      echo "" >> "$rc"
      echo "$path_line" >> "$rc"
    fi
  done
  export PATH="$HOME/.npm-global/bin:$PATH"
  ok "npm configured for user installs"
}

# ── Main ─────────────────────────────────────────────────────
echo ""
printf "${GREEN}════════════════════════════════════════════════════${NC}\n"
printf "${GREEN}  OpenClaw Custom Installer (Rita5fr fork)${NC}\n"
printf "${GREEN}════════════════════════════════════════════════════${NC}\n"
echo ""

detect_os

# Step 1: Install all prerequisites
info "Installing prerequisites..."
install_homebrew
install_git
fix_npm_permissions
install_node
install_pnpm

# Step 2: Clone / Pull
echo ""
info "Setting up OpenClaw source..."
if [ -d "$INSTALL_DIR/.git" ]; then
  info "Updating existing clone at $INSTALL_DIR..."
  cd "$INSTALL_DIR"
  git fetch origin "$BRANCH"
  git checkout "$BRANCH"
  git reset --hard "origin/$BRANCH"
  ok "Updated to latest $BRANCH"
else
  info "Cloning $REPO (branch: $BRANCH)..."
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$INSTALL_DIR"
  cd "$INSTALL_DIR"
  ok "Cloned to $INSTALL_DIR"
fi

# Step 3: Install dependencies
echo ""
info "Installing dependencies (this may take a few minutes)..."
pnpm install --frozen-lockfile 2>/dev/null || pnpm install
ok "Dependencies installed"

# Step 4: Build
info "Building OpenClaw..."
pnpm build
ok "Build complete"

# Step 5: Link binary
mkdir -p "$BIN_DIR"

cat > "$BIN_DIR/openclaw" << WRAPPER
#!/usr/bin/env bash
# OpenClaw wrapper — auto-generated by install-custom.sh
exec node "$INSTALL_DIR/openclaw.mjs" "\$@"
WRAPPER
chmod +x "$BIN_DIR/openclaw"

ok "Binary linked to $BIN_DIR/openclaw"

# Step 6: Ensure PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  SHELL_NAME=$(basename "${SHELL:-/bin/bash}")
  case "$SHELL_NAME" in
    zsh)  RC_FILE="$HOME/.zshrc" ;;
    fish) RC_FILE="$HOME/.config/fish/config.fish" ;;
    *)    RC_FILE="$HOME/.bashrc" ;;
  esac

  if [ -f "$RC_FILE" ] && ! grep -q "$BIN_DIR" "$RC_FILE" 2>/dev/null; then
    echo "" >> "$RC_FILE"
    echo "# OpenClaw (custom fork)" >> "$RC_FILE"
    if [ "$SHELL_NAME" = "fish" ]; then
      echo "set -gx PATH $BIN_DIR \$PATH" >> "$RC_FILE"
    else
      echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$RC_FILE"
    fi
    warn "Added $BIN_DIR to PATH in $RC_FILE — restart your shell or run: source $RC_FILE"
  fi
fi

# Step 7: Run doctor
export PATH="$BIN_DIR:$PATH"
info "Running doctor..."
"$BIN_DIR/openclaw" doctor --non-interactive 2>/dev/null || true

# Step 8: Done
echo ""
printf "${GREEN}════════════════════════════════════════════════════${NC}\n"
printf "${GREEN}  OpenClaw installed successfully!${NC}\n"
printf "${GREEN}════════════════════════════════════════════════════${NC}\n"
echo ""
info "Version: $(node "$INSTALL_DIR/openclaw.mjs" --version 2>/dev/null || echo 'unknown')"
info "Source:  $INSTALL_DIR"
info "Binary:  $BIN_DIR/openclaw"
echo ""
info "Get started:"
echo "  openclaw onboard         # First-time setup"
echo "  openclaw doctor          # Check health"
echo "  openclaw gateway run     # Start gateway"
echo ""
info "To update later, re-run this script or:"
echo "  cd $INSTALL_DIR && git pull && pnpm install && pnpm build"
echo ""
