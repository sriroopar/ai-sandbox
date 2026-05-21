#!/usr/bin/env bash
# Requires bash (do not run with `sh`: brace expansion would not apply and other bash-isms break).
set -euo pipefail

SANDBOX=~/ai-sandbox
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Override when Cursor releases a new RPM: export CURSOR_RPM_URL='https://...'
CURSOR_RPM_URL="${CURSOR_RPM_URL:-https://api2.cursor.sh/updates/download/golden/linux-x64-rpm/cursor/2.6}"

mkdir -p "$SANDBOX/logs"

#################################
# virtiofs + symlinks (idempotent)
#################################

# Skip mounting if using HTTP delivery (Windows)
USE_HTTP=0
USE_SSHFS=0
USE_CIFS=0
if [[ -f /etc/ai-sandbox/windows-host.env ]]; then
  source /etc/ai-sandbox/windows-host.env
  [[ "${USE_HTTP:-0}" == "1" ]] && USE_HTTP=1
fi
[[ -f /etc/ai-sandbox/sshfs.env ]] && { source /etc/ai-sandbox/sshfs.env; [[ "${USE_SSHFS:-0}" == "1" ]] && USE_SSHFS=1; }
[[ -f /etc/ai-sandbox/cifs.env  ]] && { source /etc/ai-sandbox/cifs.env;  [[ "${USE_CIFS:-0}"  == "1" ]] && USE_CIFS=1;  }

if [[ "$USE_HTTP" == "0" ]] && ! mountpoint -q /mnt/host-config 2>/dev/null; then
  sudo "$SCRIPT_DIR/ensure-sandbox-mounts.sh" "${USER}"
fi

# Live passthrough (SSHFS/CIFS): install systemd unit so mounts survive reboot.
if [[ "$USE_SSHFS" == "1" || "$USE_CIFS" == "1" ]]; then
  unit_src="$SCRIPT_DIR/systemd"
  if [[ -d "$unit_src" ]]; then
    sudo install -d -m 0755 /etc/ai-sandbox
    echo "AI_SANDBOX_TARGET_USER=${USER}" | sudo tee /etc/ai-sandbox/target-user.env >/dev/null
    sudo install -m 0644 "$unit_src/ai-sandbox-mounts.service" /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable --now ai-sandbox-mounts.service
  fi
fi

#################################
# SSH keys on guest disk for Podman (rootless statfs on virtiofs often fails)
#################################
# Bind-mounting /mnt/host-secrets/ssh into the container hits: statfs ... permission denied
# (SELinux / virtiofs + rootless Podman). Copy once to ~/.ssh on the VM disk; container mounts that.

# For HTTP delivery (Windows), keys are already in ~/.ssh from kickstart
if [[ "$USE_HTTP" == "1" ]]; then
  if [[ -f "$HOME/.ssh/id_ed25519" ]]; then
    echo "SSH keys already in ~/.ssh (HTTP delivery)."
  else
    echo "WARNING: No SSH keys in ~/.ssh - HTTP sync may have failed." >&2
    echo "Keys are optional for basic operation but needed for git/GitHub." >&2
  fi
else
  # For virtiofs/CIFS mounts, copy from sandbox
  SANDBOX_KEY="$SANDBOX/secrets/ssh/id_ed25519"
  SANDBOX_PUB="$SANDBOX/secrets/ssh/id_ed25519.pub"
  if [[ -r "$SANDBOX_KEY" ]]; then
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    install -m 600 "$SANDBOX_KEY" "$HOME/.ssh/id_ed25519"
    if [[ -r "$SANDBOX_PUB" ]]; then
      install -m 644 "$SANDBOX_PUB" "$HOME/.ssh/id_ed25519.pub"
    fi
    echo "Copied sandbox SSH keys to ~/.ssh (for Podman bind-mount)."

    # SSH config: tell SSH to use the key for GitHub
    if [[ ! -f "$HOME/.ssh/config" ]] || ! grep -q 'Host github.com' "$HOME/.ssh/config" 2>/dev/null; then
      cat >> "$HOME/.ssh/config" <<'SSHCFG'
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
SSHCFG
      chmod 600 "$HOME/.ssh/config"
    fi

    # Add GitHub host keys to known_hosts (avoids interactive prompt)
    if [[ ! -f "$HOME/.ssh/known_hosts" ]] || ! grep -q 'github.com' "$HOME/.ssh/known_hosts" 2>/dev/null; then
      ssh-keyscan github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
    fi

    # Rewrite HTTPS GitHub URLs to SSH so git clone/push uses the key
    git config --global url."git@github.com:".insteadOf "https://github.com/"
  elif [[ -e "$SANDBOX_KEY" ]]; then
    echo "Sandbox SSH private key exists but is not readable: $SANDBOX_KEY" >&2
    echo "On the host: chown/chmod secrets/ssh so guest user ai (UID usually 1000) can read the key." >&2
    exit 1
  elif [[ -f "$SANDBOX_PUB" ]]; then
    echo "Found $SANDBOX_PUB but not the private key $SANDBOX_KEY." >&2
    echo "On the host run: ./host/install-virt-linux.sh or ./secrets/gen-ssh-key.sh — both keys must live under secrets/ssh/." >&2
    exit 1
  else
    echo "ERROR: No secrets/ssh/id_ed25519 on the virtiofs share — check mounts and host secrets/ssh/." >&2
    echo "On the host run: ./host/install-virt-linux.sh (or secrets/gen-ssh-key.sh), then re-run this script." >&2
    exit 1
  fi
