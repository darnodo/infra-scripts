#!/bin/bash
# install.sh - OpenBao: LXC creation, installation & update
# Usage:
#   From Proxmox host : bash -c "$(curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/feat/lxc-OpenBao/openbao/install.sh)"
#   From inside LXC   : bash /root/install.sh           (updates bao binary)
#
# Single entrypoint, three automatic modes:
#   1. Proxmox host, no existing container  -> create LXC + install OpenBao
#   2. Proxmox host, container already present -> update packages + upgrade bao
#   3. Inside an LXC                         -> install bao if missing, otherwise update
#
# The OpenBao binary install/upgrade logic lives in a single reusable function
# (install_or_upgrade_bao) shared by both the create and update paths.

set -euo pipefail

# --- Config (override via environment) ---
CTID="${CTID:-}"
HOSTNAME_LXC="${OPENBAO_HOSTNAME:-openbao}"
TEMPLATE="${TEMPLATE:-}"                          # auto-detected when empty
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
CORES="${CORES:-2}"
RAM="${RAM:-1024}"
DISK="${DISK:-8}"
BRIDGE="${BRIDGE:-vmbr0}"
LXC_TAG="${LXC_TAG:-openbao}"                     # stable identifier for the container
OPENBAO_VERSION="${OPENBAO_VERSION:-latest}"      # "latest" or e.g. "v2.0.3"
# GitHub releases endpoint for the openbao/openbao repo (used to resolve "latest").
OPENBAO_RELEASES_URL="${OPENBAO_RELEASES_URL:-https://api.github.com/repos/openbao/openbao/releases}"
OPENBAO_LISTEN_ADDR="${OPENBAO_LISTEN_ADDR:-127.0.0.1:8200}"
# Public API address advertised to clients (also used for OIDC / UI redirects).
# Defaults to the local listener; override with the tailnet URL once known,
# e.g. OPENBAO_API_ADDR="https://openbao.<tailnet>.ts.net".
OPENBAO_API_ADDR="${OPENBAO_API_ADDR:-http://${OPENBAO_LISTEN_ADDR}}"
# Optional: pre-authorise the LXC's Tailscale non-interactively.
# Generate at https://login.tailscale.com/admin/settings/keys
TS_AUTHKEY="${TS_AUTHKEY:-}"
# SCRIPT_URL is what the host-side flow pipes into the LXC. Override it when
# testing from a non-main branch, e.g.
#   SCRIPT_URL="https://gitea.arnodo.fr/.../branch/feat/lxc-OpenBao/openbao/install.sh"
SCRIPT_URL="${SCRIPT_URL:-https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/openbao/install.sh}"
VERSION_FILE="${VERSION_FILE:-/opt/openbao_version.txt}"
BAO_USER="openbao"
BAO_CONFIG_DIR="/etc/openbao"
BAO_DATA_DIR="/var/lib/openbao"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Logs go to stderr so callers can safely use $(fn) without capturing log noise.
log_info()  { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# ============================================================
# Generic helpers
# ============================================================
require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    log_error "This script must be run as root (current uid: $(id -u))."
    log_error "On Proxmox, launch it from the host shell or via the Web UI shell, both of which run as root."
    exit 1
  fi
}

# OpenBao publishes release assets named with the raw `uname -m` arch
# (e.g. x86_64, aarch64), not Go-style amd64/arm64.
get_arch() {
  case "$(uname -m)" in
    x86_64)  echo "x86_64" ;;
    aarch64) echo "aarch64" ;;
    *)       log_error "Unsupported architecture: $(uname -m)"; exit 1 ;;
  esac
}

# Resolve "latest" -> concrete tag name, otherwise echo input unchanged.
resolve_openbao_version() {
  local requested="$1"
  if [[ "$requested" != "latest" ]]; then
    echo "$requested"
    return 0
  fi
  local tag
  tag=$(curl -fsSL "${OPENBAO_RELEASES_URL}/latest" | jq -r '.tag_name')
  if [[ -z "$tag" || "$tag" == "null" ]]; then
    log_error "Failed to resolve latest OpenBao release from GitHub API."
    exit 1
  fi
  echo "$tag"
}

