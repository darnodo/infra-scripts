#!/bin/bash
# install.sh - Gitea: LXC creation, installation & update
# Usage:
#   From Proxmox host : bash -c "$(curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/gitea/install.sh)"
#   From inside LXC   : bash /root/install.sh   (updates packages + app.ini)
#
# Single entrypoint, three automatic modes:
#   1. Proxmox host, no existing container  -> create LXC + install Gitea
#   2. Proxmox host, container already present -> update packages + app.ini
#   3. Inside an LXC                         -> install if missing, otherwise update
#
# Installed via `apk add gitea gitea-openrc` rather than the upstream release
# binary: dl.gitea.com ships glibc/CGO-linked binaries, a bad fit for musl.
# Alpine packages a native musl build in community (verified present on the
# 3.22 template as of writing; check_gitea_channel() re-verifies this on every
# install rather than trusting that to stay true).

set -euo pipefail

# --- Config (override via environment) ---
CTID="${CTID:-}"
HOSTNAME_LXC="${GITEA_HOSTNAME:-gitea}"
TEMPLATE="${TEMPLATE:-}"                          # auto-detected when empty
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
CORES="${CORES:-2}"
RAM="${RAM:-2048}"
DISK="${DISK:-16}"
BRIDGE="${BRIDGE:-vmbr0}"
LXC_TAG="${LXC_TAG:-gitea}"                       # stable identifier for the container
# SCRIPT_URL is what the host-side flow pipes into the LXC. Override it when
# testing from a non-main branch, e.g.
#   SCRIPT_URL="https://gitea.arnodo.fr/.../branch/feat/gitea-lxc/gitea/install.sh"
SCRIPT_URL="${SCRIPT_URL:-https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/gitea/install.sh}"
# Optional: pre-authorise the LXC's Tailscale non-interactively.
# Generate at https://login.tailscale.com/admin/settings/keys
TS_AUTHKEY="${TS_AUTHKEY:-}"

# --- app.ini (managed exclusively via ini_set, see configure_app_ini) ---
GITEA_DOMAIN="${GITEA_DOMAIN:-gitea.arnodo.fr}"                 # public domain
GITEA_ROOT_URL="${GITEA_ROOT_URL:-https://${GITEA_DOMAIN}/}"    # public URL, NOT the tailnet URL
GITEA_HTTP_ADDR="${GITEA_HTTP_ADDR:-127.0.0.1}"                 # loopback; tailscale serve fronts it
GITEA_HTTP_PORT="${GITEA_HTTP_PORT:-3000}"
# Hop count between the client and this instance. Traefik + `tailscale serve`
# is the assumed chain (2 hops) — validate empirically per gitea/README.md
# before relying on the resulting client IP for the fail2ban jail in #21.
GITEA_REVERSE_PROXY_LIMIT="${GITEA_REVERSE_PROXY_LIMIT:-2}"
# Must never be "*" (CVE-2026-20896). 100.64.0.0/10 is Tailscale's CGNAT range.
GITEA_TRUSTED_PROXIES="${GITEA_TRUSTED_PROXIES:-127.0.0.0/8,::1/128,100.64.0.0/10}"
# Prometheus scrape token. Generated on first install if left unset; once set
# in app.ini it is never regenerated (see setup_metrics_token).
GITEA_METRICS_TOKEN="${GITEA_METRICS_TOKEN:-}"

# --- Admin account (created once; see create_admin_user) ---
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-admin}"
GITEA_ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-admin@${GITEA_DOMAIN}}"
GITEA_ADMIN_PASSWORD="${GITEA_ADMIN_PASSWORD:-}"                # generated if unset

# --- rsyslog forwarding to the proxy's receiver (see proxy #20) ---
SYSLOG_TARGET="${SYSLOG_TARGET:-proxy.taila5ad8.ts.net}"
SYSLOG_PORT="${SYSLOG_PORT:-5514}"

