#!/bin/bash
# install.sh - FerretDB: LXC creation, installation & update
# Usage:
#   From Proxmox host : bash -c "$(curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/ferretdb/install.sh)"
#   From inside LXC   : bash /root/install.sh           (updates packages)
#
# Single entrypoint, three automatic modes:
#   1. Proxmox host, no existing container  -> create Debian LXC + install FerretDB
#   2. Proxmox host, container already present -> update packages + upgrade FerretDB
#   3. Inside an LXC                         -> install if missing, otherwise update
#
# FerretDB v2 is a MongoDB wire-protocol proxy backed by PostgreSQL + the
# DocumentDB extension. The extension is a compiled C PostgreSQL extension and
# is only published as deb/rpm packages (no Alpine/musl build), so this stack
# runs on Debian — unlike the openbao/gitea-runner Alpine LXCs in this repo.
#
# The package install/upgrade logic lives in a single reusable function
# (install_or_upgrade_packages) shared by both the create and update paths.

set -euo pipefail

# Force an always-present locale. A fresh Debian template has not generated the
# host's locale (e.g. fr_FR.UTF-8 inherited through pct exec), so apt, perl and
# apt-listchanges warn loudly about it. C.UTF-8 ships with glibc and is always
# valid; this silences the noise without installing extra locales.
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# --- Config (override via environment) ---
CTID="${CTID:-}"
HOSTNAME_LXC="${FERRETDB_HOSTNAME:-ferretdb}"
TEMPLATE="${TEMPLATE:-}"                          # auto-detected when empty
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
CORES="${CORES:-2}"
RAM="${RAM:-2048}"                                # Postgres needs more headroom than openbao
DISK="${DISK:-16}"
BRIDGE="${BRIDGE:-vmbr0}"
LXC_TAG="${LXC_TAG:-ferretdb}"                    # stable identifier for the container
PG_VERSION="${PG_VERSION:-17}"                    # PostgreSQL major version (PGDG)
# DocumentDB release tag couples both pieces: it encodes the documentdb package
# version AND the matching FerretDB version. "latest" resolves both at once.
DOCUMENTDB_TAG="${DOCUMENTDB_TAG:-latest}"
# Distro target embedded in the documentdb deb filename. Only deb11/deb12 exist
# today (no deb13). Escape hatch: when upstream ships deb13, set this + TEMPLATE
# to move to trixie without editing the script.
DOCUMENTDB_DISTRO="${DOCUMENTDB_DISTRO:-deb12}"
DOCUMENTDB_RELEASES_URL="${DOCUMENTDB_RELEASES_URL:-https://api.github.com/repos/FerretDB/documentdb/releases}"
# As a database we deliberately expose the listener on all interfaces so other
# hosts (LibreChat) can reach it over the LAN / tailnet. PostgreSQL stays local.
FERRETDB_LISTEN_ADDR="${FERRETDB_LISTEN_ADDR:-0.0.0.0:27017}"
# Application credentials. The same user/password is both the PostgreSQL role
# FerretDB connects with AND the MongoDB user LibreChat authenticates as.
FERRETDB_USER="${FERRETDB_USER:-ferretdb}"
FERRETDB_PASSWORD="${FERRETDB_PASSWORD:-}"        # auto-generated when empty
# Optional: pre-authorise the LXC's Tailscale non-interactively.
# Generate at https://login.tailscale.com/admin/settings/keys
TS_AUTHKEY="${TS_AUTHKEY:-}"
# SCRIPT_URL is what the host-side flow pipes into the LXC. Override it when
# testing from a non-main branch.
SCRIPT_URL="${SCRIPT_URL:-https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/ferretdb/install.sh}"
VERSION_FILE="${VERSION_FILE:-/opt/ferretdb_version.txt}"

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

# Debian packages use dpkg-style arch names (amd64, arm64), which is also what
# both the FerretDB and DocumentDB release assets are named with.
get_arch() {
  case "$(uname -m)" in
    x86_64)  echo "amd64" ;;
    aarch64) echo "arm64" ;;
    *)       log_error "Unsupported architecture: $(uname -m)"; exit 1 ;;
  esac
}

