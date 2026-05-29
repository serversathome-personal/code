#!/usr/bin/env bash
# ============================================================================
#  Claude Code Provisioner — TrueNAS 26 LXC Container (run INSIDE the LXC)
#  Target image: Debian 13 (Trixie)
#
#  This is the in-container half of the Proxmox deployer. You create the
#  container manually in the TrueNAS UI (Containers), then run this inside it
#  as root to reach the same end state.
#
#  Container is assumed to be PRIVILEGED already (ID Map Type: Privileged,
#  Capabilities Policy: ALLOW) — that's the only host-side requirement for
#  nested Docker, so there's nothing else to set on the TrueNAS side.
#    - Image: Debian 13 (Trixie)
#
#  Run it (from the container Shell, as root):
#    curl -fsSL https://raw.githubusercontent.com/serversathome-personal/code/main/provision-claude-code.sh -o /tmp/p.sh && bash /tmp/p.sh
#  ...or scp/paste it in and `bash provision-claude-code.sh`.
# ============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── Colors & Helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}>>> ${NC}$*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Resilient apt installer: try the batch, then fall back to one-by-one so a
# single missing/renamed package on Trixie can't abort the whole run.
apt_install() {
  if ! apt-get install -y -qq "$@" >/dev/null 2>&1; then
    warn "Batch install failed; retrying individually..."
    local p
    for p in "$@"; do
      apt-get install -y -qq "$p" >/dev/null 2>&1 || warn "  skipped (unavailable): $p"
    done
  fi
}

# ── Pre-flight ──────────────────────────────────────────────────────────────
[[ $(id -u) -eq 0 ]] || error "Run this as root inside the container."

# Normalize HOME: if elevated via `sudo` without -i/-H, $HOME may still point at
# the invoking user, which sends rustup / Claude Code / git config to the wrong
# home. Everything here assumes root's home, so force it.
ROOT_HOME="$(getent passwd 0 | cut -d: -f6)"; ROOT_HOME="${ROOT_HOME:-/root}"
if [[ "${HOME:-}" != "$ROOT_HOME" ]]; then
  warn "HOME was '${HOME:-unset}'; resetting to '$ROOT_HOME' (sudo without -i/-H?)."
  export HOME="$ROOT_HOME"
fi
cd "$HOME" 2>/dev/null || true

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  if [[ "${ID:-}" == "debian" && ( "${VERSION_ID:-}" == "13" || "${VERSION_CODENAME:-}" == "trixie" ) ]]; then
    success "Detected ${PRETTY_NAME:-Debian 13 (trixie)}"
  else
    warn "Expected Debian 13 (Trixie); found '${PRETTY_NAME:-unknown}'. Continuing anyway."
  fi
fi

echo -e "${BOLD}Provisioning Claude Code container...${NC} (a few minutes)"

# ── Timezone ────────────────────────────────────────────────────────────────
info "Setting timezone to America/New_York..."
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
echo "America/New_York" > /etc/timezone

info "Installing locales + base apt setup..."
apt-get update -qq
apt_install locales tzdata
dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true
sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
locale-gen en_US.UTF-8 > /dev/null 2>&1
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

info "Updating system..."
apt-get upgrade -y -qq

info "Installing core packages..."
# Trixie notes: dnsutils -> bind9-dnsutils (dnsutils dropped/transitional).
apt_install \
  git curl wget unzip zip \
  ca-certificates gnupg lsb-release apt-transport-https \
  bash-completion locales \
  htop nano vim tmux screen \
  jq yq tree \
  net-tools iproute2 iputils-ping bind9-dnsutils \
  openssh-server \
  cron logrotate

info "Installing build tools & dev libraries..."
# Trixie notes: libxslt-dev -> libxslt1-dev.
apt_install \
  build-essential make cmake pkg-config autoconf automake libtool \
  python3 python3-pip python3-venv python3-dev \
  libssl-dev libffi-dev libsqlite3-dev zlib1g-dev \
  libreadline-dev libbz2-dev libncurses-dev liblzma-dev libxml2-dev libxslt1-dev

info "Installing search & productivity tools..."
apt_install ripgrep fd-find fzf bat rsync sqlite3

info "Installing database clients..."
apt_install postgresql-client redis-tools

# ── Node.js 22 (NodeSource, with Debian-repo fallback) ───────────────────────
info "Installing Node.js 22.x LTS..."
if curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1 \
   && apt-get install -y -qq nodejs >/dev/null 2>&1; then
  success "Node.js via NodeSource"
else
  warn "NodeSource unavailable for this release; falling back to Debian repo Node.js (likely v20, not v22)."
  apt_install nodejs npm
