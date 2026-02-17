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

# ── Configure pnpm global bin directory ──────────────────────
setup_pnpm_global_bin() {
  # pnpm needs PNPM_HOME + global-bin-dir for global installs (skills like clawhub, mcporter)
  local pnpm_home="${PNPM_HOME:-$HOME/.local/share/pnpm}"
  mkdir -p "$pnpm_home"
  export PNPM_HOME="$pnpm_home"
  export PATH="$PNPM_HOME:$PATH"

  # Run pnpm setup to wire everything (idempotent)
  pnpm setup 2>/dev/null || true

  # Ensure PNPM_HOME is in shell rc files
  SHELL_NAME=$(basename "${SHELL:-/bin/bash}")
  case "$SHELL_NAME" in
    zsh)  RC_FILE="$HOME/.zshrc" ;;
    fish) RC_FILE="$HOME/.config/fish/config.fish" ;;
    *)    RC_FILE="$HOME/.bashrc" ;;
  esac
  touch "$RC_FILE" 2>/dev/null || true

  if ! grep -q "PNPM_HOME" "$RC_FILE" 2>/dev/null; then
    echo "" >> "$RC_FILE"
    echo "# pnpm global bin" >> "$RC_FILE"
    if [ "$SHELL_NAME" = "fish" ]; then
      echo "set -gx PNPM_HOME \"$pnpm_home\"" >> "$RC_FILE"
      echo "set -gx PATH \"\$PNPM_HOME\" \$PATH" >> "$RC_FILE"
    else
      echo "export PNPM_HOME=\"$pnpm_home\"" >> "$RC_FILE"
      echo 'export PATH="$PNPM_HOME:$PATH"' >> "$RC_FILE"
    fi
  fi

  ok "pnpm global bin directory configured: $pnpm_home"
}

# ── Install Homebrew on Linux (linuxbrew) for skills like wacli ──
install_linuxbrew() {
  if [[ "$OS" != "linux" ]]; then return 0; fi
  if command -v brew &>/dev/null; then
    ok "Homebrew (Linuxbrew) already installed"
    return 0
  fi
  info "Installing Homebrew (Linuxbrew) for skill dependencies..."
  # Install linuxbrew prerequisites
  if command -v apt-get &>/dev/null; then
    run_sudo apt-get install -y -qq build-essential procps curl file git 2>/dev/null || true
  elif command -v dnf &>/dev/null; then
    run_sudo dnf install -y -q procps-ng curl file git gcc 2>/dev/null || true
  elif command -v yum &>/dev/null; then
    run_sudo yum install -y -q procps-ng curl file git gcc 2>/dev/null || true
  fi

  # Install Homebrew (non-interactive)
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
    warn "Linuxbrew install failed (non-fatal) — wacli skill will be unavailable"
    return 0
  }

  # Add brew to current session + shell rc
  local brew_path=""
  if [[ -f "/home/linuxbrew/.linuxbrew/bin/brew" ]]; then
    brew_path="/home/linuxbrew/.linuxbrew/bin/brew"
  elif [[ -f "$HOME/.linuxbrew/bin/brew" ]]; then
    brew_path="$HOME/.linuxbrew/bin/brew"
  fi

  if [[ -n "$brew_path" ]]; then
    eval "$("$brew_path" shellenv)"
    SHELL_NAME=$(basename "${SHELL:-/bin/bash}")
    case "$SHELL_NAME" in
      zsh)  RC_FILE="$HOME/.zshrc" ;;
      fish) RC_FILE="$HOME/.config/fish/config.fish" ;;
      *)    RC_FILE="$HOME/.bashrc" ;;
    esac
    touch "$RC_FILE" 2>/dev/null || true
    if ! grep -q "linuxbrew" "$RC_FILE" 2>/dev/null; then
      echo "" >> "$RC_FILE"
      echo "# Homebrew (Linuxbrew)" >> "$RC_FILE"
      echo "eval \"\$($brew_path shellenv)\"" >> "$RC_FILE"
    fi
    ok "Linuxbrew installed"
  fi
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
setup_pnpm_global_bin
install_linuxbrew

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