# Resolve the DocumentDB release tag into the two coupled versions it encodes.
# Sets globals: DOC_TAG (full tag), DOC_PKG_VER (documentdb pkg version),
# FERRET_VER (matching FerretDB version, no leading v).
# Tag shape: v0.107.0-ferretdb-2.7.0
resolve_versions() {
  local endpoint tag
  if [[ "$DOCUMENTDB_TAG" == "latest" ]]; then
    endpoint="${DOCUMENTDB_RELEASES_URL}/latest"
  else
    endpoint="${DOCUMENTDB_RELEASES_URL}/tags/${DOCUMENTDB_TAG}"
  fi
  tag=$(curl -fsSL "$endpoint" | jq -r '.tag_name')
  if [[ -z "$tag" || "$tag" == "null" ]]; then
    log_error "Failed to resolve DocumentDB release '${DOCUMENTDB_TAG}' from GitHub API."
    exit 1
  fi
  DOC_TAG="$tag"
  DOC_PKG_VER="${tag#v}"                  # 0.107.0-ferretdb-2.7.0
  DOC_PKG_VER="${DOC_PKG_VER%%-ferretdb-*}"   # 0.107.0
  FERRET_VER="${tag##*-ferretdb-}"        # 2.7.0
  if [[ -z "$DOC_PKG_VER" || -z "$FERRET_VER" || "$FERRET_VER" == "$tag" ]]; then
    log_error "Could not parse DocumentDB tag '${tag}' (expected vX-ferretdb-Y)."
    exit 1
  fi
}

# ============================================================
# Reusable: install or upgrade PostgreSQL + DocumentDB + FerretDB.
# Used by both fresh-install and update flows. Idempotent.
# ============================================================
install_or_upgrade_packages() {
  local arch current doc_url ferret_url tmpdir doc_deb_name doc_full_ver
  resolve_versions
  arch=$(get_arch)

  current=""
  if [[ -f "$VERSION_FILE" ]]; then
    current=$(cat "$VERSION_FILE")
  fi

  if [[ "$current" == "$DOC_TAG" && -x /usr/bin/ferretdb ]]; then
    log_info "FerretDB stack already at ${DOC_TAG}, nothing to do."
    return 0
  fi

  # Ensure the PGDG repo is present so the requested PostgreSQL major exists.
  if [[ ! -f /etc/apt/sources.list.d/pgdg.list ]]; then
    log_info "Adding the PostgreSQL APT (PGDG) repository..."
    install -d -m 0755 /usr/share/keyrings
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg
    echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt $(. /etc/os-release && echo "$VERSION_CODENAME")-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list
    apt-get update >/dev/null
  fi

  log_info "Installing PostgreSQL ${PG_VERSION} + pg_cron..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    "postgresql-${PG_VERSION}" "postgresql-${PG_VERSION}-cron" >/dev/null

  # documentdb deb naming: deb12-postgresql-17-documentdb_0.107.0.ferretdb.2.7.0_amd64.deb
  doc_full_ver="${DOC_PKG_VER}.ferretdb.${FERRET_VER}"
  doc_deb_name="${DOCUMENTDB_DISTRO}-postgresql-${PG_VERSION}-documentdb_${doc_full_ver}_${arch}.deb"
  doc_url="https://github.com/FerretDB/documentdb/releases/download/${DOC_TAG}/${doc_deb_name}"
  ferret_url="https://github.com/FerretDB/FerretDB/releases/download/v${FERRET_VER}/ferretdb-${arch}-linux.deb"

  tmpdir=$(mktemp -d)
  log_info "Downloading DocumentDB extension (${doc_deb_name})..."
  curl -fsSL "$doc_url" -o "${tmpdir}/documentdb.deb"
  log_info "Downloading FerretDB ${FERRET_VER} (${arch})..."
  curl -fsSL "$ferret_url" -o "${tmpdir}/ferretdb.deb"

  log_info "Installing DocumentDB extension + FerretDB (apt resolves dependencies)..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    "${tmpdir}/documentdb.deb" "${tmpdir}/ferretdb.deb" >/dev/null

  # If the extension is already created (update path), bring it to the new version.
  if su -s /bin/sh postgres -c "psql -tAc \"SELECT 1 FROM pg_extension WHERE extname='documentdb'\" -d postgres" 2>/dev/null | grep -q 1; then
    log_info "Updating documentdb extension to ${DOC_PKG_VER}..."
    su -s /bin/sh postgres -c "psql -d postgres -c 'ALTER EXTENSION documentdb UPDATE;'" >/dev/null 2>&1 || \
      log_warn "ALTER EXTENSION documentdb UPDATE failed — check after restart."
  fi

  echo "$DOC_TAG" > "$VERSION_FILE"
  rm -rf "$tmpdir"

  log_info "Installed FerretDB: $(/usr/bin/ferretdb --version 2>&1 | head -n1 || true)"

  # Restart services if they already exist (update path); the install path
  # enables them explicitly after configuration.
  if systemctl list-unit-files ferretdb.service >/dev/null 2>&1; then
    systemctl restart postgresql 2>/dev/null || true
    systemctl restart ferretdb 2>/dev/null || true
  fi
}