# ============================================================
# Reusable: install or upgrade the bao binary in-place.
# Used by both fresh-install and update flows.
# Returns 0 on success, exits on hard error.
# ============================================================
install_or_upgrade_bao() {
  local tag arch version url tmpdir current
  tag=$(resolve_openbao_version "$OPENBAO_VERSION")
  arch=$(get_arch)
  version="${tag#v}"

  current=""
  if [[ -f "$VERSION_FILE" ]]; then
    current=$(cat "$VERSION_FILE")
  fi

  if [[ "$current" == "$tag" && -x /usr/local/bin/bao ]]; then
    log_info "OpenBao already at $tag, nothing to do."
    return 0
  fi

  # Asset naming convention: bao_<version>_Linux_<arch>.tar.gz
  url="https://github.com/openbao/openbao/releases/download/${tag}/bao_${version}_Linux_${arch}.tar.gz"
  log_info "Downloading OpenBao ${tag} (${arch}) from ${url}..."

  tmpdir=$(mktemp -d)
  curl -fsSL "$url" -o "${tmpdir}/bao.tar.gz"
  tar -xzf "${tmpdir}/bao.tar.gz" -C "$tmpdir"

  if [[ ! -f "${tmpdir}/bao" ]]; then
    log_error "Archive did not contain expected 'bao' binary."
    rm -rf "$tmpdir"
    exit 1
  fi

  # Stop service if running, swap binary atomically, then restart.
  local service_was_running=0
  if command -v rc-service >/dev/null 2>&1 && rc-service openbao status >/dev/null 2>&1; then
    service_was_running=1
    log_info "Stopping openbao service for upgrade..."
    rc-service openbao stop || true
  fi

  if [[ -x /usr/local/bin/bao ]]; then
    cp /usr/local/bin/bao "/usr/local/bin/bao.bak.$(date +%s)"
  fi
  install -m 0755 "${tmpdir}/bao" /usr/local/bin/bao
  ln -sf /usr/local/bin/bao /usr/bin/bao
  echo "$tag" > "$VERSION_FILE"

  log_info "Installed: $(/usr/local/bin/bao --version 2>&1 | head -n1 || true)"

  if [[ "$service_was_running" -eq 1 ]]; then
    log_info "Restarting openbao service..."
    rc-service openbao start
  fi

  rm -rf "$tmpdir"
}

# ============================================================
# Reusable: bring Tailscale up and publish OpenBao on the tailnet.
# Idempotent: re-running is a no-op once Tailscale is logged in and the
# serve mapping is already in place.
# ============================================================
configure_tailscale_proxy() {
  if ! command -v tailscale >/dev/null 2>&1; then
    log_warn "tailscale CLI not found, skipping reverse-proxy setup."
    return 0
  fi

  # 1. Authenticate the node (if it isn't already).
  local backend_state
  backend_state=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "unknown"')
  if [[ "$backend_state" != "Running" ]]; then
    if [[ -n "$TS_AUTHKEY" ]]; then
      log_info "Bringing Tailscale up with provided auth key..."
      tailscale up --authkey "$TS_AUTHKEY" --ssh --hostname "$HOSTNAME_LXC" \
        || log_warn "tailscale up failed — run it manually inside the LXC."
    else
      log_warn "Tailscale not authenticated and TS_AUTHKEY was not supplied."
      log_warn "Finish setup inside the LXC with: tailscale up --ssh"
      log_warn "Then publish OpenBao with:        tailscale serve --bg --https=443 http://${OPENBAO_LISTEN_ADDR}"
      return 0
    fi
  fi

  # 2. Publish the local OpenBao listener on the tailnet (auto-HTTPS).
  if tailscale serve status 2>/dev/null | grep -q "${OPENBAO_LISTEN_ADDR}"; then
    log_info "Tailscale serve already publishes http://${OPENBAO_LISTEN_ADDR}."
  else
    log_info "Publishing OpenBao on the tailnet via 'tailscale serve' (HTTPS:443)..."
    tailscale serve --bg --https=443 "http://${OPENBAO_LISTEN_ADDR}" \
      || log_warn "tailscale serve failed — enable HTTPS on your tailnet and retry."
  fi

  local fqdn
  fqdn=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // ""' | sed 's/\.$//')
  if [[ -n "$fqdn" ]]; then
    log_info "OpenBao should now be reachable at: https://${fqdn}"
    if [[ "$OPENBAO_API_ADDR" != "https://${fqdn}" ]]; then
      log_warn "OPENBAO_API_ADDR is '${OPENBAO_API_ADDR}'."
      log_warn "For OIDC / UI redirects, set it to 'https://${fqdn}' and re-run, or edit ${BAO_CONFIG_DIR}/config.hcl."
    fi
  fi
}

