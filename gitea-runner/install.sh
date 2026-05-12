#!/bin/bash
# install.sh - Gitea Act Runner: LXC creation, installation & update
# Usage:
#   From Proxmox host : curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/gitea-runner/install.sh | bash
#   From inside LXC   : bash /root/install.sh   (updates act_runner binary)

set -euo pipefail

# --- Config (override via environment) ---
CTID="${CTID:-}"
HOSTNAME="${RUNNER_HOSTNAME:-gitea-runner}"
TEMPLATE="${TEMPLATE:-alpine-3.23-default_20260116_amd64.tar.xz}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
CORES="${CORES:-2}"
RAM="${RAM:-2048}"
DISK="${DISK:-8}"
BRIDGE="${BRIDGE:-vmbr0}"
SCRIPT_URL="https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/gitea-runner/install.sh"
GITEA_API="https://gitea.com/api/v1/repos/gitea/act_runner/releases"
VERSION_FILE="/opt/gitea-runner_version.txt"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Helpers ---
get_latest_release() {
  local release
  release=$(curl -fsSL "$GITEA_API" | jq -r '.[0].tag_name')
  if [[ -z "$release" || "$release" == "null" ]]; then
    log_error "Failed to fetch latest release from Gitea API"
    exit 1
  fi
  echo "$release"
}

get_arch() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64)  echo "amd64" ;;
    aarch64) echo "arm64" ;;
    armv7l)  echo "armv7" ;;
    *)       log_error "Unsupported architecture: $arch"; exit 1 ;;
  esac
}

download_runner() {
  local release="$1"
  local version="${release#v}"
  local arch
  arch=$(get_arch)
  local url="https://gitea.com/gitea/act_runner/releases/download/${release}/act_runner-${version}-linux-${arch}"

  log_info "Downloading act_runner ${release} (${arch})..."
  curl -fsSL "$url" -o /usr/local/bin/act_runner
  chmod +x /usr/local/bin/act_runner
  ln -sf /usr/local/bin/act_runner /usr/bin/act_runner
  echo "$release" > "$VERSION_FILE"
}

# ============================================================
# MODE 1: Proxmox host — create LXC container
# ============================================================
create_lxc() {
  log_info "=== Gitea Act Runner — LXC Creation ==="

  # Auto-select next CTID if not specified
  if [[ -z "$CTID" ]]; then
    CTID=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
      | jq '[.[].vmid] | max + 1' 2>/dev/null || echo "100")
    log_info "Auto-selected CTID: $CTID"
  fi

  # Download template if needed
  if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
    log_info "Downloading template $TEMPLATE..."
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
  fi

  log_info "Creating LXC $CTID ($HOSTNAME)..."
  pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME" \
    --cores "$CORES" \
    --memory "$RAM" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged 1 \
    --features nesting=1,keyctl=1 \
    --tags "infra-script,cicd" \
    --start 0

  log_info "Configuring LXC for Docker and Tailscale..."
  cat >> "/etc/pve/lxc/${CTID}.conf" <<EOF
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net dev/net none bind,create=dir
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF

  log_info "Starting LXC $CTID..."
  pct start "$CTID"
  sleep 5

  log_info "Injecting install script into container..."
  pct exec "$CTID" -- sh -c "apk add --no-cache bash curl jq > /dev/null 2>&1"
  curl -fsSL "$SCRIPT_URL" | pct exec "$CTID" -- bash -s -- --install

  local ip
  local ip\n  ip=$(pct exec \"$CTID\" -- ip -4 addr show eth0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)

  echo ""
  log_info "========================================="
  log_info "LXC $CTID created successfully!"
  log_info "========================================="
  echo ""
  echo "  Hostname : $HOSTNAME"
  echo "  IP       : ${ip:-pending}"
  echo ""
  echo "Next steps:"
  echo "  pct enter $CTID"
  echo "  cd /var/lib/gitea-runner"
  echo "  su -s /bin/bash gitea-runner -c 'act_runner register'"
  echo "  rc-service gitea-runner start"
  echo ""
}