# Step 5: Build Control UI assets
info "Building Control UI..."
if [ -d "$INSTALL_DIR/ui" ]; then
  pnpm ui:build 2>/dev/null && ok "Control UI built" || warn "Control UI build failed (non-fatal)"
else
  warn "UI source directory not found — skipping ui:build"
fi

# Step 6: Link binary
mkdir -p "$BIN_DIR"

cat > "$BIN_DIR/openclaw" << WRAPPER
#!/usr/bin/env bash
# OpenClaw wrapper — auto-generated by install-custom.sh
exec node "$INSTALL_DIR/openclaw.mjs" "\$@"
WRAPPER
chmod +x "$BIN_DIR/openclaw"

ok "Binary linked to $BIN_DIR/openclaw"

# Step 7: Ensure PATH (add to current session AND shell rc)
export PATH="$BIN_DIR:$PATH"

if [[ ":$PATH:" != *":$BIN_DIR:"* ]] || true; then
  SHELL_NAME=$(basename "${SHELL:-/bin/bash}")
  case "$SHELL_NAME" in
    zsh)  RC_FILE="$HOME/.zshrc" ;;
    fish) RC_FILE="$HOME/.config/fish/config.fish" ;;
    *)    RC_FILE="$HOME/.bashrc" ;;
  esac

  # Create rc file if it doesn't exist
  touch "$RC_FILE" 2>/dev/null || true

  if ! grep -q "$BIN_DIR" "$RC_FILE" 2>/dev/null; then
    echo "" >> "$RC_FILE"
    echo "# OpenClaw (custom fork)" >> "$RC_FILE"
    if [ "$SHELL_NAME" = "fish" ]; then
      echo "set -gx PATH $BIN_DIR \$PATH" >> "$RC_FILE"
    else
      echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$RC_FILE"
    fi
  fi
  ok "PATH configured in $RC_FILE"
fi

# Step 8: Create state directory (~/.openclaw) and subdirectories
STATE_DIR="$HOME/.openclaw"
info "Initializing state directory..."
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true
mkdir -p "$STATE_DIR/sessions" "$STATE_DIR/store" "$STATE_DIR/credentials"
ok "State directory ready: $STATE_DIR"

# Step 9: Bootstrap config — set gateway.mode and run setup
info "Configuring OpenClaw..."
"$BIN_DIR/openclaw" setup 2>/dev/null || true
"$BIN_DIR/openclaw" config set gateway.mode local 2>/dev/null || true
ok "Gateway mode set to local"

# Step 10: Generate gateway auth token if missing
if ! "$BIN_DIR/openclaw" config get gateway.auth.token &>/dev/null || \
   [ -z "$("$BIN_DIR/openclaw" config get gateway.auth.token 2>/dev/null)" ]; then
  GATEWAY_TOKEN=$(node -e "console.log(require('crypto').randomBytes(32).toString('hex'))" 2>/dev/null || openssl rand -hex 32)
  "$BIN_DIR/openclaw" config set gateway.auth.mode token 2>/dev/null || true
  "$BIN_DIR/openclaw" config set gateway.auth.token "$GATEWAY_TOKEN" 2>/dev/null || true
  ok "Gateway auth token generated"
else
  ok "Gateway auth token already configured"
fi

# Step 11: Disable memory search if no embedding provider is available
HAS_EMBEDDING=0
if [ -n "${OPENAI_API_KEY:-}" ] || [ -n "${GEMINI_API_KEY:-}" ]; then
  HAS_EMBEDDING=1
fi
if [ "$HAS_EMBEDDING" -eq 0 ]; then
  "$BIN_DIR/openclaw" config set agents.defaults.memorySearch.enabled false 2>/dev/null || true
  ok "Memory search disabled (no embedding provider — enable later with openclaw auth add)"
