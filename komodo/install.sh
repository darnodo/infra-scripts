#!/bin/bash
# install.sh - Komodo (Docker + MongoDB) on an Alpine VM
# Usage (from inside the Alpine VM, as root):
#   bash -c "$(curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/komodo/install.sh)"
#
# Unlike the openbao/ferretdb scripts, this is targeted at an Alpine *VM*, not
# an LXC: there is no Proxmox-host orchestration mode. The script just installs
# Docker, pulls Komodo (Core + Periphery + MongoDB) via docker compose, and
# fronts it on the tailnet via `tailscale serve --https=443`.
#
# Re-running the script is safe: existing /opt/komodo/compose.env secrets are
# preserved, and `docker compose up -d --pull always` upgrades the images.

set -euo pipefail

# --- Config (override via environment) ---
KOMODO_DIR="${KOMODO_DIR:-/opt/komodo}"
KOMODO_HOSTNAME="${KOMODO_HOSTNAME:-komodo}"
# Komodo Core publishes its HTTP listener on this address — kept on loopback
# only; the tailnet reaches it through `tailscale serve`.
KOMODO_LISTEN_ADDR="${KOMODO_LISTEN_ADDR:-127.0.0.1:9120}"
# `KOMODO_HOST` ends up in the compose.env verbatim. Default is the tailnet
# FQDN you asked for; override to point Komodo at a different reverse proxy.
KOMODO_HOST="${KOMODO_HOST:-https://komodo.taila5ad8.ts.net}"
# Optional: pre-authorise the VM's Tailscale non-interactively.
# Generate at https://login.tailscale.com/admin/settings/keys
TS_AUTHKEY="${TS_AUTHKEY:-}"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Logs go to stderr so callers can safely use $(fn) without capturing log noise.
log_info()  { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    log_error "This script must be run as root (current uid: $(id -u))."
    exit 1
  fi
}

require_alpine() {
  if [[ ! -f /etc/alpine-release ]]; then
    log_error "This script targets Alpine Linux (no /etc/alpine-release found)."
    exit 1
  fi
}

# Hex secret of the requested byte length.
gen_secret() {
  local bytes="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
  else
    head -c "$bytes" /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

# ============================================================
# Docker — Alpine install per https://wiki.alpinelinux.org/wiki/Docker
# ============================================================
install_docker() {
  log_info "Enabling the Alpine 'community' repository..."
  # The community repo holds the docker package. The default repositories file
  # carries a commented `community` line; uncomment it (idempotent).
  sed -i -E 's|^#(.*/community)$|\1|' /etc/apk/repositories

  log_info "Updating package index..."
  apk update >/dev/null

  log_info "Installing Docker + Compose plugin..."
  # docker-cli-compose provides `docker compose` (v2 plugin), which is what the
  # Komodo upstream docs assume. openrc is normally already on the VM but
  # listing it explicitly keeps this script self-contained.
  apk add --no-cache docker docker-cli-compose openrc >/dev/null

  log_info "Enabling dockerd at boot..."
  rc-update add docker default >/dev/null

  if ! rc-service docker status >/dev/null 2>&1; then
    log_info "Starting dockerd..."
    rc-service docker start >/dev/null
  else
    log_info "dockerd already running."
  fi

  # Sanity check — fail fast if the daemon never came up.
  local tries=0
  until docker info >/dev/null 2>&1; do
    tries=$((tries + 1))
    if (( tries > 15 )); then
      log_error "dockerd did not become ready after 15s — check /var/log/docker.log"
      exit 1
    fi
    sleep 1
  done
}

# ============================================================
# Tailscale — install and front Komodo with `tailscale serve`
# ============================================================
install_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    log_info "Tailscale already installed."
    return 0
  fi
  log_info "Installing Tailscale from the Alpine community repo..."
  apk add --no-cache tailscale >/dev/null
  rc-update add tailscale default >/dev/null 2>&1 || true
  rc-service tailscale start >/dev/null 2>&1 \
    || log_warn "tailscaled failed to start — check /var/log/tailscaled.log"
}