# ============================================================
# MODE 2: Inside LXC — fresh install
# ============================================================
install_runner() {
  log_info "=== Gitea Act Runner — Installation ==="

  log_info "Updating system..."
  apk update > /dev/null && apk upgrade > /dev/null

  log_info "Installing dependencies..."
  apk add --no-cache curl jq tar bash docker docker-cli-compose > /dev/null

  log_info "Installing Tailscale..."
  apk add --no-cache tailscale > /dev/null
  rc-update add tailscale default > /dev/null 2>&1
  rc-service tailscale start > /dev/null 2>&1

  log_info "Starting Docker..."
  rc-update add docker default > /dev/null 2>&1
  rc-service docker start > /dev/null 2>&1

  local release
  release=$(get_latest_release)
  download_runner "$release"
  log_info "act_runner $(act_runner --version 2>&1 || true)"

  log_info "Creating gitea-runner user..."
  adduser -S -D -H -h /var/lib/gitea-runner -s /bin/bash -G docker gitea-runner 2>/dev/null || true
  addgroup gitea-runner docker 2>/dev/null || true
  mkdir -p /var/lib/gitea-runner
  chown -R gitea-runner:docker /var/lib/gitea-runner

  log_info "Generating act_runner config with Prometheus metrics enabled..."
  act_runner generate-config > /var/lib/gitea-runner/config.yaml
  sed -i '/^metrics:/,/enabled:/{s/enabled: false/enabled: true/}' /var/lib/gitea-runner/config.yaml
  chown gitea-runner:docker /var/lib/gitea-runner/config.yaml
  chmod 640 /var/lib/gitea-runner/config.yaml

  log_info "Creating OpenRC service..."
  cat <<'EOF' > /etc/init.d/gitea-runner
#!/sbin/openrc-run

name="Gitea Act Runner"
description="Gitea Actions Runner Daemon"
command="/usr/local/bin/act_runner"
command_args="daemon --config /var/lib/gitea-runner/config.yaml"
command_user="gitea-runner:docker"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
directory="/var/lib/gitea-runner"

output_log="/var/log/gitea-runner.log"
error_log="/var/log/gitea-runner.log"

depend() {
    need net docker tailscale
    after docker tailscale
}

start_pre() {
    export PATH="/usr/local/bin:$PATH"
    checkpath --directory --owner gitea-runner:docker --mode 0755 /var/lib/gitea-runner
    checkpath --file --owner gitea-runner:docker --mode 0644 /var/log/gitea-runner.log
}
EOF
  chmod +x /etc/init.d/gitea-runner
  rc-update add gitea-runner default > /dev/null

  log_info "Configuring logrotate for gitea-runner..."
  apk add --no-cache logrotate > /dev/null

  cat > /etc/logrotate.d/gitea-runner << 'LOGROTATE'
/var/log/gitea-runner.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
LOGROTATE

  ln -sf /usr/sbin/logrotate /etc/periodic/daily/logrotate 2>/dev/null || true

  log_info "Enabling console auto-login..."
  mkdir -p /etc/conf.d
  cat <<'EOF' > /etc/conf.d/agetty
agetty_options="--autologin root --noclear"
EOF
  sed -i 's|^tty1::respawn:/sbin/getty.*|tty1::respawn:/sbin/agetty --autologin root --noclear 38400 tty1|' /etc/inittab

  log_info "Cleaning up..."
  rm -rf /var/cache/apk/*

  echo ""
  log_info "========================================="
  log_info "Installation complete!"
  log_info "========================================="
  echo ""
  echo "Connect to Tailscale first:"
  echo "  tailscale up --ssh"
  echo ""
  echo "Register the runner:"
  echo "  cd /var/lib/gitea-runner"
  echo "  su -s /bin/bash gitea-runner -c 'act_runner register'"
  echo "  rc-service gitea-runner start"
  echo ""
}

# ============================================================
# MODE 3: Inside LXC — update binary
# ============================================================
update_runner() {
  log_info "=== Gitea Act Runner — Update ==="

  local release
  release=$(get_latest_release)

  if [[ -f "$VERSION_FILE" && "$release" == "$(cat "$VERSION_FILE")" ]]; then
    log_info "Already at latest version: $release"
    exit 0
  fi

  local current
  current=$(cat "$VERSION_FILE" 2>/dev/null || echo "unknown")
  log_info "Updating: $current → $release"

  log_info "Stopping service..."
  rc-service gitea-runner stop 2>/dev/null || true

  log_info "Backing up current binary..."
  cp /usr/local/bin/act_runner "/usr/local/bin/act_runner.bak.$(date +%s)"

  download_runner "$release"

  log_info "Starting service..."
  rc-service gitea-runner start

  log_info "Updated to $release"
}

# ============================================================
# Main — detect context
# ============================================================
main() {
  if [[ "${1:-}" == "--install" ]]; then
    # Explicitly called in install mode (from pct exec)
    install_runner
  elif command -v pct &> /dev/null; then
    # We're on the Proxmox host
    create_lxc
  elif [[ -f /usr/local/bin/act_runner ]]; then
    # act_runner exists — update mode
    update_runner
  else
    # Fresh LXC — install mode
    install_runner
  fi
}

main "$@"
