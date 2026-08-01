#!/bin/bash
# install.sh - Automated deployment of Proxy Server with Tailscale + Traefik v3 + Fail2ban
# Usage: curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/proxy/install.sh | bash

set -euo pipefail

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Pre-flight checks
check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "Do not run as root directly. Use a user with sudo privileges."
        exit 1
    fi
    if ! sudo -v; then
        log_error "User must have sudo privileges."
        exit 1
    fi
}

check_debian() {
    if ! grep -qi debian /etc/os-release 2>/dev/null; then
        log_warn "This script is optimized for Debian. Continuing anyway..."
    fi
}

# Configuration variables (can be overridden via environment)
PROXY_HOSTNAME="${PROXY_HOSTNAME:-proxy}"
TRAEFIK_DIR="$HOME/traefik"

# ACME_EMAIL is required for Let's Encrypt certificate issuance notifications.
# Export it before running: export ACME_EMAIL=you@example.com
ACME_EMAIL="${ACME_EMAIL:-}"

# Optional: pre-authorize Tailscale non-interactively (recommended for curl|bash).
# Generate at https://login.tailscale.com/admin/settings/keys
TS_AUTHKEY="${TS_AUTHKEY:-}"

# rsyslog receiver for exposed services' logs (see "Configuring rsyslog" below).
RSYSLOG_PORT="${RSYSLOG_PORT:-5514}"
# Default 0.0.0.0 is fine: UFW's default-deny only opens 80/443 publicly, so
# this port is reachable exclusively over tailscale0 either way. Override to
# a specific tailnet IP to shrink the blast radius of log injection instead.
RSYSLOG_BIND_ADDR="${RSYSLOG_BIND_ADDR:-0.0.0.0}"