# ============================================================
# Proxmox-host helpers
# ============================================================

# Detect newest Alpine LXC template available from the Proxmox repos.
detect_latest_alpine_template() {
  local tmpl
  tmpl=$(pveam available --section system 2>/dev/null \
    | awk '/^system[[:space:]]+alpine-/ {print $2}' \
    | sort -V \
    | tail -n1)

  if [[ -z "$tmpl" ]]; then
    log_warn "Could not query pveam; falling back to a known-good Alpine template."
    tmpl="alpine-3.22-default_20250617_amd64.tar.xz"
  fi
  log_info "Selected Alpine template: $tmpl"
  echo "$tmpl"
}

# Find an existing LXC by tag or hostname. Echoes CTID, returns 1 if none.
find_existing_lxc() {
  local id host tags
  while read -r id _; do
    [[ -z "$id" || "$id" == "VMID" ]] && continue
    host=$(pct config "$id" 2>/dev/null | awk -F': ' '/^hostname:/ {print $2}' || true)
    tags=$(pct config "$id" 2>/dev/null | awk -F': ' '/^tags:/ {print $2}' || true)
    if [[ "$host" == "$HOSTNAME_LXC" ]] || [[ ",${tags//;/,}," == *",${LXC_TAG},"* ]]; then
      echo "$id"
      return 0
    fi
  done < <(pct list | awk 'NR>1 {print $1}')
  return 1
}

ensure_template_present() {
  local tmpl="$1"
  if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$tmpl"; then
    log_info "Downloading template ${tmpl} to storage ${TEMPLATE_STORAGE}..."
    pveam update >/dev/null
    pveam download "$TEMPLATE_STORAGE" "$tmpl"
  else
    log_info "Template ${tmpl} already present on ${TEMPLATE_STORAGE}."
  fi
}

# Pick next available CTID if user did not provide one.
allocate_ctid() {
  pvesh get /cluster/nextid 2>/dev/null \
    || pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
       | jq '[.[].vmid] | max + 1' \
    || echo 100
}

# Inject the script into the container and execute it in the requested mode.
# Forwards the relevant runtime configuration through the environment so the
# inner invocation produces the same config the user requested on the host.
exec_in_lxc() {
  local ctid="$1"
  local mode="$2"   # --install or --update

  # Ensure base tooling exists inside the container before piping the script.
  pct exec "$ctid" -- sh -c "apk add --no-cache bash curl jq ca-certificates >/dev/null 2>&1"
  curl -fsSL "$SCRIPT_URL" \
    | pct exec "$ctid" --  env \
        SCRIPT_URL="$SCRIPT_URL" \
        OPENBAO_VERSION="$OPENBAO_VERSION" \
        OPENBAO_HOSTNAME="$HOSTNAME_LXC" \
        OPENBAO_LISTEN_ADDR="$OPENBAO_LISTEN_ADDR" \
        OPENBAO_API_ADDR="$OPENBAO_API_ADDR" \
        TS_AUTHKEY="$TS_AUTHKEY" \
        bash -s -- "$mode"
}