# ============================================================
# Reusable: bring Tailscale up so the LXC joins the tailnet.
# Unlike openbao we do NOT use 'tailscale serve' — FerretDB speaks the raw
# MongoDB wire protocol (TCP), not HTTP, so serve does not apply. The DB is
# reachable directly on 0.0.0.0:27017 over the LAN / tailnet.
# ============================================================
configure_tailscale() {
  if ! command -v tailscale >/dev/null 2>&1; then
    log_warn "tailscale CLI not found, skipping tailnet setup."
    return 0
  fi

  local backend_state
  backend_state=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "unknown"')
  if [[ "$backend_state" == "Running" ]]; then
    log_info "Tailscale already up."
    return 0
  fi

  if [[ -n "$TS_AUTHKEY" ]]; then
    log_info "Bringing Tailscale up with provided auth key..."
    tailscale up --authkey "$TS_AUTHKEY" --ssh --hostname "$HOSTNAME_LXC" \
      || log_warn "tailscale up failed — run it manually inside the LXC."
  else
    log_warn "Tailscale not authenticated and TS_AUTHKEY was not supplied."
    log_warn "Finish setup inside the LXC with: tailscale up --ssh --hostname ${HOSTNAME_LXC}"
  fi
}

# ============================================================
# Proxmox-host helpers
# ============================================================

# The installer re-fetches itself inside the LXC from SCRIPT_URL. Verify it is
# reachable on the host *before* creating any container, so a wrong branch/path
# fails immediately with guidance instead of dying mid-install with a curl 404.
preflight_script_url() {
  if curl -fsSL -o /dev/null "$SCRIPT_URL"; then
    return 0
  fi
  log_error "SCRIPT_URL is not reachable: ${SCRIPT_URL}"
  log_error "The installer re-fetches itself inside the LXC from SCRIPT_URL, so this"
  log_error "must resolve. If you are testing from a branch (not yet on main), pass it:"
  log_error "  SCRIPT_URL=https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/<branch>/ferretdb/install.sh \\"
  log_error "    bash -c \"\$(curl -fsSL \"\$SCRIPT_URL\")\""
  exit 1
}

# Detect newest Debian *12* LXC template available from the Proxmox repos.
# Deliberately pinned to debian-12: the DocumentDB extension only ships a deb12
# build (DOCUMENTDB_DISTRO default), and a newer template (e.g. debian-13) would
# pair that deb against a different libicu soname. To move to trixie, set both
# TEMPLATE and DOCUMENTDB_DISTRO yourself once upstream publishes a deb13 build.
detect_latest_debian_template() {
  local tmpl
  tmpl=$(pveam available --section system 2>/dev/null \
    | awk '/^system[[:space:]]+debian-12-/ {print $2}' \
    | sort -V \
    | tail -n1)

  if [[ -z "$tmpl" ]]; then
    log_warn "Could not find a debian-12 template via pveam; falling back to a known-good name."
    tmpl="debian-12-standard_12.7-1_amd64.tar.zst"
  fi
  log_info "Selected Debian template: $tmpl"
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
  pct exec "$ctid" -- sh -c "export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 LANG=C.UTF-8; apt-get update >/dev/null 2>&1; apt-get install -y bash curl jq ca-certificates >/dev/null 2>&1"
  curl -fsSL "$SCRIPT_URL" \
    | pct exec "$ctid" --  env \
        LC_ALL=C.UTF-8 \
        LANG=C.UTF-8 \
        SCRIPT_URL="$SCRIPT_URL" \
        PG_VERSION="$PG_VERSION" \
        DOCUMENTDB_TAG="$DOCUMENTDB_TAG" \
        DOCUMENTDB_DISTRO="$DOCUMENTDB_DISTRO" \
        FERRETDB_HOSTNAME="$HOSTNAME_LXC" \
        FERRETDB_LISTEN_ADDR="$FERRETDB_LISTEN_ADDR" \
        FERRETDB_USER="$FERRETDB_USER" \
        FERRETDB_PASSWORD="$FERRETDB_PASSWORD" \
        TS_AUTHKEY="$TS_AUTHKEY" \
        bash -s -- "$mode"
}