configure_tailscale_proxy() {
  if ! command -v tailscale >/dev/null 2>&1; then
    log_warn "tailscale CLI not found, skipping reverse-proxy setup."
    return 0
  fi

  local backend_state
  backend_state=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "unknown"')
  if [[ "$backend_state" != "Running" ]]; then
    if [[ -n "$TS_AUTHKEY" ]]; then
      log_info "Bringing Tailscale up with provided auth key..."
      tailscale up --authkey "$TS_AUTHKEY" --ssh --hostname "$KOMODO_HOSTNAME" \
        || log_warn "tailscale up failed — run it manually inside the VM."
    else
      log_warn "Tailscale not authenticated and TS_AUTHKEY was not supplied."
      log_warn "Finish setup with: tailscale up --ssh --hostname ${KOMODO_HOSTNAME}"
      log_warn "Then publish Komodo with: tailscale serve --bg --https=443 http://${KOMODO_LISTEN_ADDR}"
      return 0
    fi
  fi

  if tailscale serve status 2>/dev/null | grep -q "${KOMODO_LISTEN_ADDR}"; then
    log_info "Tailscale serve already publishes http://${KOMODO_LISTEN_ADDR}."
  else
    log_info "Publishing Komodo on the tailnet via 'tailscale serve' (HTTPS:443)..."
    tailscale serve --bg --https=443 "http://${KOMODO_LISTEN_ADDR}" \
      || log_warn "tailscale serve failed — enable HTTPS on your tailnet and retry."
  fi
}

# ============================================================
# Komodo — compose files in $KOMODO_DIR
# ============================================================

# Pulls the existing value of $1 out of compose.env (if any). Used so re-runs
# preserve the password and secrets generated the first time around.
read_env_var() {
  local key="$1"
  local env_file="${KOMODO_DIR}/compose.env"
  [[ -f "$env_file" ]] || return 0
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); gsub(/^"|"$/, ""); print; exit }' "$env_file"
}

# Reject the upstream Komodo example placeholders so a compose.env borrowed
# from komo.do docs is regenerated instead of "preserved" verbatim.
is_insecure_default() {
  case "$1" in
    ""|admin|a_random_secret|a_random_jwt_secret) return 0 ;;
    *) return 1 ;;
  esac
}