# ============================================================
# MODE: Proxmox host — create LXC + install
# ============================================================
create_lxc() {
  log_info "=== OpenBao — LXC creation ==="

  if [[ -z "$TEMPLATE" ]]; then
    TEMPLATE=$(detect_latest_alpine_template)
  else
    log_info "Using user-provided template: $TEMPLATE"
  fi
  ensure_template_present "$TEMPLATE"

  if [[ -z "$CTID" ]]; then
    CTID=$(allocate_ctid)
    log_info "Auto-selected CTID: $CTID"
  fi

  log_info "Creating LXC ${CTID} (${HOSTNAME_LXC})..."
  pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME_LXC" \
    --cores "$CORES" \
    --memory "$RAM" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged 1 \
    --features "nesting=1" \
    --tags "infra-script,${LXC_TAG}" \
    --onboot 1 \
    --start 0

  # Tailscale needs /dev/net/tun inside the unprivileged container.
  log_info "Adding /dev/net/tun passthrough for Tailscale..."
  cat >> "/etc/pve/lxc/${CTID}.conf" <<EOF
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net dev/net none bind,create=dir
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF

  log_info "Starting LXC ${CTID}..."
  pct start "$CTID"
  # Wait for network to come up
  local tries=0
  until pct exec "$CTID" -- sh -c "ip -4 addr show eth0 | grep -q 'inet '" 2>/dev/null; do
    tries=$((tries + 1))
    if (( tries > 20 )); then
      log_error "LXC ${CTID} did not acquire an IP after 20s."
      exit 1
    fi
    sleep 1
  done

  log_info "Running installer inside LXC ${CTID}..."
  exec_in_lxc "$CTID" "--install"

  local ip
  ip=$(pct exec "$CTID" -- ip -4 addr show eth0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 || true)

  echo ""
  log_info "========================================="
  log_info "LXC ${CTID} created successfully!"
  log_info "========================================="
  echo ""
  echo "  Hostname : ${HOSTNAME_LXC}"
  echo "  IP       : ${ip:-pending}"
  echo "  API      : http://${ip:-<ip>}:8200"
  echo ""
  echo "Next steps:"
  echo "  pct enter ${CTID}"
  echo "  export VAULT_ADDR=http://127.0.0.1:8200"
  echo "  bao operator init        # initialise & retrieve unseal keys + root token"
  echo "  bao operator unseal      # repeat with the unseal keys"
  echo ""
}

# ============================================================
# MODE: Proxmox host — update existing LXC
# ============================================================
update_lxc() {
  local ctid="$1"
  log_info "=== OpenBao — updating existing LXC ${ctid} ==="

  if ! pct status "$ctid" | grep -q running; then
    log_info "Starting LXC ${ctid}..."
    pct start "$ctid"
    sleep 3
  fi

  log_info "Refreshing Alpine packages inside LXC ${ctid}..."
  pct exec "$ctid" -- sh -c "apk update >/dev/null && apk upgrade >/dev/null"

  log_info "Upgrading bao binary inside LXC ${ctid}..."
  exec_in_lxc "$ctid" "--update"

  log_info "Update of LXC ${ctid} complete."
}

