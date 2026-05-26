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
OPENBAO_API="https://api.github.com/repos/openbao/openbao/releases"
SCRIPT_URL="https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/feat/lxc-OpenBao/openbao/install.sh"
VERSION_FILE="/opt/openbao_version.txt"
BAO_USER="openbao"
BAO_CONFIG_DIR="/etc/openbao"
BAO_DATA_DIR="/var/lib/openbao"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

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

get_arch() {
  case "$(uname -m)" in
    x86_64)  echo "amd64" ;;
    aarch64) echo "arm64" ;;
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
  tag=$(curl -fsSL "${OPENBAO_API}/latest" | jq -r '.tag_name')
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

  # OpenBao publishes zip archives named bao_<version>_linux_<arch>.zip
  url="https://github.com/openbao/openbao/releases/download/${tag}/bao_${version}_linux_${arch}.zip"
  log_info "Downloading OpenBao ${tag} (${arch}) from ${url}..."

  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' RETURN
  curl -fsSL "$url" -o "${tmpdir}/bao.zip"
  unzip -q -o "${tmpdir}/bao.zip" -d "$tmpdir"

  if [[ ! -f "${tmpdir}/bao" ]]; then
    log_error "Archive did not contain expected 'bao' binary."
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
exec_in_lxc() {
  local ctid="$1"
  local mode="$2"   # --install or --update

  # Ensure base tooling exists inside the container before piping the script.
  pct exec "$ctid" -- sh -c "apk add --no-cache bash curl jq unzip ca-certificates >/dev/null 2>&1"
  curl -fsSL "$SCRIPT_URL" | pct exec "$ctid" -- bash -s -- "$mode"
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
  # gcompat: OpenBao binaries are glibc-built; gcompat is required on musl Alpine.
  apk add --no-cache bash curl jq unzip ca-certificates gcompat openrc logrotate >/dev/null

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
    cat > "${BAO_CONFIG_DIR}/config.hcl" <<EOF
ui            = true
disable_mlock = true

storage "raft" {
  path    = "${BAO_DATA_DIR}/data"
  node_id = "${HOSTNAME_LXC}"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

api_addr     = "http://0.0.0.0:8200"
cluster_addr = "http://0.0.0.0:8201"
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