main() {
    log_info "=== Proxy Server Deployment (Traefik v3) ==="

    check_root
    check_debian

    # Prompt for ACME email if not set. Only attempt interactive prompt when a
    # TTY is available — when invoked via `curl … | bash`, stdin is the pipe
    # and reading from /dev/tty may also fail (e.g. non-interactive runners).
    if [[ -z "$ACME_EMAIL" ]]; then
        if [[ -r /dev/tty ]]; then
            log_warn "ACME_EMAIL is not set in the environment."
            read -rp "Enter your ACME email address: " ACME_EMAIL < /dev/tty || true
        fi
        if [[ -z "$ACME_EMAIL" ]]; then
            log_error "ACME_EMAIL is required. Export it before running:"
            log_error "  export ACME_EMAIL=you@example.com"
            exit 1
        fi
    fi

    if [[ "$(hostname)" != "$PROXY_HOSTNAME" ]]; then
        log_info "Setting hostname to: $PROXY_HOSTNAME"
        echo "$PROXY_HOSTNAME" | sudo tee /etc/hostname > /dev/null
        sudo hostnamectl set-hostname "$PROXY_HOSTNAME"
    else
        log_info "Hostname already set to $PROXY_HOSTNAME, skipping."
    fi

    log_info "Installing base packages..."
    sudo apt update -qq
    sudo apt install -y -qq vim ca-certificates curl gnupg lsb-release fail2ban unattended-upgrades ufw ethtool networkd-dispatcher rsyslog > /dev/null

    log_info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh

    log_info "Configuring sysctl for exit-node support..."
    echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-tailscale.conf > /dev/null
    echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf > /dev/null
    sudo sysctl -p /etc/sysctl.d/99-tailscale.conf > /dev/null

    log_info "Configuring ethtool for Tailscale UDP GRO forwarding..."
    # Determine the default-route interface and disable rx-gro-list / enable
    # rx-udp-gro-forwarding to avoid the Tailscale throughput warning.
    NETDEV=$(ip -o route show default | awk '{print $5; exit}')
    if [[ -z "$NETDEV" ]]; then
        log_error "Could not determine default network interface."
        exit 1
    fi
    sudo ethtool -K "$NETDEV" rx-udp-gro-forwarding on rx-gro-list off
    # Persist across reboots via networkd-dispatcher
    sudo mkdir -p /etc/networkd-dispatcher/routable.d
    printf '#!/bin/sh\nethtool -K %s rx-udp-gro-forwarding on rx-gro-list off\n' "$NETDEV" \
        | sudo tee /etc/networkd-dispatcher/routable.d/50-tailscale > /dev/null
    sudo chmod 755 /etc/networkd-dispatcher/routable.d/50-tailscale

    # Connect to Tailscale only if not already logged in (idempotent re-runs).
    if ! sudo tailscale status >/dev/null 2>&1; then
        log_info "Connecting to Tailscale..."
        if [[ -n "$TS_AUTHKEY" ]]; then
            sudo tailscale up --ssh --advertise-exit-node --authkey="$TS_AUTHKEY"
        else
            log_warn "TS_AUTHKEY not set — interactive browser auth required."
            sudo tailscale up --ssh --advertise-exit-node
        fi
    else
        log_info "Tailscale already connected, skipping."
    fi

    log_info "Installing Docker..."
    sudo mkdir -m 0755 -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update -qq
    sudo apt install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null

    log_info "Adding current user to docker group..."
    sudo usermod -aG docker "$USER"

    log_info "Configuring UFW firewall..."
    # Idempotent: only reset if our marker rules are absent. This preserves any
    # rules added later by the operator on re-runs.
    if ! sudo ufw status | grep -q "tailscale0"; then
        sudo ufw --force reset > /dev/null
        sudo ufw default deny incoming > /dev/null
        sudo ufw default allow outgoing > /dev/null
        # Allow HTTP/HTTPS from the public internet (handled by Traefik)
        sudo ufw allow 80/tcp > /dev/null
        sudo ufw allow 443/tcp > /dev/null
        # Allow all traffic on Tailscale interface (dashboard, metrics, SSH, admin — everything internal)
        sudo ufw allow in on tailscale0 > /dev/null
        # Port 22 is intentionally NOT opened publicly; Tailscale SSH covers management access
        sudo ufw --force enable > /dev/null
    else
        log_info "UFW already configured, skipping reset."
    fi

    log_info "Configuring Fail2ban for Traefik..."
    # Create the log file and fail2ban socket dir now so:
    #  - fail2ban can open the log file when the jail loads.
    #  - docker doesn't bind-mount /var/run/fail2ban as an empty dir if the
    #    exporter container starts before fail2ban writes its socket.
    sudo mkdir -p /var/log/traefik /var/run/fail2ban
    sudo chown "$USER":"$USER" /var/log/traefik
    sudo touch /var/log/traefik/access.log

    sudo tee /etc/fail2ban/filter.d/traefik.conf > /dev/null << 'EOF'
[Definition]
# Match JSON log lines where ClientHost is the offending IP and DownstreamStatus
# is an auth/abuse status (401, 403, 429) or a server error (5xx).
# Legitimate 404s on missing assets are excluded so dev traffic doesn't ban users.
# Two patterns cover both possible field orderings in the JSON.
failregex = ^.*"ClientHost":"<HOST>".*"DownstreamStatus":(401|403|429|5[0-9]{2})
            ^.*"DownstreamStatus":(401|403|429|5[0-9]{2}).*"ClientHost":"<HOST>"
ignoreregex =
EOF

    sudo tee /etc/fail2ban/jail.d/traefik.conf > /dev/null << 'EOF'
[traefik-auth]
enabled  = true
filter   = traefik
logpath  = /var/log/traefik/access.log
maxretry = 10
findtime = 5m
bantime  = 1h
action   = iptables-multiport[name=traefik, port="80,443", protocol=tcp]
EOF

    sudo systemctl restart fail2ban

    log_info "Configuring rsyslog receiver for exposed services..."
    # A fail2ban jail running inside a service's own LXC only ever sees this
    # proxy's tailnet IP as the source of connections, so it would end up
    # banning the proxy itself. Detection has to stay where the signal is
    # (the service's application log); banning has to happen here, at the
    # edge where public connections actually terminate. Services forward
    # their logs to this receiver over TCP; adding a new one is a matter of
    # dropping a 50-<service>.conf here (see proxy/README.md) — nothing else
    # to touch.
    #
    # 10- carries only the listener (module/input): rsyslog loads
    # /etc/rsyslog.d/*.conf in filename order, and rules within a ruleset
    # execute in the order they were loaded. A catch-all defined here would
    # run *before* any 50-<service>.conf's rules ever get a chance — every
    # message would double up into both the generic file and the
    # service-specific one. The catch-all instead lives in
    # 90-remote-fallback.conf (below, written after this block) so it loads
    # last, and a service's `stop` actually prevents fallthrough into it.
    sudo mkdir -p /var/log/remote
    sudo tee /etc/rsyslog.d/10-remote-receiver.conf > /dev/null << EOF
module(load="imtcp")

input(type="imtcp" port="${RSYSLOG_PORT}" address="${RSYSLOG_BIND_ADDR}" ruleset="remoteLogs")
EOF

    # Catch-all for anything a 50-<service>.conf doesn't claim (or before one
    # exists yet). Kept on the legacy $RuleSet/$template directives rather
    # than the modern ruleset(name=...){...} object: rsyslog rejects a named
    # ruleset declared via that object syntax more than once ("ruleset ...
    # specified more than once"), which would break the moment a
    # 50-<service>.conf tries to add its own rules to the same "remoteLogs"
    # ruleset — the entire point of this split. $RuleSet <name> is a context
    # selector, not a one-shot declaration, so any number of files can
    # reopen it to append rules.
    sudo tee /etc/rsyslog.d/90-remote-fallback.conf > /dev/null << 'EOF'
$RuleSet remoteLogs
$template RemoteLogPath,"/var/log/remote/%HOSTNAME%.log"
*.* ?RemoteLogPath
$RuleSet RSYSLOG_DefaultRuleset
EOF

    sudo tee /etc/logrotate.d/remote-logs > /dev/null << 'EOF'
/var/log/remote/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF

    sudo systemctl restart rsyslog

    log_info "Creating Traefik stack under $TRAEFIK_DIR..."
    mkdir -p "$TRAEFIK_DIR/conf.d"

    # acme.json must be 600 or Traefik refuses to use it
    touch "$TRAEFIK_DIR/acme.json"
    chmod 600 "$TRAEFIK_DIR/acme.json"

    # --- docker-compose.yml ---
    # SECURITY: The dashboard/API entrypoint is bound to 127.0.0.1 ONLY.
    # Combined with `api.insecure: true` in traefik.yml, the dashboard has no
    # authentication — it is only reachable via the host loopback and exposed
    # selectively over the tailnet through `tailscale serve`. DO NOT change
    # this port binding to 0.0.0.0 or any non-loopback address.
    cat > "$TRAEFIK_DIR/docker-compose.yml" << 'EOF'
services:
  traefik:
    image: traefik:v3
    container_name: traefik
    restart: unless-stopped
    dns:
      - 100.100.100.100
    ports:
      - "80:80"
      - "443:443"
      # MUST stay on 127.0.0.1: dashboard is unauthenticated (see traefik.yml).
      - "127.0.0.1:8080:8080"
    volumes:
      - ./traefik.yml:/etc/traefik/traefik.yml:ro
      - ./conf.d:/etc/traefik/conf.d:ro
      - ./acme.json:/acme.json
      - /var/log/traefik:/var/log/traefik
      - /etc/localtime:/etc/localtime:ro

  fail2ban-exporter:
    image: registry.gitlab.com/hctrdev/fail2ban-prometheus-exporter:latest
    container_name: fail2ban-exporter
    restart: unless-stopped
    user: root
    ports:
      # Metrics reachable only via Tailscale (127.0.0.1 binding + UFW blocks public access)
      - "127.0.0.1:9191:9191"
    volumes:
      # Mount the directory, not the socket file: avoids Docker creating a directory
      # at the path when fail2ban is briefly down and recreating its socket.
      - /var/run/fail2ban:/var/run/fail2ban
EOF

    # --- traefik.yml (static config) ---
    # Unquoted EOF: ${ACME_EMAIL} must expand at write time into the static config.
    cat > "$TRAEFIK_DIR/traefik.yml" << EOF
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https

  websecure:
    address: ":443"

  traefik:
    address: ":8080"

certificatesResolvers:
  letsencrypt:
    acme:
      email: "${ACME_EMAIL}"
      storage: /acme.json
      httpChallenge:
        entryPoint: web

providers:
  file:
    directory: /etc/traefik/conf.d
    watch: true

metrics:
  prometheus:
    addEntryPointsLabels: true
    addServicesLabels: true
    addRoutersLabels: true
    entryPoint: traefik

api:
  dashboard: true
  # insecure exposes the dashboard on the :8080 entrypoint without auth.
  # This is acceptable ONLY because docker-compose.yml binds 8080 to 127.0.0.1.
  # Public reach requires going through `tailscale serve` (tailnet-authenticated).
  insecure: true

accessLog:
  filePath: /var/log/traefik/access.log
  format: json
EOF

    # --- conf.d/gitea.yml (dynamic config) ---
    cat > "$TRAEFIK_DIR/conf.d/gitea.yml" << 'EOF'
http:
  routers:
    gitea:
      rule: "Host(`gitea.arnodo.fr`)"
      entryPoints:
        - websecure
      service: gitea
      tls:
        certResolver: letsencrypt

  services:
    gitea:
      loadBalancer:
        servers:
          - url: "http://gitea.taila5ad8.ts.net:3000"
EOF

    log_info "Starting Traefik stack..."
    # Use sg to apply the docker group without requiring a re-login.
    # cd into the dir so paths inside the command don't break on spaces in $HOME.
    (cd "$TRAEFIK_DIR" && sg docker -c "docker compose up -d")

    # Idempotent: only register the serve mapping if it isn't already present.
    # Use --json (stable contract) and capture stdout+stderr so any help/error
    # output on older tailscale builds doesn't leak to the user's terminal.
    if ! sudo tailscale serve status --json 2>&1 | grep -q '"127.0.0.1:8080"'; then
        log_info "Exposing Traefik dashboard via Tailscale serve..."
        sudo tailscale serve --bg http://localhost:8080
    else
        log_info "Tailscale serve already configured for dashboard, skipping."
    fi

    log_info "Configuring MOTD..."
    # /etc/profile.d/ runs for every interactive login shell regardless of the SSH
    # implementation (works for both Tailscale SSH and regular OpenSSH).
    cat << 'MOTD' | sudo tee /etc/profile.d/00-proxy.sh > /dev/null
TS_FQDN=$(tailscale status --json 2>/dev/null | awk -F'"' '
    /"Self"/ { in_self=1 }
    in_self && /"DNSName"/ { gsub(/\.$/, "", $4); print $4; exit }
')
[[ -z "$TS_FQDN" ]] && TS_FQDN="$(hostname).ts.net"

echo ""
echo " ____  ____   _____  ____   __"
echo "|  _ \|  _ \ / _ \ \/ /\ \ / /"
echo "| |_) | |_) | | | \  /  \ V /"
echo "|  __/|  _ <| |_| /  \   | |"
echo "|_|   |_| \_\\___/_/\_\  |_|"
echo ""
echo "Traefik v3 Reverse Proxy"
echo "─────────────────────────────────────────"
echo "Access:"
echo "  • Dashboard : https://${TS_FQDN} (Tailscale)"
echo "  • HTTP/HTTPS: Public ports 80/443"
echo ""
echo "Services:"
docker ps --format '  • {{.Names}} : {{.Status}}' 2>/dev/null || echo "  Docker not running"
echo ""
echo "Useful commands:"
echo "  cd ~/traefik && docker compose logs -f"
echo "  sudo tailscale serve status"
echo "─────────────────────────────────────────"
echo ""
MOTD

    TS_FQDN=$(tailscale status --json 2>/dev/null | awk -F'"' '
        /"Self"/ { in_self=1 }
        in_self && /"DNSName"/ { gsub(/\.$/, "", $4); print $4; exit }
    ' || echo "${PROXY_HOSTNAME}.ts.net")

    echo ""
    log_info "=========================================="
    log_info "Deployment complete!"
    log_info "=========================================="
    echo ""
    echo "Traefik dashboard : https://${TS_FQDN}"
    echo "Stack directory   : $TRAEFIK_DIR"
    echo ""
    echo "Note: Approve exit-node in Tailscale admin console if needed."
    echo "Note: Fail2ban is running on the host; fail2ban-exporter exposes"
    echo "      metrics on port 9191 (Tailscale-only, not public)."
    echo ""
}

main "$@"
