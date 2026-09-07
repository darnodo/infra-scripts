#!/bin/bash
# install.sh - Semaphore UI: LXC creation, installation & update
# Usage:
#   From Proxmox host : bash -c "$(curl -fsSL https://raw.githubusercontent.com/darnodo/infra-scripts/main/semaphore/install.sh)"
#   From inside LXC   : bash /root/install.sh           (updates the semaphore binary)
#
# Single entrypoint, three automatic modes:
#   1. Proxmox host, no existing container    -> create Alpine LXC + install Semaphore
#   2. Proxmox host, container already present -> refresh packages + upgrade Semaphore
#   3. Inside an LXC                           -> install if missing, otherwise update
#
# The script writes config.json and runs the migrations itself, so
# `semaphore setup` is never needed. It stops before creating the admin user
# and before starting the service: both are yours to do.
# See: https://semaphoreui.com/docs/admin-guide/installation/binary-file

set -euo pipefail

# --- Config (override via environment) ---
CTID="${CTID:-}"
HOSTNAME_LXC="${SEMAPHORE_HOSTNAME:-semaphore}"
TEMPLATE="${TEMPLATE:-}"                          # auto-detected when empty
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
CORES="${CORES:-2}"
RAM="${RAM:-2048}"
DISK="${DISK:-12}"
BRIDGE="${BRIDGE:-vmbr0}"
LXC_TAG="${LXC_TAG:-semaphore}"                   # stable identifier for the container
SEMAPHORE_VERSION="${SEMAPHORE_VERSION:-latest}"  # "latest" or e.g. "v2.19.12"
# Upstream ships two builds per release: `semaphore_community` and `semaphore`
# (Pro features present but licence-gated). Switch with SEMAPHORE_EDITION=standard.
SEMAPHORE_EDITION="${SEMAPHORE_EDITION:-community}"
SEMAPHORE_RELEASES_URL="${SEMAPHORE_RELEASES_URL:-https://api.github.com/repos/semaphoreui/semaphore/releases}"
# Loopback only. Tailscale is the reverse proxy and terminates TLS.
SEMAPHORE_LISTEN_ADDR="${SEMAPHORE_LISTEN_ADDR:-127.0.0.1:3000}"
# Optional: pre-authorise the LXC's Tailscale non-interactively.
# Generate at https://login.tailscale.com/admin/settings/keys
TS_AUTHKEY="${TS_AUTHKEY:-}"
# The host curls SCRIPT_URL and pipes the result into `pct exec`, so this only
# ever has to be reachable from the Proxmox host. A file:// URL works, which is
# how you test an unpushed branch.
SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/darnodo/infra-scripts/main/semaphore/install.sh}"
VERSION_FILE="${VERSION_FILE:-/opt/semaphore_version.txt}"
SEMAPHORE_USER="semaphore"
SEMAPHORE_CONFIG_DIR="/etc/semaphore"
SEMAPHORE_CONFIG="${SEMAPHORE_CONFIG_DIR}/config.json"
SEMAPHORE_DATA_DIR="/var/lib/semaphore"

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

# Semaphore names its release assets with the Go arch (amd64, arm64), not `uname -m`.
get_arch() {
  case "$(uname -m)" in
    x86_64)  echo "amd64" ;;
    aarch64) echo "arm64" ;;
    *)       log_error "Unsupported architecture: $(uname -m)"; exit 1 ;;
  esac
}

# Resolve "latest" -> concrete tag name, otherwise echo input unchanged.
resolve_semaphore_version() {
  local requested="$1"
  if [[ "$requested" != "latest" ]]; then
    echo "$requested"
    return 0
  fi
  local tag
  tag=$(curl -fsSL "${SEMAPHORE_RELEASES_URL}/latest" | jq -r '.tag_name')
  if [[ -z "$tag" || "$tag" == "null" ]]; then
    log_error "Failed to resolve latest Semaphore release from GitHub API."
    exit 1
  fi
  echo "$tag"
}