fi
if command -v node >/dev/null 2>&1; then
  echo "    Node.js $(node --version) / npm $(npm --version 2>/dev/null || echo 'n/a')"
else
  warn "Node.js not present — npm-dependent steps (global tools, plugins, Playwright) will be skipped."
fi

if command -v npm >/dev/null 2>&1; then
  info "Installing global npm packages..."
  npm install -g typescript ts-node eslint prettier || warn "Some global npm packages failed."
fi

# ── Go ───────────────────────────────────────────────────────────────────────
info "Installing Go..."
GO_VERSION=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
rm /tmp/go.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile.d/go.sh
echo "    Go $(/usr/local/go/bin/go version | awk '{print $3}')"

# ── Rust ───────────────────────────────────────────────────────────────────────
info "Installing Rust..."
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
echo "    Rust $(rustc --version | awk '{print $2}')"

# ── Docker (nested in a privileged LXC) ──────────────────────────────────────
# containerd expects /dev/kmsg; some LXC containers don't expose it. Guard it
# (almost always a no-op in a privileged container). Harmless if it exists.
if [[ ! -e /dev/kmsg ]]; then
  info "Creating /dev/kmsg shim for nested Docker..."
  ln -sf /dev/console /dev/kmsg || true
  echo 'L+ /dev/kmsg - - - - /dev/console' > /etc/tmpfiles.d/kmsg.conf
fi

info "Installing Docker..."
curl -fsSL https://get.docker.com | sh
systemctl enable docker >/dev/null 2>&1 || true
systemctl restart docker || warn "dockerd didn't start cleanly; check 'journalctl -u docker'."
echo "    Docker $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo 'install check failed')"

info "Installing Docker Compose plugin..."
apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 || true
echo "    Compose $(docker compose version --short 2>/dev/null || echo 'included with Docker')"

# Quick storage-driver sanity note (privilege doesn't fix vfs-on-ZFS fallback).
if command -v docker >/dev/null 2>&1; then
  SD=$(docker info --format '{{.Driver}}' 2>/dev/null || echo unknown)
  [[ "$SD" == "vfs" ]] && warn "Docker is on the 'vfs' storage driver (slow, no layer sharing). If on ZFS, consider fuse-overlayfs."
fi

# ── Claude Code ───────────────────────────────────────────────────────────────
info "Installing Claude Code (native installer)..."
curl -fsSL https://claude.ai/install.sh | bash
if [[ -f "$HOME/.local/bin/claude" ]]; then
  ln -sf "$HOME/.local/bin/claude" /usr/local/bin/claude 2>/dev/null || true
elif [[ -f "$HOME/.claude/bin/claude" ]]; then
  ln -sf "$HOME/.claude/bin/claude" /usr/local/bin/claude 2>/dev/null || true
fi
echo "    Claude Code installed"

info "Configuring Claude Code permissions (full auto-approve)..."
mkdir -p /root/.claude
cat > /root/.claude/settings.json << 'SETTINGS'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "permissions": {
    "allow": [
      "Bash(*)",
      "Read(*)",
      "Write(*)",
      "Edit(*)",
      "MultiEdit(*)",
      "WebFetch(*)",
      "WebSearch(*)",
      "TodoRead(*)",
      "TodoWrite(*)",
      "Grep(*)",
      "Glob(*)",
      "LS(*)",
      "Task(*)",
      "mcp__*"
    ]
  },
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "64000",
    "MAX_THINKING_TOKENS": "31999"
  },
  "alwaysThinkingEnabled": true,
  "enableRemoteControl": true,
  "enabledPlugins": {
    "frontend-design@claude-code-plugins": true,
    "code-review@claude-code-plugins": true,
    "commit-commands@claude-code-plugins": true,
    "security-guidance@claude-code-plugins": true,
    "context7@claude-plugin-directory": true,
    "webapp-testing@anthropic-agent-skills": true,
    "superpowers@superpowers-marketplace": true
  }
}
SETTINGS

info "Setting up /project directory..."
mkdir -p /project
cat > /project/CLAUDE.md << 'CLAUDEMD'
# Claude Code Workspace

## Environment
- **OS**: Debian 13 (Trixie) LXC container on TrueNAS 26 (libvirt-managed)
- **Working directory**: /project
- **Timezone**: America/New_York
- **User**: root
- **Container**: Privileged ID map + Capabilities ALLOW (required for nested Docker)