# ============================================================
# MODE: Proxmox host — create LXC + install
# ============================================================
create_lxc() {
  log_info "=== FerretDB — LXC creation ==="

  # Generate the password on the host so we can both pass it in and print it.
  if [[ -z "$FERRETDB_PASSWORD" ]]; then
    FERRETDB_PASSWORD=$(openssl rand -hex 24)
    log_info "Generated FerretDB password (saved in the summary below)."
  fi

  if [[ -z "$TEMPLATE" ]]; then
    TEMPLATE=$(detect_latest_debian_template)
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
    if (( tries > 30 )); then
      log_error "LXC ${CTID} did not acquire an IP after 30s."
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
  echo "  FerretDB : ${FERRETDB_LISTEN_ADDR}"
  echo ""
  echo "LibreChat connection string (set as MONGO_URI in LibreChat's .env):"
  echo "  mongodb://${FERRETDB_USER}:${FERRETDB_PASSWORD}@${ip:-<ip>}:27017/LibreChat"
  echo ""
  echo "Store this password somewhere safe — it is not persisted on the host:"
  echo "  user     : ${FERRETDB_USER}"
  echo "  password : ${FERRETDB_PASSWORD}"
  echo ""
}

# ============================================================
# MODE: Proxmox host — update existing LXC
# ============================================================
update_lxc() {
  local ctid="$1"
  log_info "=== FerretDB — updating existing LXC ${ctid} ==="

  if ! pct status "$ctid" | grep -q running; then
    log_info "Starting LXC ${ctid}..."
    pct start "$ctid"
    sleep 3
  fi

  log_info "Refreshing Debian packages inside LXC ${ctid}..."
  pct exec "$ctid" -- sh -c "export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 LANG=C.UTF-8; apt-get update >/dev/null && apt-get upgrade -y >/dev/null"

  log_info "Upgrading FerretDB stack inside LXC ${ctid}..."
  exec_in_lxc "$ctid" "--update"

  log_info "Update of LXC ${ctid} complete."
}