# ============================================================
# Proxmox-host helpers
# ============================================================

# Pick the newest Alpine LXC template the Proxmox repos advertise. Falls back to
# a hardcoded known-good template if `pveam` is unavailable or returns nothing.
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

# Download the template if missing. `pveam update` first, so a stale local cache
# doesn't silently settle for an older version than the one just picked.
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

# Find an existing LXC by hostname or tag. Echoes the CTID, returns 1 if none.
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

# Pick next available CTID if the user did not provide one.
allocate_ctid() {
  pvesh get /cluster/nextid 2>/dev/null \
    || pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
       | jq '[.[].vmid] | max + 1' \
    || echo 100
}

# Inject the script into the container and execute it in the requested mode.
exec_in_lxc() {
  local ctid="$1"
  local mode="$2"   # --install or --update

  # Ensure base tooling exists inside the container before piping the script.
  pct exec "$ctid" -- sh -c "apk add --no-cache bash curl jq ca-certificates >/dev/null 2>&1"
  curl -fsSL "$SCRIPT_URL" \
    | pct exec "$ctid" -- env \
        SEMAPHORE_VERSION="$SEMAPHORE_VERSION" \
        SEMAPHORE_EDITION="$SEMAPHORE_EDITION" \
        SEMAPHORE_HOSTNAME="$HOSTNAME_LXC" \
        SEMAPHORE_LISTEN_ADDR="$SEMAPHORE_LISTEN_ADDR" \
        TS_AUTHKEY="$TS_AUTHKEY" \
        bash -s -- "$mode"
}

# ============================================================
# Inside-LXC helpers
# ============================================================
refresh_os_packages() {
  log_info "Refreshing Alpine packages..."
  apk update >/dev/null && apk upgrade >/dev/null
}

# Enable root auto-login on tty1 (Alpine/OpenRC). Idempotent.
enable_tty1_autologin() {
  log_info "Enabling console auto-login on tty1..."
  # Alpine ships busybox getty by default; agetty (from util-linux) is what
  # supports --autologin.
  apk add --no-cache agetty >/dev/null 2>&1 || apk add --no-cache util-linux >/dev/null

  # Delete + append rather than an in-place sed against a pattern that may
  # drift across Alpine releases.
  sed -i '/^tty1::/d' /etc/inittab
  echo 'tty1::respawn:/sbin/agetty --autologin root --noclear 38400 tty1' >> /etc/inittab

  kill -HUP 1 2>/dev/null || true

  # Kick any getty still attached to tty1 so init respawns it now with the new
  # line. Otherwise the first console session lands on the stale process.
  pkill -KILL -f '(getty|agetty).*tty1' 2>/dev/null || true
}