## Available Tools
- **Languages**: Node.js 22 LTS, Python 3.13, Go (latest), Rust (latest)
- **Package managers**: npm, pip (use --break-system-packages), cargo, go install
- **Docker**: Docker Engine + Compose plugin, running and ready
- **Containers**: Watchtower (auto-updates), Code Server (port 8443)
- **Search tools**: ripgrep (rg), fd-find (fdfind), fzf
- **Databases**: PostgreSQL client (psql), Redis client (redis-cli), SQLite3

## Permissions
All tools are pre-approved — no permission prompts. Bash, Read, Write, Edit, WebFetch, WebSearch, Task, and MCP tools all run without confirmation.

## Agent Teams
Agent teams are enabled. You can spawn parallel teammates for complex tasks:
- Use agent teams for work that benefits from parallel exploration
- Use subagents (Task tool) for quick focused work that reports back
- tmux is installed for split-pane team visualization

## Remote Control
Remote control is enabled for all sessions. Every interactive session is automatically controllable
from claude.ai/code or the Claude mobile app. Use /remote-control or press spacebar to show QR code.

## Docker Usage
Docker compose files should go in /docker/<service-name>/docker-compose.yml.
Watchtower is already running and will auto-update any containers with `restart: unless-stopped`.
On TrueNAS LXC, give nested Docker containers `security_opt: [apparmor=unconfined]` if they hit AppArmor errors.

## Conventions
- Prefer creating files over printing long code blocks
- Use git for version control on all projects in /project/src/
- Debian 13 enforces PEP 668 — install Python packages with: pip install --break-system-packages <package>
- Extended thinking is always on — use it for complex architectural decisions

## Installed Plugins
- **frontend-design**: Production-grade UI with distinctive aesthetics (auto-activates on frontend tasks)
- **code-review**: Multi-agent PR review with confidence scoring
- **commit-commands**: Git commit, push, and PR workflows (/commit, /push, /pr)
- **security-guidance**: Security warnings when editing sensitive files
- **context7**: Live, version-specific library docs lookup (reduces API hallucinations)
- **webapp-testing**: Playwright-based browser testing for UI verification and debugging
- **superpowers**: Development workflow framework — brainstorm → plan → implement with TDD
  - /superpowers:brainstorm — Refine ideas before coding
  - /superpowers:write-plan — Create implementation plans
  - /superpowers:execute-plan — Execute plans in batches via subagents
  - Auto-activating skills: test-driven-development, systematic-debugging, verification-before-completion
CLAUDEMD

# ── Plugins (non-fatal: marketplace/CLI path may differ across versions) ──────
if command -v npx >/dev/null 2>&1; then
  info "Installing Claude Code plugins (best-effort)..."
  install_plugin() {
    npx -y claude-plugins install "$1" >/dev/null 2>&1 \
      || warn "Could not auto-install '$1'. Add it later from inside Claude Code with /plugin."
  }
  install_plugin @anthropics/claude-code-plugins/frontend-design
  install_plugin @anthropics/claude-code-plugins/code-review
  install_plugin @anthropics/claude-code-plugins/commit-commands
  install_plugin @anthropics/claude-code-plugins/security-guidance
  install_plugin @anthropics/claude-plugins-official/context7
  install_plugin @obra/superpowers-marketplace/superpowers
else
  warn "npx not available; skipping plugin auto-install. Use /plugin inside Claude Code."
fi

info "Installing webapp-testing skill (from anthropics/skills)..."
if git clone --depth 1 --filter=blob:none --sparse https://github.com/anthropics/skills.git /tmp/anthropic-skills >/dev/null 2>&1; then
  ( cd /tmp/anthropic-skills && git sparse-checkout set skills/webapp-testing >/dev/null 2>&1 )
  mkdir -p /root/.claude/skills/
  cp -r /tmp/anthropic-skills/skills/webapp-testing /root/.claude/skills/webapp-testing
  rm -rf /tmp/anthropic-skills
else
  warn "webapp-testing skill clone failed; skipping."
fi

if command -v npx >/dev/null 2>&1; then
  info "Installing Playwright for webapp-testing skill..."
  npx -y playwright install --with-deps chromium || warn "Playwright install failed (Trixie dep names can differ); rerun later if needed."
fi

# ── SSH ───────────────────────────────────────────────────────────────────────
info "Configuring SSH..."
sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
systemctl enable ssh >/dev/null 2>&1 || true
# Debian 13 ships sshd with systemd socket activation; restart whichever applies.
systemctl restart ssh >/dev/null 2>&1 || systemctl restart ssh.socket >/dev/null 2>&1 || true

# ── Shell environment ───────────────────────────────────────────────────────
info "Setting up shell environment..."
if ! grep -q "Claude Code Container" /root/.bashrc 2>/dev/null; then
cat >> /root/.bashrc << 'BASHRC'