fi

#################################
# install dev tools
#################################

# After Cursor RPM is installed once, /etc/yum.repos.d/cursor*.repo exists; the next dnf refresh
# can warn "repomd.xml GPG signature verification error" until rpm knows Anysphere's key.
if command -v curl >/dev/null 2>&1; then
  curl -fsSL https://downloads.cursor.com/keys/anysphere.asc | sudo rpm --import - 2>/dev/null || true
fi

echo "Cleaning dnf cache (avoids checksum / OpenPGP errors from partial or bad mirror downloads)..."
sudo dnf clean all

echo "Updating system..."
sudo dnf upgrade -y --refresh

echo "Installing core tools..."

sudo dnf install -y --refresh \
podman \
slirp4netns \
git \
curl \
nodejs \
npm \
python3 \
python3-pip \
golang \
tmux \
htop \
iftop \
tcpdump \
ripgrep \
fd-find \
firewalld \
audit \
bind-utils

# Note: terminator is now installed via kickstart (ks.template.cfg) for immediate availability

# Rootless Podman: slirp4netns is required for start-container.sh --network slirp4netns (not always a podman dep).
# Rootless Podman: linger keeps user session services available (typical Fedora default for subuids).
if command -v loginctl >/dev/null 2>&1; then
  loginctl enable-linger "$(id -un)" 2>/dev/null || true
fi

#################################
# node ecosystem
#################################

sudo npm install -g \
typescript \
ts-node \
pnpm \
yarn
# @anthropic-ai/claude-code is installed after setup-claude.sh (GCP project / Vertex first) or via fallback below.

#################################
# python ecosystem
#################################

pip install --user \
anthropic \
fastapi \
uvicorn \
httpx \
poetry

sudo systemctl enable --now firewalld
sudo systemctl enable --now auditd

#################################
# Firewall (clean + consistent; all rules on zone block)
#################################

sudo firewall-cmd --set-default-zone=block

sudo firewall-cmd --permanent --zone=block --add-service=dns
sudo firewall-cmd --permanent --zone=block --add-service=http
sudo firewall-cmd --permanent --zone=block --add-service=https
sudo firewall-cmd --permanent --zone=block --add-service=ssh

sudo firewall-cmd --reload
sudo firewall-cmd --set-log-denied=all

#################################
# Audit logging
#################################

# Idempotent: re-running the script hits "Rule exists" if execve is already audited.
if ! sudo auditctl -l 2>/dev/null | grep -qF 'arch=b64 -S execve'; then
  sudo auditctl -a always,exit -F arch=b64 -S execve
fi

#################################
# Build container (same as build-container.sh)
#################################

"$SCRIPT_DIR/build-container.sh"

#################################
# Install Cursor
#################################

curl -fL "$CURSOR_RPM_URL" -o /tmp/cursor.rpm
sudo dnf install -y /tmp/cursor.rpm
rm -f /tmp/cursor.rpm

#################################
# Setup Claude Code (permissions + legacy API file)
#################################

mkdir -p ~/.claude

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/claude-login-env.sh"
ai_sandbox_sync_claude_vertex_env_from_sandbox "$SANDBOX"
ai_sandbox_install_claude_login_hook "$HOME/.bashrc"

# Host-backed MCP (user scope) + personal skills — see config/claude-bootstrap/
"$SCRIPT_DIR/merge-claude-bootstrap.sh" "$SANDBOX"

# User settings: prefer non-empty host-only override, else repo default (bypassPermissions / "YOLO").
# Empty secrets/claude-settings.json must not win — it would leave ~/.claude/settings.json empty.
# See spec/how/runtime.md — use secrets/claude-settings.json on the host to persist edits across rebuilds.
CLAUDE_SETTINGS_TEMPLATE="$SANDBOX/config/claude-code.settings.json"
install_claude_settings_from() {
  install -m 600 "$1" ~/.claude/settings.json
}
if [[ -f "$SANDBOX/secrets/claude-settings.json" && -s "$SANDBOX/secrets/claude-settings.json" ]]; then
  install_claude_settings_from "$SANDBOX/secrets/claude-settings.json"