fi

# Step 12: Run doctor to verify
echo ""
info "Running doctor..."
"$BIN_DIR/openclaw" doctor --non-interactive 2>/dev/null || true

# Step 13: Create systemd service for auto-start
CURRENT_USER="$(whoami)"
NODE_PATH="$(command -v node)"
setup_systemd_service() {
  if [[ "$OS" != "linux" ]]; then
    warn "Systemd service only supported on Linux — skipping"
    return 0
  fi
  if ! command -v systemctl &>/dev/null; then
    warn "systemctl not found — skipping service setup"
    return 0
  fi

  info "Setting up systemd service..."

  local service_user="$CURRENT_USER"
  local service_home="$HOME"
  local service_install_dir="$INSTALL_DIR"
  local service_bin_dir="$BIN_DIR"

  # Build environment block — pass through API keys if set
  local env_lines=""
  env_lines+="Environment=\"HOME=$service_home\"\n"
  env_lines+="Environment=\"NODE_ENV=production\"\n"
  env_lines+="Environment=\"PATH=$service_bin_dir:$service_home/.local/share/pnpm:/usr/local/bin:/usr/bin:/bin\"\n"
  env_lines+="Environment=\"PNPM_HOME=$service_home/.local/share/pnpm\"\n"
  for key in OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY GOOGLE_API_KEY; do
    if [ -n "${!key:-}" ]; then
      env_lines+="Environment=\"$key=${!key}\"\n"
    fi
  done

  run_sudo bash -c "cat > /etc/systemd/system/openclaw.service << SYSTEMD_EOF
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$service_user
Group=$service_user
WorkingDirectory=$service_install_dir
ExecStart=$NODE_PATH $service_install_dir/openclaw.mjs gateway run
Restart=always
RestartSec=5
$(printf '%b' "$env_lines")
# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=openclaw

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=$service_home
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF"

  run_sudo systemctl daemon-reload
  run_sudo systemctl enable openclaw.service
  run_sudo systemctl restart openclaw.service
  ok "Systemd service created and started (auto-starts on boot)"
}

setup_systemd_service

# Step 14: Done
echo ""
printf "${GREEN}════════════════════════════════════════════════════${NC}\n"
printf "${GREEN}  OpenClaw installed successfully!${NC}\n"
printf "${GREEN}════════════════════════════════════════════════════${NC}\n"
echo ""
info "Version: $(node "$INSTALL_DIR/openclaw.mjs" --version 2>/dev/null || echo 'unknown')"
info "Source:  $INSTALL_DIR"
info "Binary:  $BIN_DIR/openclaw"
echo ""
printf "${YELLOW}  ┌────────────────────────────────────────────────┐${NC}\n"
printf "${YELLOW}  │  IMPORTANT: Source your shell config to use    │${NC}\n"
printf "${YELLOW}  │  openclaw in this session:                     │${NC}\n"
printf "${YELLOW}  │                                                │${NC}\n"
printf "${YELLOW}  │    source ~/.bashrc                            │${NC}\n"
printf "${YELLOW}  │                                                │${NC}\n"
printf "${YELLOW}  │  Or just open a new terminal.                  │${NC}\n"
printf "${YELLOW}  └────────────────────────────────────────────────┘${NC}\n"
echo ""
info "Get started:"
echo "  openclaw onboard         # First-time setup (API keys, channels)"
echo "  openclaw doctor          # Check health"
echo "  openclaw gateway run     # Start gateway (manual)"
echo ""
info "Service management:"
echo "  sudo systemctl status openclaw   # Check status"
echo "  sudo systemctl restart openclaw  # Restart"
echo "  sudo systemctl stop openclaw     # Stop"
echo "  sudo journalctl -u openclaw -f   # View logs"
echo ""
info "To update later, re-run this script or:"
echo "  cd $INSTALL_DIR && git pull && pnpm install && pnpm build && sudo systemctl restart openclaw"
echo ""