# --- Fixed paths (Alpine package layout; not meant to be overridden) ---
APP_INI="/etc/gitea/app.ini"
GITEA_WORK_DIR="/var/lib/gitea"
GITEA_LOG_DIR="/var/log/gitea"

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
# Load shared helpers (lib/common.sh: detect_latest_alpine_template,
# enable_tty1_autologin, find_existing_lxc, refresh_os_packages, ini_set).
#
# Same reasoning as openbao/install.sh and gitea-runner/install.sh: a local
# checkout has the file on disk right next to us, but the documented curl
# one-liner (host or piped into `pct exec` inside the LXC) has no
# BASH_SOURCE path worth trusting, so fall back to fetching lib/common.sh
# over HTTP next to SCRIPT_URL. The LXC already needs outbound network to
# curl this very script and to apk-install gitea, so this adds no new
# failure mode.
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)"
LIB_COMMON_URL="$(dirname "$(dirname "$SCRIPT_URL")")/lib/common.sh"
if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/../lib/common.sh" ]]; then
  source "${SCRIPT_DIR}/../lib/common.sh"
else
  # shellcheck source=/dev/null
  source <(curl -fsSL "$LIB_COMMON_URL")
fi

# `source <(curl ...)` swallows curl failures: an empty stream still makes
# `source` return 0, so a 404/network error would otherwise only surface
# later as a confusing "command not found" for ini_set et al. Fail loudly
# here instead, with the URL that was tried.
if ! declare -F ini_set >/dev/null; then
  log_error "Failed to load lib/common.sh (tried: ${LIB_COMMON_URL})."
  exit 1
fi

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    log_error "This script must be run as root (current uid: $(id -u))."
    log_error "On Proxmox, launch it from the host shell or via the Web UI shell, both of which run as root."
    exit 1
  fi
}

# ============================================================
# Refuse to install from edge/community: acceptable for a throwaway test
# box, not for a production instance. Re-checked on every install rather
# than assumed, since the issue this script implements only verified this
# against Alpine 3.22 at write time.
# ============================================================
check_gitea_channel() {
  local repo_line
  repo_line=$(apk policy gitea 2>/dev/null | awk '/^[[:space:]]+https?:\/\//{print; exit}')

  if [[ -z "$repo_line" ]]; then
    log_error "Package 'gitea' not found in the configured Alpine repositories."
    log_error "This Alpine release may not package Gitea — see https://pkgs.alpinelinux.org/packages?name=gitea"
    exit 1
  fi
  if [[ "$repo_line" == *"/edge/"* ]]; then
    log_error "gitea is only available via edge/community on this Alpine release."
    log_error "Refusing to install from edge on what should be a production instance."
    log_error "Pin an Alpine template where gitea has reached a stable release (TEMPLATE=...),"
    log_error "or comment on issue #19 with what you found so the assumption can be revisited."
    exit 1
  fi
  log_info "gitea package available via:${repo_line}"
}

# ============================================================
# Merge app.ini to the keys this script owns via ini_set (#18). Never a
# heredoc overwrite: the file ships with sane Alpine-package defaults for
# everything we don't list here, and a rejoué script must only touch its
# own keys (see lib/common.sh's ini_set contract).
# ============================================================
configure_app_ini() {
  log_info "Configuring ${APP_INI}..."

  ini_set "$APP_INI" server PROTOCOL http
  ini_set "$APP_INI" server HTTP_ADDR "$GITEA_HTTP_ADDR"
  ini_set "$APP_INI" server HTTP_PORT "$GITEA_HTTP_PORT"
  ini_set "$APP_INI" server DOMAIN "$GITEA_DOMAIN"
  ini_set "$APP_INI" server ROOT_URL "$GITEA_ROOT_URL"
  ini_set "$APP_INI" server DISABLE_SSH true

  # INSTALL_LOCK must land before the service's first start, or the web
  # installer is exposed on the public domain and the first visitor becomes
  # admin. configure_app_ini() always runs before rc-service gitea start in
  # install_inside_lxc — do not reorder that.
  ini_set "$APP_INI" security INSTALL_LOCK true
  ini_set "$APP_INI" security REVERSE_PROXY_LIMIT "$GITEA_REVERSE_PROXY_LIMIT"
  ini_set "$APP_INI" security REVERSE_PROXY_TRUSTED_PROXIES "$GITEA_TRUSTED_PROXIES"

  ini_set "$APP_INI" service DISABLE_REGISTRATION true
  ini_set "$APP_INI" service REQUIRE_CAPTCHA_FOR_LOGIN true
  ini_set "$APP_INI" service ENABLE_CAPTCHA true

  ini_set "$APP_INI" log MODE file
  ini_set "$APP_INI" log LEVEL info
  ini_set "$APP_INI" log ROOT_PATH "$GITEA_LOG_DIR"
  # ANSI color codes in gitea.log would break the <HOST> match in the
  # fail2ban filter added by #21.
  ini_set "$APP_INI" log COLORIZE false

  ini_set "$APP_INI" actions ENABLED true

  ini_set "$APP_INI" database DB_TYPE sqlite3
  ini_set "$APP_INI" database PATH "${GITEA_WORK_DIR}/data/gitea.db"

  setup_metrics_token
}