# ============================================================
# Reusable: install or upgrade the semaphore binary in-place.
# Used by both the fresh-install and update flows.
# ============================================================
install_or_upgrade_semaphore() {
  local tag arch version asset url tmpdir current

  tag=$(resolve_semaphore_version "$SEMAPHORE_VERSION")
  arch=$(get_arch)
  version="${tag#v}"

  current=""
  if [[ -f "$VERSION_FILE" ]]; then
    current=$(cat "$VERSION_FILE")
  fi

  if [[ "$current" == "$tag" && -x /usr/local/bin/semaphore ]]; then
    log_info "Semaphore already at $tag, nothing to do."
    return 0
  fi

  # Asset naming: semaphore_<version>_linux_<arch>.tar.gz, with a parallel
  # semaphore_community_<version>_... build.
  if [[ "$SEMAPHORE_EDITION" == "standard" ]]; then
    asset="semaphore_${version}_linux_${arch}.tar.gz"
  else
    asset="semaphore_community_${version}_linux_${arch}.tar.gz"
  fi
  url="https://github.com/semaphoreui/semaphore/releases/download/${tag}/${asset}"
  log_info "Downloading Semaphore ${tag} (${arch}, ${SEMAPHORE_EDITION}) from ${url}..."

  tmpdir=$(mktemp -d)
  curl -fsSL "$url" -o "${tmpdir}/semaphore.tar.gz"
  tar -xzf "${tmpdir}/semaphore.tar.gz" -C "$tmpdir"

  if [[ ! -f "${tmpdir}/semaphore" ]]; then
    log_error "Archive did not contain the expected 'semaphore' binary."
    rm -rf "$tmpdir"
    exit 1
  fi

  # Stop the service if running, swap the binary, then restart.
  local service_was_running=0
  if command -v rc-service >/dev/null 2>&1 && rc-service semaphore status >/dev/null 2>&1; then
    service_was_running=1
    log_info "Stopping semaphore service for upgrade..."
    rc-service semaphore stop || true
  fi

  if [[ -x /usr/local/bin/semaphore ]]; then
    cp /usr/local/bin/semaphore "/usr/local/bin/semaphore.bak.$(date +%s)"
  fi
  install -m 0755 "${tmpdir}/semaphore" /usr/local/bin/semaphore
  echo "$tag" > "$VERSION_FILE"

  log_info "Installed: $(/usr/local/bin/semaphore version 2>&1 | head -n1 || true)"

  if [[ "$service_was_running" -eq 1 ]]; then
    log_info "Restarting semaphore service..."
    rc-service semaphore start
  fi

  rm -rf "$tmpdir"
}

# ============================================================
# Write a ready-to-run config.json so the operator never has to sit through
# `semaphore setup`. That wizard defaults to MySQL and, since 2.19, panics on
# its own BoltDB option. SQLite is the obvious single-node backend here, and
# the binary ships a pure-Go driver, so nothing extra is needed.
#
# Same shape `semaphore setup` produces, plus the `interface` key it omits.
# Never overwrites an existing config.
# ============================================================
write_default_config() {
  if [[ -f "$SEMAPHORE_CONFIG" ]]; then
    log_info "Existing ${SEMAPHORE_CONFIG} preserved."
    return 0
  fi

  log_info "Writing ${SEMAPHORE_CONFIG} (sqlite, listening on ${SEMAPHORE_LISTEN_ADDR})..."
  # Three independent 32-byte secrets, exactly as the wizard generates them.
  # Losing access_key_encryption makes every stored credential unreadable.
  cat > "$SEMAPHORE_CONFIG" <<EOF
{
  "dialect": "sqlite",
  "sqlite": {
    "host": "${SEMAPHORE_DATA_DIR}/database.sqlite"
  },
  "interface": "${SEMAPHORE_LISTEN_ADDR}",
  "tmp_path": "${SEMAPHORE_DATA_DIR}/tmp",
  "cookie_hash": "$(openssl rand -base64 32)",
  "cookie_encryption": "$(openssl rand -base64 32)",
  "access_key_encryption": "$(openssl rand -base64 32)"
}
EOF
  chown root:"$SEMAPHORE_USER" "$SEMAPHORE_CONFIG"
  chmod 640 "$SEMAPHORE_CONFIG"
}

# ============================================================
# Reusable: bring the schema up to date. Idempotent: a no-op when the database
# already matches the binary. Runs as the semaphore user so the SQLite file and
# its -wal/-shm siblings stay owned by the service.
# ============================================================
run_migrations() {
  [[ -f "$SEMAPHORE_CONFIG" ]] || return 0
  log_info "Running database migrations..."
  su -s /bin/sh -c "/usr/local/bin/semaphore migrate --config=${SEMAPHORE_CONFIG}" "$SEMAPHORE_USER" >/dev/null \
    || { log_error "Migrations failed. Inspect with: semaphore migrate --config=${SEMAPHORE_CONFIG}"; exit 1; }
}