# ── Claude Code Container ──────────────────────────────────
export EDITOR=nano
export LANG=en_US.UTF-8
export TZ=America/New_York
export PATH="$HOME/.local/bin:$HOME/.claude/bin:$HOME/.cargo/bin:/usr/local/go/bin:$PATH"

# Aliases
alias ll="ls -lah --color=auto"
alias cls="clear"
alias ..="cd .."
alias ...="cd ../.."
alias gs="git status"
alias gl="git log --oneline -20"
alias dc="docker compose"
alias dps="docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"

# Always start in /project
cd /project 2>/dev/null || true
BASHRC
fi

info "Setting up Git defaults..."
git config --global init.defaultBranch main
git config --global core.editor nano
git config --global pull.rebase false

# ── Docker services ───────────────────────────────────────────────────────────
info "Setting up Docker services..."
mkdir -p /docker/watchtower
cat > /docker/watchtower/docker-compose.yml << 'DCOMPOSE'
services:
  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    restart: unless-stopped
    environment:
      TZ: America/New_York
      WATCHTOWER_CLEANUP: "true"
      WATCHTOWER_INCLUDE_STOPPED: "true"
      WATCHTOWER_SCHEDULE: "0 0 4 * * *"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    security_opt:
      - apparmor=unconfined
DCOMPOSE

mkdir -p /docker/code-server
cat > /docker/code-server/docker-compose.yml << 'DCOMPOSE2'
services:
  code-server:
    image: lscr.io/linuxserver/code-server:latest
    container_name: code-server
    restart: unless-stopped
    environment:
      PUID: "0"
      PGID: "0"
      TZ: America/New_York
      PASSWORD: admin
    volumes:
      - ./config:/config
      - /:/config/workspace
    ports:
      - 8443:8443
    security_opt:
      - apparmor=unconfined
DCOMPOSE2

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  ( cd /docker/watchtower && docker compose up -d ) || warn "watchtower failed to start."
  ( cd /docker/code-server && docker compose up -d ) || warn "code-server failed to start."
else
  warn "Docker/Compose not ready; skipping service startup. Bring them up later with 'docker compose up -d'."
fi
cd /root

# ── Auto-update cron ──────────────────────────────────────────────────────────
info "Setting up auto-update cron..."
cat > /etc/cron.d/system-update << 'CRON'
# Weekly system update - Sunday 3:00 AM ET
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 * * 0 root apt-get update -qq && apt-get upgrade -y -qq && apt-get autoremove -y -qq && apt-get clean -qq >> /var/log/auto-update.log 2>&1
CRON
chmod 0644 /etc/cron.d/system-update

cat > /etc/logrotate.d/auto-update << 'LOGROTATE'
/var/log/auto-update.log {
    monthly
    rotate 3
    compress
    missingok
    notifempty
}
LOGROTATE

info "Cleaning up..."
apt-get autoremove -y -qq
apt-get clean -qq
rm -rf /var/lib/apt/lists/*

# ── Summary ───────────────────────────────────────────────────────────────────
CT_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║       Claude Code Container Ready!              ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Base:${NC}      Debian 13 (Trixie)"
echo -e "  ${BOLD}IP:${NC}        ${CT_IP:-check 'hostname -I'}"
echo -e "  ${BOLD}Timezone:${NC}  America/New_York"
echo ""
echo -e "  ${BOLD}Connect:${NC}"
[[ -n "${CT_IP:-}" ]] && echo -e "    SSH:   ${CYAN}ssh root@${CT_IP}${NC}"
[[ -n "${CT_IP:-}" ]] && echo -e "    Code:  ${CYAN}http://${CT_IP}:8443${NC}  (password: admin)"
echo ""
echo -e "  ${BOLD}Start Claude Code:${NC}  ${CYAN}claude${NC}  (new shells auto-cd to /project)"
echo ""
echo -e "  ${BOLD}Installed:${NC}  Claude Code, Node 22, Python3, Go, Rust, Docker+Compose,"
echo -e "               Watchtower, Code Server, git/ripgrep/fzf/fd, psql/redis-cli"
echo -e "  ${BOLD}Config:${NC}     ~/.claude/settings.json   ${BOLD}Workspace:${NC} /project"
echo -e "  ${BOLD}Features:${NC}   Agent teams, extended thinking, 64k output, remote control"
echo ""
warn "Open a fresh shell (or 'source ~/.bashrc') so PATH + aliases take effect."
warn "Sanity check: 'docker info | grep -i \"storage driver\"' should say overlay2 (not vfs)."