write_compose_files() {
  log_info "Provisioning ${KOMODO_DIR}..."
  mkdir -p "$KOMODO_DIR"
  chmod 750 "$KOMODO_DIR"

  # Reuse existing secrets if compose.env was written by a previous run.
  local db_password webhook_secret jwt_secret
  db_password="$(read_env_var KOMODO_DATABASE_PASSWORD || true)"
  webhook_secret="$(read_env_var KOMODO_WEBHOOK_SECRET || true)"
  jwt_secret="$(read_env_var KOMODO_JWT_SECRET || true)"

  if is_insecure_default "$db_password"; then
    db_password="$(gen_secret 24)"
    log_info "Generated KOMODO_DATABASE_PASSWORD."
  else
    log_info "Preserving existing KOMODO_DATABASE_PASSWORD from compose.env."
  fi
  if is_insecure_default "$webhook_secret"; then
    webhook_secret="$(gen_secret 32)"
    log_info "Generated KOMODO_WEBHOOK_SECRET."
  else
    log_info "Preserving existing KOMODO_WEBHOOK_SECRET from compose.env."
  fi
  if is_insecure_default "$jwt_secret"; then
    jwt_secret="$(gen_secret 32)"
    log_info "Generated KOMODO_JWT_SECRET."
  else
    log_info "Preserving existing KOMODO_JWT_SECRET from compose.env."
  fi

  # Stash the resolved values so the install summary can print them.
  KOMODO_DB_PASSWORD_RESOLVED="$db_password"
  KOMODO_WEBHOOK_SECRET_RESOLVED="$webhook_secret"
  KOMODO_JWT_SECRET_RESOLVED="$jwt_secret"

  # mongo.compose.yaml is upstream's reference (https://komo.do/docs/setup/mongo)
  # with one change: Core's host port is bound to ${KOMODO_LISTEN_ADDR} instead
  # of every interface, so only the loopback (and Tailscale serve) can reach it.
  cat > "${KOMODO_DIR}/mongo.compose.yaml" <<EOF
services:
  mongo:
    image: mongo
    labels:
      komodo.skip:
    command: --quiet --wiredTigerCacheSizeGB 0.25
    restart: unless-stopped
    volumes:
      - mongo-data:/data/db
      - mongo-config:/data/configdb
    environment:
      MONGO_INITDB_ROOT_USERNAME: \${KOMODO_DATABASE_USERNAME}
      MONGO_INITDB_ROOT_PASSWORD: \${KOMODO_DATABASE_PASSWORD}

  core:
    image: ghcr.io/moghtech/komodo-core:\${COMPOSE_KOMODO_IMAGE_TAG:-2}
    init: true
    restart: unless-stopped
    depends_on:
      - mongo
    ports:
      - ${KOMODO_LISTEN_ADDR}:9120
    env_file: ./compose.env
    environment:
      KOMODO_DATABASE_ADDRESS: mongo:27017
    volumes:
      - keys:/config/keys
      - \${COMPOSE_KOMODO_BACKUPS_PATH}:/backups

  periphery:
    image: ghcr.io/moghtech/komodo-periphery:\${COMPOSE_KOMODO_IMAGE_TAG:-2}
    init: true
    restart: unless-stopped
    depends_on:
      - core
    env_file: ./compose.env
    volumes:
      - keys:/config/keys
      - /var/run/docker.sock:/var/run/docker.sock
      - /proc:/proc
      - \${PERIPHERY_ROOT_DIRECTORY:-/etc/komodo}:\${PERIPHERY_ROOT_DIRECTORY:-/etc/komodo}

volumes:
  mongo-data:
  mongo-config:
  keys:
EOF

  # compose.env is upstream's reference file with the three secrets injected
  # and KOMODO_HOST set to the tailnet FQDN. Every other variable is left at
  # the upstream default — adjust by hand later if needed.
  cat > "${KOMODO_DIR}/compose.env" <<EOF
####################################
# Generated by infra-scripts/komodo #
####################################

COMPOSE_KOMODO_IMAGE_TAG="2"
COMPOSE_KOMODO_BACKUPS_PATH=/etc/komodo/backups

## DB credentials — password generated at install time, do not commit anywhere
KOMODO_DATABASE_USERNAME=admin
KOMODO_DATABASE_PASSWORD=${db_password}

TZ=Etc/UTC

#=-------------------------=#
#= Komodo Core Environment =#
#=-------------------------=#

## Used for Oauth / Webhook url suggestion — served via 'tailscale serve'.
KOMODO_HOST=${KOMODO_HOST}
KOMODO_TITLE=Komodo

KOMODO_PERIPHERY_PUBLIC_KEY=file:/config/keys/periphery.pub

KOMODO_LOCAL_AUTH=true
KOMODO_INIT_ADMIN_USERNAME=admin
KOMODO_INIT_ADMIN_PASSWORD=changeme

KOMODO_FIRST_SERVER_NAME=Local

KOMODO_DISABLE_CONFIRM_DIALOG=false
KOMODO_DISABLE_INIT_RESOURCES=false

## Secrets — generated at install time
KOMODO_WEBHOOK_SECRET=${webhook_secret}
KOMODO_JWT_SECRET=${jwt_secret}
KOMODO_JWT_TTL="1-day"

KOMODO_MONITORING_INTERVAL="15-sec"
KOMODO_RESOURCE_POLL_INTERVAL="1-hr"

KOMODO_DISABLE_USER_REGISTRATION=false
KOMODO_ENABLE_NEW_USERS=false
KOMODO_DISABLE_NON_ADMIN_CREATE=false
KOMODO_TRANSPARENT_MODE=false

KOMODO_OIDC_ENABLED=false
KOMODO_GITHUB_OAUTH_ENABLED=false
KOMODO_GOOGLE_OAUTH_ENABLED=false

KOMODO_AWS_ACCESS_KEY_ID=
KOMODO_AWS_SECRET_ACCESS_KEY=

KOMODO_LOGGING_PRETTY=false
KOMODO_PRETTY_STARTUP_CONFIG=false

#=------------------------------=#
#= Komodo Periphery Environment =#
#=------------------------------=#

PERIPHERY_CORE_ADDRESS=ws://core:9120
PERIPHERY_CONNECT_AS=\${KOMODO_FIRST_SERVER_NAME}
PERIPHERY_CORE_PUBLIC_KEYS=file:/config/keys/core.pub

PERIPHERY_ROOT_DIRECTORY=/etc/komodo

PERIPHERY_DISABLE_TERMINALS=false
PERIPHERY_DISABLE_CONTAINER_TERMINALS=false

PERIPHERY_INCLUDE_DISK_MOUNTS=/etc/hostname

PERIPHERY_LOGGING_PRETTY=false
PERIPHERY_PRETTY_STARTUP_CONFIG=false
EOF
  # Compose env contains the DB password + JWT/webhook secrets — keep readable
  # only by root.
  chmod 600 "${KOMODO_DIR}/compose.env"
}

bring_up_stack() {
  log_info "Pulling Komodo + MongoDB images..."
  (cd "$KOMODO_DIR" && docker compose --env-file ./compose.env -f mongo.compose.yaml pull) >/dev/null

  log_info "Starting the Komodo stack..."
  (cd "$KOMODO_DIR" && docker compose --env-file ./compose.env -f mongo.compose.yaml up -d) >/dev/null
}