# ============================================================
# MODE: inside LXC — fresh install of OpenBao
# ============================================================
install_inside_lxc() {
  log_info "=== OpenBao — installation ==="

  log_info "Updating package index..."
  apk update >/dev/null
  apk upgrade >/dev/null

  log_info "Installing dependencies..."
  apk add --no-cache bash curl jq ca-certificates gcompat openrc logrotate tailscale >/dev/null

  log_info "Enabling tailscaled..."
  rc-update add tailscale default >/dev/null 2>&1 || true
  rc-service tailscale start >/dev/null 2>&1 || log_warn "tailscaled failed to start (is /dev/net/tun mapped into the LXC?)"

  install_or_upgrade_bao

  log_info "Creating ${BAO_USER} system user..."
  if ! id "$BAO_USER" >/dev/null 2>&1; then
    addgroup -S "$BAO_USER" 2>/dev/null || true
    adduser -S -D -H -h "$BAO_DATA_DIR" -s /sbin/nologin -G "$BAO_USER" "$BAO_USER"
  fi

  log_info "Provisioning directories..."
  mkdir -p "$BAO_CONFIG_DIR" "$BAO_DATA_DIR/data"
  chown -R "${BAO_USER}:${BAO_USER}" "$BAO_DATA_DIR"
  chmod 750 "$BAO_DATA_DIR"

  if [[ ! -f "${BAO_CONFIG_DIR}/config.hcl" ]]; then
    log_info "Writing default ${BAO_CONFIG_DIR}/config.hcl..."
    # OpenBao listens on loopback only; Tailscale (running in the same LXC)
    # acts as the reverse proxy and terminates TLS via tailnet certificates.
    # https://openbao.org/docs/configuration/
    cat > "${BAO_CONFIG_DIR}/config.hcl" <<EOF
ui            = true
disable_mlock = true

storage "raft" {
  path    = "${BAO_DATA_DIR}/data"
  node_id = "${HOSTNAME_LXC}"
}

listener "tcp" {
  address     = "${OPENBAO_LISTEN_ADDR}"
  tls_disable = 1
}

api_addr     = "${OPENBAO_API_ADDR}"
cluster_addr = "http://127.0.0.1:8201"
EOF
    chown root:"$BAO_USER" "${BAO_CONFIG_DIR}/config.hcl"
    chmod 640 "${BAO_CONFIG_DIR}/config.hcl"
  else
    log_info "Existing ${BAO_CONFIG_DIR}/config.hcl preserved."
  fi

  log_info "Installing OpenRC service..."
  cat > /etc/init.d/openbao <<'EOF'
#!/sbin/openrc-run

name="OpenBao"
description="OpenBao secrets manager"
command="/usr/local/bin/bao"
command_args="server -config=/etc/openbao/config.hcl"
command_user="openbao:openbao"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
directory="/var/lib/openbao"

output_log="/var/log/openbao.log"
error_log="/var/log/openbao.log"

depend() {
    need net
    after net
}

start_pre() {
    checkpath --directory --owner openbao:openbao --mode 0750 /var/lib/openbao
    checkpath --directory --owner openbao:openbao --mode 0750 /var/lib/openbao/data
    checkpath --file      --owner openbao:openbao --mode 0644 /var/log/openbao.log
}
EOF
  chmod +x /etc/init.d/openbao
  rc-update add openbao default >/dev/null

  cat > /etc/logrotate.d/openbao <<'EOF'
/var/log/openbao.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF
  ln -sf /usr/sbin/logrotate /etc/periodic/daily/logrotate 2>/dev/null || true

  log_info "Starting openbao service..."
  rc-service openbao start || log_warn "openbao failed to start — inspect /var/log/openbao.log"

  log_info "Enabling console auto-login on tty1..."
  # Alpine ships busybox getty by default; agetty (from util-linux) is what
  # supports --autologin.
  apk add --no-cache agetty >/dev/null 2>&1 || apk add --no-cache util-linux >/dev/null

  # Replace any existing tty1 entry, then append our autologin line. Doing it
  # in two steps (delete + append) is more robust than an in-place sed against
  # a pattern that may drift across Alpine releases.
  sed -i '/^tty1::/d' /etc/inittab
  echo 'tty1::respawn:/sbin/agetty --autologin root --noclear 38400 tty1' >> /etc/inittab

  # Tell PID 1 to re-read /etc/inittab so the change takes effect without a reboot.
  kill -HUP 1 2>/dev/null || true

  # Kick any getty/agetty still attached to tty1 so init respawns it *now* with
  # the new line — otherwise the first web-console session lands on the stale
  # process and the operator has to type `exit` once before autologin kicks in.
  pkill -KILL -f '(getty|agetty).*tty1' 2>/dev/null || true

  configure_tailscale_proxy

  log_info "Configuring MOTD..."
  # /etc/profile.d/ runs for every interactive login shell — works for both
  # the auto-login tty and Tailscale SSH. Quoted heredoc: every variable is
  # resolved at login time, not at install time.
  cat > /etc/profile.d/00-openbao.sh <<'MOTD'
TS_FQDN=$(tailscale status --json 2>/dev/null | awk -F'"' '
    /"Self"/ { in_self=1 }
    in_self && /"DNSName"/ { gsub(/\.$/, "", $4); print $4; exit }
')
[[ -z "$TS_FQDN" ]] && TS_FQDN="$(hostname).ts.net"

BAO_VERSION=$(cat /opt/openbao_version.txt 2>/dev/null || echo "unknown")

# `bao status` exit codes: 0 = unsealed, 2 = sealed, anything else = error.
VAULT_ADDR=http://127.0.0.1:8200 /usr/local/bin/bao status >/dev/null 2>&1
case $? in
    0) SEAL_STATE="unsealed" ;;
    2) SEAL_STATE="SEALED (run: bao operator unseal)" ;;
    *) SEAL_STATE="unreachable" ;;
