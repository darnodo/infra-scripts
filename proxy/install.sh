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
HOSTNAME="${PROXY_HOSTNAME:-proxy}"
TRAEFIK_DIR="$HOME/traefik"
TIMEZONE="${TZ:-Europe/Paris}"

# INFOMANIAK_ACCESS_TOKEN must be set in the environment or will be prompted.
# WARNING: Without this token, Traefik cannot issue certificates via DNS challenge.
# Export it before running: export INFOMANIAK_ACCESS_TOKEN=your_token_here
INFOMANIAK_ACCESS_TOKEN="${INFOMANIAK_ACCESS_TOKEN:-}"

main() {
    log_info "=== Proxy Server Deployment (Traefik v3) ==="

    check_root
    check_debian

    # Prompt for token if not set
    if [[ -z "$INFOMANIAK_ACCESS_TOKEN" ]]; then
        log_warn "INFOMANIAK_ACCESS_TOKEN is not set in the environment."
        read -rsp "Enter your Infomaniak API token: " INFOMANIAK_ACCESS_TOKEN
        echo
        if [[ -z "$INFOMANIAK_ACCESS_TOKEN" ]]; then
            log_error "Token is required for DNS challenge certificate issuance. Aborting."
            exit 1
        fi
    fi

    log_info "Setting hostname to: $HOSTNAME"
    echo "$HOSTNAME" | sudo tee /etc/hostname > /dev/null
    sudo hostnamectl set-hostname "$HOSTNAME"

    log_info "Installing base packages..."
    sudo apt update -qq
    sudo apt install -y -qq vim ca-certificates curl gnupg lsb-release fail2ban unattended-upgrades at ufw > /dev/null

    log_info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh

    log_info "Connecting to Tailscale..."
    sudo tailscale up --ssh --advertise-exit-node

    log_info "Configuring sysctl for exit-node support..."
    echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-tailscale.conf > /dev/null
    echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf > /dev/null
    sudo sysctl -p /etc/sysctl.d/99-tailscale.conf > /dev/null

    log_info "Installing Docker..."
    sudo mkdir -m 0755 -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update -qq
    sudo apt install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null

    log_info "Adding current user to docker group..."
    sudo usermod -aG docker "$USER"

    log_info "Configuring UFW firewall..."
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

    log_info "Creating Traefik stack under $TRAEFIK_DIR..."
    mkdir -p "$TRAEFIK_DIR/conf.d"

    # acme.json must be 600 or Traefik refuses to use it
    touch "$TRAEFIK_DIR/acme.json"
    chmod 600 "$TRAEFIK_DIR/acme.json"

    # Host log directory (mounted into container so Fail2ban can parse access logs)
    sudo mkdir -p /var/log/traefik
    sudo chown "$USER":"$USER" /var/log/traefik

    # Write .env so the token survives reboots without embedding it in compose
    cat > "$TRAEFIK_DIR/.env" << EOF
INFOMANIAK_ACCESS_TOKEN=${INFOMANIAK_ACCESS_TOKEN}
EOF
    chmod 600 "$TRAEFIK_DIR/.env"

    # --- docker-compose.yml ---
    cat > "$TRAEFIK_DIR/docker-compose.yml" << 'EOF'
services:
  traefik:
    image: traefik:v3
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      # Dashboard bound to localhost only; exposed via Tailscale serve
      - "127.0.0.1:8080:8080"
    volumes:
      - ./traefik.yml:/etc/traefik/traefik.yml:ro
      - ./conf.d:/etc/traefik/conf.d:ro
      - ./acme.json:/acme.json
      - /var/log/traefik:/var/log/traefik
      - /etc/localtime:/etc/localtime:ro
    environment:
      - INFOMANIAK_ACCESS_TOKEN=${INFOMANIAK_ACCESS_TOKEN}

  fail2ban-exporter:
    image: hectorjsmith/fail2ban-prometheus-exporter:latest
    container_name: fail2ban-exporter
    restart: unless-stopped
    ports:
      # Metrics reachable only via Tailscale (127.0.0.1 binding + UFW blocks public access)
      - "127.0.0.1:9191:9191"
    volumes:
      - /var/run/fail2ban/fail2ban.sock:/var/run/fail2ban/fail2ban.sock
EOF

    # --- traefik.yml (static config) ---
    cat > "$TRAEFIK_DIR/traefik.yml" << 'EOF'
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
  infomaniak:
    acme:
      storage: /acme.json
      dnsChallenge:
        provider: infomaniak

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
        certResolver: infomaniak

  services:
    gitea:
      loadBalancer:
        servers:
          - url: "http://gitea.taila5ad8.ts.net:3000"
EOF

    log_info "Starting Traefik stack..."
    # Use sg to apply the docker group without requiring a re-login
    sg docker -c "docker compose -f $TRAEFIK_DIR/docker-compose.yml up -d"

    log_info "Exposing Traefik dashboard via Tailscale serve..."
    sudo tailscale serve --bg http://localhost:8080

    log_info "Configuring MOTD..."
    sudo chmod -x /etc/update-motd.d/* 2>/dev/null || true

    cat << 'MOTD' | sudo tee /etc/update-motd.d/00-proxy > /dev/null
#!/bin/bash
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
    sudo chmod +x /etc/update-motd.d/00-proxy

    TS_FQDN=$(tailscale status --json 2>/dev/null | awk -F'"' '
        /"Self"/ { in_self=1 }
        in_self && /"DNSName"/ { gsub(/\.$/, "", $4); print $4; exit }
    ' || echo "${HOSTNAME}.ts.net")

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