elif [[ -f "$CLAUDE_SETTINGS_TEMPLATE" ]]; then
  install_claude_settings_from "$CLAUDE_SETTINGS_TEMPLATE"
else
  cat > ~/.claude/settings.json <<'EOF'
{
  "permissions": {
    "defaultMode": "bypassPermissions"
  }
}
EOF
  chmod 600 ~/.claude/settings.json
fi
if [[ ! -s ~/.claude/settings.json ]]; then
  [[ -f "$CLAUDE_SETTINGS_TEMPLATE" ]] && install_claude_settings_from "$CLAUDE_SETTINGS_TEMPLATE"
fi

# Vertex (Red Hat) uses ADC + env vars; do not write apiKey when claude-vertex.env is present (any host-backed path).
VERTEX_ENV_PRESENT=0
if [ -r "$SANDBOX/secrets/claude-vertex.env" ] || [ -r "$SANDBOX/workspace/.ai-sandbox-private/claude-vertex.env" ]; then
  VERTEX_ENV_PRESENT=1
fi

CLAUDE_KEY_FILE=""
if [ -r "$SANDBOX/secrets/claude_api_key" ]; then
  CLAUDE_KEY_FILE="$SANDBOX/secrets/claude_api_key"
elif [ -r "$SANDBOX/workspace/.ai-sandbox-private/claude_api_key" ]; then
  CLAUDE_KEY_FILE="$SANDBOX/workspace/.ai-sandbox-private/claude_api_key"
fi

# Vertex (Red Hat) uses ADC + env vars; do not write apiKey when claude-vertex.env is present.
if [ -n "$CLAUDE_KEY_FILE" ] && [ "$VERTEX_ENV_PRESENT" -eq 0 ]; then
  KEY=$(cat "$CLAUDE_KEY_FILE")

  cat > ~/.claude/config.json <<EOF
{
  "apiKey": "$KEY",
  "defaultModel": "claude-3-opus",
  "projects": {
    "default": "/workspace"
  }
}
EOF
fi

echo "VM setup complete."

#################################
# Claude Code wizard: TTY = run now; no TTY (e.g. systemd first boot) = GNOME autostart terminal
#################################
install_claude_wizard_gnome_autostart() {
  local desk="$HOME/.config/autostart/ai-sandbox-claude-setup.desktop"
  local sb
  sb="$(cd "$SANDBOX" && pwd)"
  mkdir -p "$HOME/.config/autostart" "$HOME/.config/ai-sandbox"
  printf '%s\n' "$sb" >"$HOME/.config/ai-sandbox/sandbox-root"
  chmod 600 "$HOME/.config/ai-sandbox/sandbox-root"
  cat >"$desk" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=AI Sandbox Claude setup
Comment=One-time interactive Claude Code setup (Red Hat Vertex or API key)
Exec=/usr/bin/bash $sb/config/run-claude-setup-once.sh
Terminal=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=20
OnlyShowIn=GNOME;
EOF
  chmod 644 "$desk"
}

if [[ "${AI_SANDBOX_SKIP_CLAUDE_SETUP:-}" != "1" ]] && [[ -t 0 ]] && [[ -t 1 ]]; then
  echo ""
  echo "Starting Claude Code setup (Red Hat vs standard). Press Ctrl+C to skip; re-run later: bash ~/ai-sandbox/config/setup-claude.sh"
  AI_SANDBOX_SETUP_FROM_INSTALL=1 bash "$SCRIPT_DIR/setup-claude.sh" || true
elif [[ "${AI_SANDBOX_SKIP_CLAUDE_SETUP:-}" != "1" ]]; then
  echo ""
  install_claude_wizard_gnome_autostart
  echo "First-boot install has no interactive terminal. A **GNOME autostart** entry was added: after you log in,"
  echo "a terminal should open for **Claude setup** (~20s delay). If it does not (no DISPLAY / no gnome-terminal), run:"
  echo "  bash ~/ai-sandbox/config/setup-claude.sh"
  echo "To skip autostart, remove ~/.config/autostart/ai-sandbox-claude-setup.desktop or set AI_SANDBOX_SKIP_CLAUDE_SETUP=1 before re-running install."
fi

# Claude CLI: wizard installs it after GCP project / gcloud; ensure binary exists for non-interactive first-boot or skipped wizard.
if ! command -v claude >/dev/null 2>&1; then
  echo "Installing Claude Code CLI (npm global) — wizard was skipped or did not install it."
  sudo npm install -g @anthropic-ai/claude-code
fi