# ============================================================
# Log hygiene
# ============================================================
configure_log_hygiene() {
  # Bound the journal-equivalent — Alpine uses OpenRC, so we cap Docker's
  # per-container logs via daemon.json (json-file driver, default).
  log_info "Capping per-container Docker log size..."
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
  # Reload so the cap applies to subsequent container starts. Existing
  # containers keep their previous log driver until recreated.
  rc-service docker reload >/dev/null 2>&1 \
    || rc-service docker restart >/dev/null 2>&1 || true
}

write_motd() {
  log_info "Configuring MOTD..."
  # Quoted heredoc: every variable in the body is resolved at login time, not
  # install time.
  cat > /etc/profile.d/00-komodo.sh <<'MOTD'
KOMODO_DIR="${KOMODO_DIR:-/opt/komodo}"

TS_FQDN=$(tailscale status --json 2>/dev/null | awk -F'"' '
    /"Self"/ { in_self=1 }
    in_self && /"DNSName"/ { gsub(/\.$/, "", $4); print $4; exit }
')
[ -z "$TS_FQDN" ] && TS_FQDN="$(hostname).ts.net"

# compose.env is root-only (chmod 600); when this MOTD runs as a non-root user
# the awk read returns empty, so fall back to the Tailscale-derived FQDN.
KOMODO_HOST=$(awk -F= '$1 == "KOMODO_HOST" { print $2; exit }' "${KOMODO_DIR}/compose.env" 2>/dev/null)
[ -z "$KOMODO_HOST" ] && KOMODO_HOST="https://${TS_FQDN}"

CORE_STATE=$(docker inspect -f '{{.State.Status}}' komodo-core-1 2>/dev/null || echo "missing")
PERI_STATE=$(docker inspect -f '{{.State.Status}}' komodo-periphery-1 2>/dev/null || echo "missing")
MONGO_STATE=$(docker inspect -f '{{.State.Status}}' komodo-mongo-1 2>/dev/null || echo "missing")

echo ""
echo " _  __                   _       "
echo "| |/ /___  _ __ ___   __| | ___  "
echo "| ' // _ \\| '_ \` _ \\ / _\` |/ _ \\ "
echo "| . \\ (_) | | | | | | (_| | (_) |"
echo "|_|\\_\\___/|_| |_| |_|\\__,_|\\___/ "
echo ""
echo "Komodo (Docker + MongoDB)"
echo "─────────────────────────────────────────"
echo "Access:"
echo "  • Local   : http://127.0.0.1:9120"
echo "  • Tailnet : ${KOMODO_HOST}"
echo ""
echo "Containers:"
echo "  • core      : ${CORE_STATE}"
echo "  • periphery : ${PERI_STATE}"
echo "  • mongo     : ${MONGO_STATE}"
echo ""
echo "Useful commands:"
echo "  cd ${KOMODO_DIR}"
echo "  docker compose --env-file compose.env -f mongo.compose.yaml ps"
echo "  docker compose --env-file compose.env -f mongo.compose.yaml logs -f core"
echo "  docker compose --env-file compose.env -f mongo.compose.yaml pull && \\"
echo "    docker compose --env-file compose.env -f mongo.compose.yaml up -d"
echo "─────────────────────────────────────────"
echo ""
MOTD
  chmod +x /etc/profile.d/00-komodo.sh
}

# ============================================================
# Main
# ============================================================
main() {
  require_root
  require_alpine

  log_info "=== Komodo — installation ==="

  # Base tooling for the rest of the script (jq is used to read tailscale status,
  # curl/ca-certificates for image pulls / future tailscale install).
  apk add --no-cache bash curl jq ca-certificates openssl >/dev/null

  install_docker
  install_tailscale
  write_compose_files
  bring_up_stack
  configure_log_hygiene
  configure_tailscale_proxy
  write_motd

  echo ""
  log_info "========================================="
  log_info "Komodo installation complete!"
  log_info "========================================="
  echo ""
  echo "  Local URL    : http://${KOMODO_LISTEN_ADDR}"
  echo "  Tailnet URL  : ${KOMODO_HOST}"
  echo "  Compose dir  : ${KOMODO_DIR}"
  echo ""
  echo "Initial admin (change immediately via the UI):"
  echo "  username : admin"
  echo "  password : changeme"
  echo ""
  echo "Generated secrets (also in ${KOMODO_DIR}/compose.env, root-only):"
  echo "  KOMODO_DATABASE_PASSWORD : ${KOMODO_DB_PASSWORD_RESOLVED}"
  echo "  KOMODO_WEBHOOK_SECRET    : ${KOMODO_WEBHOOK_SECRET_RESOLVED}"
  echo "  KOMODO_JWT_SECRET        : ${KOMODO_JWT_SECRET_RESOLVED}"
  echo ""
}

main "$@"