# ============================================================
# Reusable: force the listener back onto the loopback address.
# `semaphore setup` writes "interface": ":3000" (all interfaces); this rewrites
# it once the config exists. No-op before the operator has run setup.
# ============================================================
enforce_loopback_listener() {
  [[ -f "$SEMAPHORE_CONFIG" ]] || return 0

  local current
  current=$(jq -r '.interface // ""' "$SEMAPHORE_CONFIG")
  if [[ "$current" == "$SEMAPHORE_LISTEN_ADDR" ]]; then
    return 0
  fi

  log_info "Rewriting config.json interface '${current}' -> '${SEMAPHORE_LISTEN_ADDR}'..."
  local tmp
  tmp=$(mktemp)
  jq --arg addr "$SEMAPHORE_LISTEN_ADDR" '.interface = $addr' "$SEMAPHORE_CONFIG" > "$tmp"
  cat "$tmp" > "$SEMAPHORE_CONFIG"   # preserve ownership/mode of the original
  rm -f "$tmp"
}

# ============================================================
# Reusable: bring Tailscale up and publish Semaphore on the tailnet.
# Idempotent once the node is logged in and the serve mapping exists.
# ============================================================
configure_tailscale_proxy() {
  if ! command -v tailscale >/dev/null 2>&1; then
    log_warn "tailscale CLI not found, skipping reverse-proxy setup."
    return 0
  fi

  local backend_state
  backend_state=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "unknown"')
  if [[ "$backend_state" != "Running" ]]; then
    if [[ -n "$TS_AUTHKEY" ]]; then
      log_info "Bringing Tailscale up with the provided auth key..."
      tailscale up --authkey "$TS_AUTHKEY" --ssh --hostname "$HOSTNAME_LXC" \
        || log_warn "tailscale up failed. Run it manually inside the LXC."
    else
      log_warn "Tailscale is not authenticated and TS_AUTHKEY was not supplied."
      log_warn "Finish setup inside the LXC with: tailscale up --ssh"
      log_warn "Then publish Semaphore with:       tailscale serve --bg --https=443 http://${SEMAPHORE_LISTEN_ADDR}"
      return 0
    fi
  fi

  if tailscale serve status 2>/dev/null | grep -q "${SEMAPHORE_LISTEN_ADDR}"; then
    log_info "Tailscale serve already publishes http://${SEMAPHORE_LISTEN_ADDR}."
  else
    log_info "Publishing Semaphore on the tailnet via 'tailscale serve' (HTTPS:443)..."
    tailscale serve --bg --https=443 "http://${SEMAPHORE_LISTEN_ADDR}" \
      || log_warn "tailscale serve failed. Enable HTTPS on your tailnet and retry."
  fi

  local fqdn
  fqdn=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // ""' | sed 's/\.$//')
  if [[ -n "$fqdn" ]]; then
    log_info "Semaphore will be reachable at: https://${fqdn}"
  fi
}

# ============================================================
# MODE: Proxmox host, create LXC + install
# ============================================================
create_lxc() {
  log_info "=== Semaphore: LXC creation ==="

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
  echo ""
  echo "Semaphore is installed and its database is migrated. Add the admin user:"
  echo "  pct enter ${CTID}"
  echo "  semaphore users add --admin --login <login> --name <name> \\"
  echo "      --email <email> --password <password> --config=${SEMAPHORE_CONFIG}"
  echo "  rc-service semaphore start"
  echo ""
}

# ============================================================
# MODE: Proxmox host, update existing LXC
# ============================================================
update_lxc() {
  local ctid="$1"
  log_info "=== Semaphore: updating existing LXC ${ctid} ==="

  if ! pct status "$ctid" | grep -q running; then
    log_info "Starting LXC ${ctid}..."
    pct start "$ctid"
    sleep 3
  fi

  log_info "Refreshing Alpine packages inside LXC ${ctid}..."
  # refresh_os_packages() is a bash function local to this process; it cannot
  # cross the `pct exec ... sh -c` boundary, so this call site stays inline.
  pct exec "$ctid" -- sh -c "apk update >/dev/null && apk upgrade >/dev/null"

  log_info "Upgrading Semaphore inside LXC ${ctid}..."
  exec_in_lxc "$ctid" "--update"

  log_info "Update of LXC ${ctid} complete."
}