esac

echo ""
echo "  ___                   ____             "
echo " / _ \ _ __   ___ _ __ | __ )  __ _  ___ "
echo "| | | | '_ \ / _ \ '_ \|  _ \ / _\` |/ _ \\"
echo "| |_| | |_) |  __/ | | | |_) | (_| | (_) |"
echo " \___/| .__/ \___|_| |_|____/ \__,_|\___/"
echo "      |_|                                "
echo ""
echo "OpenBao Secrets Manager (${BAO_VERSION})"
echo "─────────────────────────────────────────"
echo "Access:"
echo "  • API (local) : http://127.0.0.1:8200"
echo "  • Tailnet     : https://${TS_FQDN}"
echo "  • Seal status : ${SEAL_STATE}"
echo ""
echo "Useful commands:"
echo "  export VAULT_ADDR=http://127.0.0.1:8200"
echo "  bao status"
echo "  bao operator init       # first-time only"
echo "  bao operator unseal     # after every restart"
echo "  rc-service openbao status"
echo "  tail -f /var/log/openbao.log"
echo "─────────────────────────────────────────"
echo ""
MOTD
  chmod +x /etc/profile.d/00-openbao.sh

  log_info "Cleaning up..."
  rm -rf /var/cache/apk/*

  echo ""
  log_info "========================================="
  log_info "OpenBao installation complete!"
  log_info "========================================="
  echo ""
  echo "Initialise the server with:"
  echo "  export VAULT_ADDR=http://127.0.0.1:8200"
  echo "  bao operator init"
  echo "  bao operator unseal   # repeat with each unseal key share"
  echo ""
}

# ============================================================
# MODE: inside LXC — update only
# ============================================================
update_inside_lxc() {
  log_info "=== OpenBao — update ==="
  apk update >/dev/null
  apk upgrade >/dev/null
  install_or_upgrade_bao
  configure_tailscale_proxy
  log_info "Update complete."
}

# ============================================================
# Main — dispatch on explicit mode flag or auto-detect context
# ============================================================
main() {
  case "${1:-}" in
    --install)
      install_inside_lxc
      return
      ;;
    --update)
      update_inside_lxc
      return
      ;;
  esac

  if command -v pct >/dev/null 2>&1; then
    # Running on a Proxmox host
    require_root

    local existing=""
    if existing=$(find_existing_lxc); then
      log_info "Found existing OpenBao LXC (CTID ${existing}, hostname/tag match) — switching to update mode."
      update_lxc "$existing"
    else
      create_lxc
    fi
  else
    # Inside a container (no Proxmox tooling)
    require_root
    if [[ -x /usr/local/bin/bao ]]; then
      update_inside_lxc
    else
      install_inside_lxc
    fi
  fi
}

main "$@"