# ============================================================
# MODE: inside LXC — fresh install of FerretDB
# ============================================================
install_inside_lxc() {
  log_info "=== FerretDB — installation ==="

  if [[ -z "$FERRETDB_PASSWORD" ]]; then
    FERRETDB_PASSWORD=$(openssl rand -hex 24 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
    log_info "Generated FerretDB password (shown in the summary below)."
  fi

  log_info "Updating package index..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update >/dev/null
  apt-get upgrade -y >/dev/null

  log_info "Installing base dependencies..."
  apt-get install -y curl jq ca-certificates gnupg lsb-release sudo logrotate openssl >/dev/null

  log_info "Installing Tailscale..."
  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1 \
      || log_warn "Tailscale install script failed — install it manually later."
  fi
  systemctl enable --now tailscaled >/dev/null 2>&1 \
    || log_warn "tailscaled failed to start (is /dev/net/tun mapped into the LXC?)"

  install_or_upgrade_packages

  log_info "Configuring PostgreSQL for DocumentDB..."
  local pg_confd="/etc/postgresql/${PG_VERSION}/main/conf.d"
  mkdir -p "$pg_confd"
  # https://docs.ferretdb.io/installation/documentdb/deb/
  cat > "${pg_confd}/documentdb.conf" <<EOF
# Managed by infra-scripts/ferretdb — DocumentDB extension settings.
shared_preload_libraries = 'pg_cron,pg_documentdb_core,pg_documentdb'
cron.database_name = 'postgres'

documentdb.enableCompact = true
documentdb.enableLetAndCollationForQueryMatch = true
documentdb.enableNowSystemVariable = true
documentdb.enableSortbyIdPushDownToPrimaryKey = true
documentdb.enableSchemaValidation = true
documentdb.enableBypassDocumentValidation = true
documentdb.enableUserCrud = true
documentdb.maxUserLimit = 100

# Ensure any password we set is hashed with SCRAM-SHA-256 (PG default, set
# explicitly so it is active before roles are provisioned).
password_encryption = 'scram-sha-256'

# Postgres stays loopback-only; FerretDB (same LXC) is the network front door.
listen_addresses = '127.0.0.1'
EOF

  log_info "Restarting PostgreSQL..."
  systemctl restart postgresql

  log_info "Creating the documentdb extension..."
  su -s /bin/sh postgres -c "psql -v ON_ERROR_STOP=1 -d postgres" >/dev/null <<'SQL'
CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;
SQL

  # Provision the user THROUGH DocumentDB — never a plain CREATE ROLE ... PASSWORD.
  # DocumentDB builds the SCRAM-SHA-256 verifier with its own salt length
  # (documentdb.scramDefaultSaltLen = 28 bytes) via documentdb_api.create_user /
  # update_user. A native PostgreSQL role instead stores a 16-byte salt, which
  # MongoDB clients reject at SASL step2 with "invalid salt length of 16".
  # create_user only accepts a read-only role, or the clusterAdmin +
  # readWriteAnyDatabase pair we use here for full read/write (FerretDB/DocumentDB
  # commands/users.c::ValidateAndObtainUserRole). The spec is built with jq so the
  # password is JSON-escaped, then embedded in a $DDB$-dollar-quoted SQL literal.
  log_info "Provisioning MongoDB user '${FERRETDB_USER}' via DocumentDB (28-byte SCRAM salt)..."
  local role_exists cmd spec
  role_exists=$(su -s /bin/sh postgres -c \
    "psql -tAX -d postgres -c \"SELECT 1 FROM pg_roles WHERE rolname = '${FERRETDB_USER}'\"" 2>/dev/null || true)
  if [[ "$role_exists" == "1" ]]; then
    log_info "Role '${FERRETDB_USER}' already exists — resetting its password via DocumentDB."
    cmd="update_user"
    spec=$(jq -nc --arg u "$FERRETDB_USER" --arg p "$FERRETDB_PASSWORD" \
      '{updateUser:$u, pwd:$p}')
  else
    cmd="create_user"
    spec=$(jq -nc --arg u "$FERRETDB_USER" --arg p "$FERRETDB_PASSWORD" \
      '{createUser:$u, pwd:$p, roles:[{role:"clusterAdmin",db:"admin"},{role:"readWriteAnyDatabase",db:"admin"}]}')
  fi
  su -s /bin/sh postgres -c "psql -v ON_ERROR_STOP=1 -d postgres" >/dev/null <<SQL
SELECT documentdb_api.${cmd}(\$DDB\$${spec}\$DDB\$);
SQL

  log_info "Writing FerretDB systemd override..."
  mkdir -p /etc/systemd/system/ferretdb.service.d
  cat > /etc/systemd/system/ferretdb.service.d/override.conf <<EOF
[Service]
Environment=FERRETDB_POSTGRESQL_URL=postgres://${FERRETDB_USER}:${FERRETDB_PASSWORD}@127.0.0.1:5432/postgres
Environment=FERRETDB_LISTEN_ADDR=${FERRETDB_LISTEN_ADDR}
Environment=FERRETDB_TELEMETRY=disable
EOF
  chmod 600 /etc/systemd/system/ferretdb.service.d/override.conf

  systemctl daemon-reload
  log_info "Enabling and starting services..."
  systemctl enable --now postgresql >/dev/null 2>&1 || true
  systemctl enable ferretdb >/dev/null 2>&1 || true
  # Explicit restart: the deb postinst may have already started ferretdb with
  # default settings, in which case 'enable --now' would not re-read our override.
  systemctl restart ferretdb || log_warn "ferretdb failed to start — check 'journalctl -u ferretdb'."

  # --- Log hygiene ---
  # PostgreSQL ships /etc/logrotate.d/postgresql-common already. FerretDB logs to
  # journald, so bound the journal instead of adding a logrotate stanza.
  log_info "Bounding the systemd journal size..."
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/ferretdb.conf <<'EOF'
[Journal]
SystemMaxUse=200M
EOF
  systemctl restart systemd-journald >/dev/null 2>&1 || true

  # --- Console auto-login on tty1 (Proxmox web console / pct console) ---
  log_info "Enabling console auto-login on tty1..."
  mkdir -p /etc/systemd/system/container-getty@1.service.d
  cat > /etc/systemd/system/container-getty@1.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 $TERM
EOF
  systemctl daemon-reload
  systemctl restart container-getty@1.service 2>/dev/null || true

  configure_tailscale

  log_info "Configuring MOTD..."
  # /etc/profile.d/ runs for every interactive login shell — works for both the
  # auto-login tty and Tailscale SSH. Quoted heredoc except the values we want
  # frozen at install time, which we inject via a small companion env file.
  cat > /etc/ferretdb-motd.env <<EOF
FERRETDB_USER='${FERRETDB_USER}'
FERRETDB_LISTEN_ADDR='${FERRETDB_LISTEN_ADDR}'
EOF
  chmod 600 /etc/ferretdb-motd.env

  cat > /etc/profile.d/00-ferretdb.sh <<'MOTD'
[ -f /etc/ferretdb-motd.env ] && . /etc/ferretdb-motd.env

TS_FQDN=$(tailscale status --json 2>/dev/null | awk -F'"' '
    /"Self"/ { in_self=1 }
    in_self && /"DNSName"/ { gsub(/\.$/, "", $4); print $4; exit }
')
[ -z "$TS_FQDN" ] && TS_FQDN="$(hostname).ts.net"
LAN_IP=$(ip -4 addr show eth0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
FERRET_VERSION=$(/usr/bin/ferretdb --version 2>/dev/null | head -n1 || echo "unknown")

systemctl is-active --quiet ferretdb && FERRET_STATE="active" || FERRET_STATE="DOWN"
systemctl is-active --quiet postgresql && PG_STATE="active" || PG_STATE="DOWN"

echo ""
echo " _____                  _   ____  ____  "
echo "|  ___|__ _ __ _ __ ___| |_|  _ \\| __ ) "
echo "| |_ / _ \\ '__| '__/ _ \\ __| | | |  _ \\ "
echo "|  _|  __/ |  | | |  __/ |_| |_| | |_) |"
echo "|_|  \\___|_|  |_|  \\___|\\__|____/|____/ "
echo ""
echo "FerretDB (MongoDB-compatible) — ${FERRET_VERSION}"
echo "─────────────────────────────────────────"
echo "Status:"
echo "  • FerretDB   : ${FERRET_STATE} (listening on ${FERRETDB_LISTEN_ADDR})"
echo "  • PostgreSQL : ${PG_STATE} (127.0.0.1:5432)"
echo ""
echo "LibreChat MONGO_URI:"
echo "  mongodb://${FERRETDB_USER}:<password>@${LAN_IP:-<ip>}:27017/LibreChat"
echo "  (tailnet) mongodb://${FERRETDB_USER}:<password>@${TS_FQDN}:27017/LibreChat"
echo ""
echo "Useful commands:"
echo "  systemctl status ferretdb postgresql"
echo "  journalctl -u ferretdb -f"
echo "  mongosh \"mongodb://${FERRETDB_USER}:<password>@127.0.0.1:27017/\""
echo "─────────────────────────────────────────"
echo ""
MOTD
  chmod +x /etc/profile.d/00-ferretdb.sh

  log_info "Cleaning up..."
  apt-get clean >/dev/null 2>&1 || true

  local ip
  ip=$(ip -4 addr show eth0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 || true)

  echo ""
  log_info "========================================="
  log_info "FerretDB installation complete!"
  log_info "========================================="
  echo ""
  echo "Set this as MONGO_URI in LibreChat's .env:"
  echo "  mongodb://${FERRETDB_USER}:${FERRETDB_PASSWORD}@${ip:-<ip>}:27017/LibreChat"
  echo ""
  echo "Credentials (store safely — not persisted on the Proxmox host):"
  echo "  user     : ${FERRETDB_USER}"
  echo "  password : ${FERRETDB_PASSWORD}"
  echo ""
}

# ============================================================
# MODE: inside LXC — update only
# ============================================================
update_inside_lxc() {
  log_info "=== FerretDB — update ==="
  export DEBIAN_FRONTEND=noninteractive
  apt-get update >/dev/null
  apt-get upgrade -y >/dev/null
  install_or_upgrade_packages
  configure_tailscale
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
    preflight_script_url

    local existing=""
    if existing=$(find_existing_lxc); then
      log_info "Found existing FerretDB LXC (CTID ${existing}, hostname/tag match) — switching to update mode."
      update_lxc "$existing"
    else
      create_lxc
    fi
  else
    # Inside a container (no Proxmox tooling)
    require_root
    if [[ -x /usr/bin/ferretdb ]]; then
      update_inside_lxc
    else
      install_inside_lxc
    fi
  fi
}

main "$@"