# ============================================================
# MODE: inside LXC, fresh install
# ============================================================
install_inside_lxc() {
  log_info "=== Semaphore: installation ==="

  log_info "Updating package index..."
  apk update >/dev/null
  apk upgrade >/dev/null

  log_info "Installing dependencies..."
  # The upstream binary is a static CGO-free build, so gcompat is unnecessary.
  # ansible/opentofu/git/openssh: what Semaphore actually shells out to.
  # openssl: generates the three secrets in config.json.
  apk add --no-cache bash curl jq ca-certificates openssl openrc logrotate \
    tailscale git openssh-client python3 py3-pip ansible >/dev/null
  # opentofu landed in the community repo; don't fail the install if this
  # Alpine release doesn't carry it.
  apk add --no-cache opentofu >/dev/null 2>&1 \
    || log_warn "opentofu is not in this Alpine's repos. Install it by hand if you need Terraform tasks."

  log_info "Enabling tailscaled..."
  rc-update add tailscale default >/dev/null 2>&1 || true
  rc-service tailscale start >/dev/null 2>&1 || log_warn "tailscaled failed to start (is /dev/net/tun mapped into the LXC?)"

  install_or_upgrade_semaphore

  log_info "Creating ${SEMAPHORE_USER} system user..."
  if ! id "$SEMAPHORE_USER" >/dev/null 2>&1; then
    addgroup -S "$SEMAPHORE_USER" 2>/dev/null || true
    adduser -S -D -H -h "$SEMAPHORE_DATA_DIR" -s /bin/sh -G "$SEMAPHORE_USER" "$SEMAPHORE_USER"
  fi

  log_info "Provisioning directories..."
  mkdir -p "$SEMAPHORE_CONFIG_DIR" "$SEMAPHORE_DATA_DIR" "${SEMAPHORE_DATA_DIR}/tmp"
  chown -R "${SEMAPHORE_USER}:${SEMAPHORE_USER}" "$SEMAPHORE_DATA_DIR"
  chmod 750 "$SEMAPHORE_DATA_DIR"
  chown root:"$SEMAPHORE_USER" "$SEMAPHORE_CONFIG_DIR"
  chmod 750 "$SEMAPHORE_CONFIG_DIR"

  write_default_config
  run_migrations

  log_info "Installing OpenRC service..."
  cat > /etc/init.d/semaphore <<'EOF'
#!/sbin/openrc-run

name="Semaphore"
description="Semaphore UI - Ansible / OpenTofu web interface"
command="/usr/local/bin/semaphore"
command_args="server --config=/etc/semaphore/config.json"
command_user="semaphore:semaphore"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
directory="/var/lib/semaphore"

output_log="/var/log/semaphore.log"
error_log="/var/log/semaphore.log"

depend() {
    need net
    after net
}

start_pre() {
    if [ ! -f /etc/semaphore/config.json ]; then
        eerror "/etc/semaphore/config.json is missing. Re-run the install script."
        return 1
    fi
    checkpath --directory --owner semaphore:semaphore --mode 0750 /var/lib/semaphore
    checkpath --file      --owner semaphore:semaphore --mode 0644 /var/log/semaphore.log
}
EOF
  chmod +x /etc/init.d/semaphore
  rc-update add semaphore default >/dev/null

  cat > /etc/logrotate.d/semaphore <<'EOF'
/var/log/semaphore.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF
  ln -sf /usr/sbin/logrotate /etc/periodic/daily/logrotate 2>/dev/null || true

  # Ours already binds the loopback; this only matters when the operator
  # hand-wrote a config before running the script.
  enforce_loopback_listener

  enable_tty1_autologin
  configure_tailscale_proxy

  log_info "Configuring MOTD..."
  # /etc/profile.d/ runs for every interactive login shell, the auto-login tty
  # and Tailscale SSH alike. Quoted heredoc: everything resolves at login time.
  cat > /etc/profile.d/00-semaphore.sh <<'MOTD'
TS_FQDN=$(tailscale status --json 2>/dev/null | awk -F'"' '
    /"Self"/ { in_self=1 }
    in_self && /"DNSName"/ { gsub(/\.$/, "", $4); print $4; exit }
')
[ -z "$TS_FQDN" ] && TS_FQDN="$(hostname).ts.net"

SEM_VERSION=$(cat /opt/semaphore_version.txt 2>/dev/null || echo "unknown")

if [ ! -f /etc/semaphore/config.json ]; then
    SEM_STATE="no config (re-run the install script)"
elif rc-service semaphore status >/dev/null 2>&1; then
    SEM_STATE="running"
else
    SEM_STATE="stopped (run: rc-service semaphore start)"
fi

echo ""
echo " ____                              _                   "
echo "/ ___|  ___ _ __ ___   __ _ _ __| |__   ___  _ __ ___ "
echo "\\___ \\ / _ \\ '_ \` _ \\ / _\` | '_ \\| '_ \\ / _ \\| '__/ _ \\"
echo " ___) |  __/ | | | | | (_| | |_) | | | | (_) | | |  __/"
echo "|____/ \\___|_| |_| |_|\\__,_| .__/|_| |_|\\___/|_|  \\___|"
echo "                           |_|                         "
echo ""
echo "Semaphore UI (${SEM_VERSION})"
echo "─────────────────────────────────────────"
echo "Access:"
echo "  • Local   : http://127.0.0.1:3000"
echo "  • Tailnet : https://${TS_FQDN}"
echo "  • State   : ${SEM_STATE}"
echo ""
echo "Useful commands:"
echo "  semaphore users list --config=/etc/semaphore/config.json"
echo "  semaphore users add --admin --config=/etc/semaphore/config.json ..."
echo "  rc-service semaphore status"
echo "  tail -f /var/log/semaphore.log"
echo "─────────────────────────────────────────"
echo ""
MOTD
  chmod +x /etc/profile.d/00-semaphore.sh

  log_info "Cleaning up..."
  rm -rf /var/cache/apk/*

  echo ""
  log_info "========================================="
  log_info "Semaphore installation complete!"
  log_info "========================================="
  echo ""
  echo "Config written to ${SEMAPHORE_CONFIG} (sqlite, ${SEMAPHORE_LISTEN_ADDR})"
  echo "and the schema is migrated. You do not need to run 'semaphore setup'."
  echo ""
  echo "Create the admin user, then start the service:"
  echo ""
  echo "  semaphore users add --admin --login <login> --name <name> \\"
  echo "      --email <email> --password <password> --config=${SEMAPHORE_CONFIG}"
  echo "  rc-service semaphore start"
  echo ""
  echo "Back up ${SEMAPHORE_CONFIG}: without access_key_encryption every stored"
  echo "credential becomes unreadable."
  echo ""
}

# ============================================================
# MODE: inside LXC, update only
# ============================================================
update_inside_lxc() {
  log_info "=== Semaphore: update ==="
  refresh_os_packages
  install_or_upgrade_semaphore
  run_migrations
  enforce_loopback_listener
  configure_tailscale_proxy
  log_info "Update complete."
}

# ============================================================
# Main: dispatch on explicit mode flag, or auto-detect the context
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
      log_info "Found an existing Semaphore LXC (CTID ${existing}, hostname/tag match). Switching to update mode."
      update_lxc "$existing"
    else
      create_lxc
    fi
  else
    # Inside a container (no Proxmox tooling)
    require_root
    if [[ -x /usr/local/bin/semaphore ]]; then
      update_inside_lxc
    else
      install_inside_lxc
    fi
  fi
}

main "$@"