# ============================================================
# Metrics token: generate once, then leave alone. A rejeu that regenerated
# it would silently break the Prometheus scrape config.
# ============================================================
setup_metrics_token() {
  local current_token
  current_token=$(awk '
    /^\[metrics\]/ { insec = 1; next }
    /^\[/ { insec = 0 }
    insec && match($0, /^[ \t]*TOKEN[ \t]*=/) {
      sub(/^[^=]*=[ \t]*/, "")
      print
      exit
    }
  ' "$APP_INI" 2>/dev/null || true)

  local token="${current_token:-${GITEA_METRICS_TOKEN}}"
  if [[ -z "$token" ]]; then
    token=$(openssl rand -hex 32)
    log_info "Generated new Prometheus metrics token (shown once, save it now):"
    log_info "  ${token}"
  fi

  ini_set "$APP_INI" metrics ENABLED true
  ini_set "$APP_INI" metrics TOKEN "$token"
  ini_set "$APP_INI" metrics ENABLED_ISSUE_BY_REPOSITORY true
  ini_set "$APP_INI" metrics ENABLED_ISSUE_BY_LABEL true
}

# ============================================================
# Block until Gitea answers its health endpoint. Both create_admin_user()
# (DB must be migrated) and configure_rsyslog_forwarder() (log file must
# exist) depend on the service actually being up.
# ============================================================
wait_for_gitea_ready() {
  local tries=0
  until curl -fsS "http://${GITEA_HTTP_ADDR}:${GITEA_HTTP_PORT}/api/healthz" >/dev/null 2>&1; do
    tries=$((tries + 1))
    if (( tries > 30 )); then
      log_error "Gitea did not become healthy within 30s."
      log_error "Check: rc-service gitea status && tail -50 ${GITEA_LOG_DIR}/gitea.log"
      exit 1
    fi
    sleep 1
  done
}

# ============================================================
# Idempotent admin creation: the DB only exists once Gitea has started at
# least once (its CLI does not migrate on its own), so this must run after
# wait_for_gitea_ready(). Skips creation if any admin already exists,
# regardless of username, so a rerun never touches an operator-renamed or
# operator-created admin account.
# ============================================================
create_admin_user() {
  local existing
  existing=$(su -s /bin/sh gitea -c \
    "gitea admin user list --admin --config '${APP_INI}' --work-path '${GITEA_WORK_DIR}'" \
    2>/dev/null | tail -n +2 | grep -c . || true)

  if [[ "${existing:-0}" -gt 0 ]]; then
    log_info "Admin account already present, skipping creation."
    return 0
  fi

  local password="${GITEA_ADMIN_PASSWORD:-$(openssl rand -base64 24)}"
  log_info "Creating admin account '${GITEA_ADMIN_USER}'..."
  su -s /bin/sh gitea -c \
    "gitea admin user create --admin --username '${GITEA_ADMIN_USER}' --email '${GITEA_ADMIN_EMAIL}' --password '${password}' --must-change-password=true --config '${APP_INI}' --work-path '${GITEA_WORK_DIR}'"

  echo ""
  log_info "Admin account created (shown once, save it now):"
  log_info "  Username: ${GITEA_ADMIN_USER}"
  log_info "  Password: ${password}"
  echo ""
}

# ============================================================
# Forward gitea.log to the proxy's generic rsyslog receiver (#20), tagged
# "gitea" so the proxy can route it into its own file (#21) for a
# proxy-side fail2ban jail — a jail running in this LXC would only ever
# see the proxy's own tailnet IP as the source and end up banning the
# proxy. Scoped to $programname == "gitea" so the LXC's own local syslog
# traffic (cron, auth, rsyslog's startup messages) is never forwarded.
# ============================================================
configure_rsyslog_forwarder() {
  log_info "Configuring rsyslog forwarding to ${SYSLOG_TARGET}:${SYSLOG_PORT}..."
  apk add --no-cache rsyslog >/dev/null
  mkdir -p /etc/rsyslog.d

  cat > /etc/rsyslog.d/50-gitea-forward.conf << EOF
module(load="imfile")

input(type="imfile"
      File="${GITEA_LOG_DIR}/gitea.log"
      Tag="gitea"
      Severity="info"
      Facility="local0")

if \$programname == "gitea" then {
    action(type="omfwd" target="${SYSLOG_TARGET}" port="${SYSLOG_PORT}" protocol="tcp")
    stop
}
EOF

  rc-update add rsyslog default >/dev/null 2>&1 || true
  rc-service rsyslog status >/dev/null 2>&1 && rc-service rsyslog stop
  rc-service rsyslog start
}

# ============================================================
# Reusable: bring Tailscale up and publish Gitea on the tailnet.
# Idempotent: re-running is a no-op once Tailscale is logged in and the
# serve mapping is already in place. Mirrors openbao/install.sh's helper
# of the same name.
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
      log_info "Bringing Tailscale up with provided auth key..."
      tailscale up --authkey "$TS_AUTHKEY" --ssh --hostname "$HOSTNAME_LXC" \
        || log_warn "tailscale up failed — run it manually inside the LXC."
    else
      log_warn "Tailscale not authenticated and TS_AUTHKEY was not supplied."
      log_warn "Finish setup inside the LXC with: tailscale up --ssh"
      log_warn "Then publish Gitea with: tailscale serve --bg --https=443 http://${GITEA_HTTP_ADDR}:${GITEA_HTTP_PORT}"
      return 0
    fi
  fi

  if tailscale serve status 2>/dev/null | grep -q "${GITEA_HTTP_ADDR}:${GITEA_HTTP_PORT}"; then
    log_info "Tailscale serve already publishes http://${GITEA_HTTP_ADDR}:${GITEA_HTTP_PORT}."
  else
    log_info "Publishing Gitea on the tailnet via 'tailscale serve' (HTTPS:443)..."
    tailscale serve --bg --https=443 "http://${GITEA_HTTP_ADDR}:${GITEA_HTTP_PORT}" \
      || log_warn "tailscale serve failed — enable HTTPS on your tailnet and retry."
  fi

  local fqdn
  fqdn=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // ""' | sed 's/\.$//')
  if [[ -n "$fqdn" ]]; then
    log_info "Gitea reachable on the tailnet at: https://${fqdn}"
  fi
}

# ============================================================
# Proxmox-host helpers
# ============================================================
allocate_ctid() {
  pvesh get /cluster/nextid 2>/dev/null \
    || pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
       | jq '[.[].vmid] | max + 1' \
    || echo 100
}

# Inject the script into the container and execute it in the requested mode.
# Forwards the runtime configuration the inner invocation needs to reproduce
# what the user requested on the host (mirrors openbao/gitea-runner's
# exec_in_lxc).
exec_in_lxc() {
  local ctid="$1"
  local mode="$2"   # --install or --update

  pct exec "$ctid" -- sh -c "apk add --no-cache bash curl jq ca-certificates >/dev/null 2>&1"
  curl -fsSL "$SCRIPT_URL" \
    | pct exec "$ctid" -- env \
        SCRIPT_URL="$SCRIPT_URL" \
        GITEA_HOSTNAME="$HOSTNAME_LXC" \
        GITEA_DOMAIN="$GITEA_DOMAIN" \
        GITEA_ROOT_URL="$GITEA_ROOT_URL" \
        GITEA_HTTP_ADDR="$GITEA_HTTP_ADDR" \
        GITEA_HTTP_PORT="$GITEA_HTTP_PORT" \
        GITEA_REVERSE_PROXY_LIMIT="$GITEA_REVERSE_PROXY_LIMIT" \
        GITEA_TRUSTED_PROXIES="$GITEA_TRUSTED_PROXIES" \
        GITEA_METRICS_TOKEN="$GITEA_METRICS_TOKEN" \
        GITEA_ADMIN_USER="$GITEA_ADMIN_USER" \
        GITEA_ADMIN_EMAIL="$GITEA_ADMIN_EMAIL" \
        GITEA_ADMIN_PASSWORD="$GITEA_ADMIN_PASSWORD" \
        SYSLOG_TARGET="$SYSLOG_TARGET" \
        SYSLOG_PORT="$SYSLOG_PORT" \
        TS_AUTHKEY="$TS_AUTHKEY" \
        bash -s -- "$mode"
}

# ============================================================
# MODE: Proxmox host — create LXC + install
# ============================================================
create_lxc() {
  log_info "=== Gitea — LXC creation ==="

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
  echo "IMPORTANT — do not deploy the fail2ban jail (#21) yet. Validate the"
  echo "X-Forwarded-For chain first (see gitea/README.md):"
  echo "  1. Trigger a failed login from a known external IP."
  echo "  2. pct enter ${CTID} && grep 'Failed authentication' ${GITEA_LOG_DIR}/gitea.log | tail -1"
  echo "  3. Only once that line shows the real client IP, deploy #20 then #21."
  echo ""
}

# ============================================================
# MODE: Proxmox host — update existing LXC
# ============================================================
update_lxc() {
  local ctid="$1"
  log_info "=== Gitea — updating existing LXC ${ctid} ==="

  if ! pct status "$ctid" | grep -q running; then
    log_info "Starting LXC ${ctid}..."
    pct start "$ctid"
    sleep 3
  fi

  log_info "Updating LXC ${ctid}..."
  exec_in_lxc "$ctid" "--update"

  log_info "Update of LXC ${ctid} complete."
}

# ============================================================
# MODE: inside LXC — fresh install
# ============================================================
install_inside_lxc() {
  log_info "=== Gitea — installation ==="

  log_info "Updating package index..."
  apk update >/dev/null

  check_gitea_channel

  log_info "Installing dependencies..."
  apk add --no-cache bash curl jq ca-certificates openssl gcompat openrc tailscale >/dev/null

  log_info "Installing gitea + gitea-openrc..."
  apk add --no-cache gitea gitea-openrc >/dev/null

  log_info "Enabling tailscaled..."
  rc-update add tailscale default >/dev/null 2>&1 || true
  rc-service tailscale start >/dev/null 2>&1 || log_warn "tailscaled failed to start (is /dev/net/tun mapped into the LXC?)"

  configure_app_ini

  log_info "Starting gitea service..."
  rc-update add gitea default >/dev/null 2>&1 || true
  rc-service gitea status >/dev/null 2>&1 && rc-service gitea stop
  rc-service gitea start

  wait_for_gitea_ready
  create_admin_user

  configure_rsyslog_forwarder

  log_info "Configuring logrotate for ${GITEA_LOG_DIR}/gitea.log..."
  apk add --no-cache logrotate >/dev/null
  cat > /etc/logrotate.d/gitea <<EOF
${GITEA_LOG_DIR}/gitea.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF
  ln -sf /usr/sbin/logrotate /etc/periodic/daily/logrotate 2>/dev/null || true

  enable_tty1_autologin

  configure_tailscale_proxy

  log_info "Configuring MOTD..."
  # /etc/profile.d/ runs for every interactive login shell — works for both
  # the auto-login tty and Tailscale SSH. Quoted heredoc: every variable is
  # resolved at login time, not at install time; the two __GITEA_*__
  # markers below are the only install-time values, substituted after the fact.
  cat > /etc/profile.d/00-gitea.sh <<'MOTD'
TS_FQDN=$(tailscale status --json 2>/dev/null | awk -F'"' '
    /"Self"/ { in_self=1 }
    in_self && /"DNSName"/ { gsub(/\.$/, "", $4); print $4; exit }
')
[[ -z "$TS_FQDN" ]] && TS_FQDN="$(hostname).ts.net"

GITEA_VERSION=$(apk list -I 2>/dev/null | awk '/^gitea-[0-9]/{print $1; exit}' | sed 's/^gitea-//')
[[ -z "$GITEA_VERSION" ]] && GITEA_VERSION="unknown"

if rc-service gitea status >/dev/null 2>&1; then
    SVC_STATE="running"
else
    SVC_STATE="stopped"
fi

echo ""
echo " ____ _ _            "
echo "/ ___(_) |_ ___  __ _ "
echo "| |  _| | __/ _ \/ _\` |"
echo "| |_| | | ||  __/ (_| |"
echo "\____|_|\__\___|\__,_|"
echo ""
echo "Gitea (${GITEA_VERSION})"
echo "─────────────────────────────────────────"
echo "Access:"
echo "  • Tailnet : https://${TS_FQDN}"
echo "  • Public  : __GITEA_ROOT_URL__"
echo "  • Service : ${SVC_STATE}"
echo ""
echo "Useful commands:"
echo "  rc-service gitea status"
echo "  tail -f __GITEA_LOG_DIR__/gitea.log"
echo "─────────────────────────────────────────"
echo ""
MOTD
  sed -i "s#__GITEA_ROOT_URL__#${GITEA_ROOT_URL}#; s#__GITEA_LOG_DIR__#${GITEA_LOG_DIR}#" /etc/profile.d/00-gitea.sh
  chmod +x /etc/profile.d/00-gitea.sh

  log_info "Cleaning up..."
  rm -rf /var/cache/apk/*

  echo ""
  log_info "========================================="
  log_info "Gitea installation complete!"
  log_info "========================================="
  echo ""
  echo "  Public URL : ${GITEA_ROOT_URL}"
  echo ""
  echo "IMPORTANT — do not deploy the fail2ban jail (#21) yet. Validate the"
  echo "X-Forwarded-For chain first (see gitea/README.md):"
  echo "  grep 'Failed authentication' ${GITEA_LOG_DIR}/gitea.log | tail -1"
  echo ""
}

# ============================================================
# MODE: inside LXC — update only
# ============================================================
update_inside_lxc() {
  log_info "=== Gitea — update ==="

  # refresh_os_packages() runs an unscoped `apk update && apk upgrade`,
  # which already brings gitea/gitea-openrc to the latest available build —
  # no separate `apk upgrade gitea` call needed.
  refresh_os_packages

  configure_app_ini

  rc-service gitea status >/dev/null 2>&1 && rc-service gitea stop
  rc-service gitea start
  wait_for_gitea_ready

  configure_rsyslog_forwarder
  configure_tailscale_proxy

  log_info "Gitea version: $(apk list -I 2>/dev/null | awk '/^gitea-[0-9]/{print $1; exit}')"
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
      log_info "Found existing Gitea LXC (CTID ${existing}, hostname/tag match) — switching to update mode."
      update_lxc "$existing"
    else
      create_lxc
    fi
  else
    # Inside a container (no Proxmox tooling)
    require_root
    if command -v gitea >/dev/null 2>&1; then
      update_inside_lxc
    else
      install_inside_lxc
    fi
  fi
}

main "$@"
