#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Migrate OpenClaw from root to a dedicated 'openclaw' user
# Usage:  sudo bash migrate-to-user.sh
# ─────────────────────────────────────────────────────────────
set -euo pipefail

TARGET_USER="${1:-openclaw}"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { printf "${CYAN}▸${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}✔${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}⚠${NC} %s\n" "$*"; }
fail()  { printf "${RED}✖ %s${NC}\n" "$*" >&2; exit 1; }

if [[ "$(id -u)" -ne 0 ]]; then
  fail "This script must be run as root: sudo bash migrate-to-user.sh"
fi

echo ""
printf "${GREEN}════════════════════════════════════════════════════${NC}\n"
printf "${GREEN}  Migrating OpenClaw to user: $TARGET_USER${NC}\n"
printf "${GREEN}════════════════════════════════════════════════════${NC}\n"
echo ""

# Step 1: Create user if doesn't exist
if id "$TARGET_USER" &>/dev/null; then
  ok "User '$TARGET_USER' already exists"
else
  info "Creating user '$TARGET_USER'..."
  useradd -m -s /bin/bash "$TARGET_USER"
  ok "User '$TARGET_USER' created"
fi

TARGET_HOME="$(eval echo "~$TARGET_USER")"

# Step 2: Stop existing service
if systemctl is-active openclaw &>/dev/null; then
  info "Stopping openclaw service..."
  systemctl stop openclaw
  ok "Service stopped"
fi

# Step 3: Move source code
SRC_DIR="/root/.openclaw-src"
DEST_SRC="$TARGET_HOME/.openclaw-src"
if [ -d "$SRC_DIR" ] && [ "$SRC_DIR" != "$DEST_SRC" ]; then
  info "Moving source: $SRC_DIR → $DEST_SRC"
  if [ -d "$DEST_SRC" ]; then
    rm -rf "$DEST_SRC"
  fi
  mv "$SRC_DIR" "$DEST_SRC"
  ok "Source moved"
else
  warn "Source dir $SRC_DIR not found or already at destination"
fi

# Step 4: Move state directory
STATE_DIR="/root/.openclaw"
DEST_STATE="$TARGET_HOME/.openclaw"
if [ -d "$STATE_DIR" ] && [ "$STATE_DIR" != "$DEST_STATE" ]; then
  info "Moving state: $STATE_DIR → $DEST_STATE"
  if [ -d "$DEST_STATE" ]; then
    # Merge — don't overwrite existing config
    cp -rn "$STATE_DIR/"* "$DEST_STATE/" 2>/dev/null || true
    rm -rf "$STATE_DIR"
  else
    mv "$STATE_DIR" "$DEST_STATE"
  fi
  ok "State moved"
else
  warn "State dir $STATE_DIR not found or already at destination"
fi

# Step 5: Create bin directory and wrapper
DEST_BIN="$TARGET_HOME/.local/bin"
mkdir -p "$DEST_BIN"
NODE_PATH="$(command -v node)"

cat > "$DEST_BIN/openclaw" << WRAPPER
#!/usr/bin/env bash
exec $NODE_PATH $DEST_SRC/openclaw.mjs "\$@"
WRAPPER
chmod +x "$DEST_BIN/openclaw"
ok "Binary wrapper created at $DEST_BIN/openclaw"

# Step 6: Set up .bashrc for the new user
DEST_BASHRC="$TARGET_HOME/.bashrc"
touch "$DEST_BASHRC"
if ! grep -q "openclaw" "$DEST_BASHRC" 2>/dev/null; then
  cat >> "$DEST_BASHRC" << 'BASHRC_BLOCK'

# OpenClaw environment
export PATH="$HOME/.local/bin:$HOME/.local/share/pnpm:$PATH"
export PNPM_HOME="$HOME/.local/share/pnpm"
BASHRC_BLOCK
  ok ".bashrc configured for $TARGET_USER"
fi

# Step 7: Copy pnpm global store if exists
if [ -d "/root/.local/share/pnpm" ]; then
  mkdir -p "$TARGET_HOME/.local/share"
  cp -r "/root/.local/share/pnpm" "$TARGET_HOME/.local/share/pnpm" 2>/dev/null || true
  ok "pnpm store copied"
fi

# Step 8: Fix all ownership
info "Setting ownership to $TARGET_USER..."
chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME"
chmod 700 "$DEST_STATE" 2>/dev/null || true
ok "Ownership fixed"

# Step 9: Update systemd service
info "Updating systemd service..."

# Build environment block
ENV_LINES="Environment=\"HOME=$TARGET_HOME\"\n"
ENV_LINES+="Environment=\"NODE_ENV=production\"\n"
ENV_LINES+="Environment=\"PATH=$DEST_BIN:$TARGET_HOME/.local/share/pnpm:/usr/local/bin:/usr/bin:/bin\"\n"
ENV_LINES+="Environment=\"PNPM_HOME=$TARGET_HOME/.local/share/pnpm\"\n"

# Copy API keys from root's openclaw config env if present
for key in OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY GOOGLE_API_KEY; do
  if [ -n "${!key:-}" ]; then
    ENV_LINES+="Environment=\"$key=${!key}\"\n"
  fi
done

cat > /etc/systemd/system/openclaw.service << SYSTEMD_EOF
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$TARGET_USER
Group=$TARGET_USER
WorkingDirectory=$DEST_SRC
ExecStart=$NODE_PATH $DEST_SRC/openclaw.mjs gateway run
Restart=always
RestartSec=5
$(printf '%b' "$ENV_LINES")
# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=openclaw

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=$TARGET_HOME
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

systemctl daemon-reload
systemctl enable openclaw.service
systemctl start openclaw.service
ok "Systemd service updated for user '$TARGET_USER' and started"

# Step 10: Clean up root's old bin wrapper
if [ -f "/root/.local/bin/openclaw" ]; then
  rm -f "/root/.local/bin/openclaw"
  ok "Removed old root binary wrapper"
fi

# Done
echo ""
printf "${GREEN}════════════════════════════════════════════════════${NC}\n"
printf "${GREEN}  Migration complete!${NC}\n"
printf "${GREEN}════════════════════════════════════════════════════${NC}\n"
echo ""
info "OpenClaw is now running as user: $TARGET_USER"
info "Source:  $DEST_SRC"
info "State:   $DEST_STATE"
info "Binary:  $DEST_BIN/openclaw"
echo ""
info "To manage the service:"
echo "  sudo systemctl status openclaw   # Check status"
echo "  sudo systemctl restart openclaw  # Restart"
echo "  sudo journalctl -u openclaw -f   # View logs"
echo ""
info "To run openclaw commands as $TARGET_USER:"
echo "  sudo -u $TARGET_USER $DEST_BIN/openclaw doctor"
echo "  sudo -u $TARGET_USER $DEST_BIN/openclaw onboard"
echo "  sudo su - $TARGET_USER           # Switch to user shell"
echo ""
