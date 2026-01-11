#!/bin/bash
# install.sh - Automated deployment of Proxy Server with Tailscale + Nginx Proxy Manager
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
NPM_DIR="$HOME/npm"
TIMEZONE="${TZ:-Europe/Paris}"

main() {
    log_info "=== Proxy Server Deployment ==="
    
    check_root
    check_debian

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

    log_info "Configuring UFW firewall..."
    sudo ufw --force reset > /dev/null
    sudo ufw default deny incoming > /dev/null
    sudo ufw default allow outgoing > /dev/null
    # Allow HTTP/HTTPS from public internet
    sudo ufw allow 80/tcp > /dev/null
    sudo ufw allow 443/tcp > /dev/null
    # Allow all traffic on Tailscale interface (SSH, admin, etc.)
    sudo ufw allow in on tailscale0 > /dev/null
    # Temporarily allow SSH during setup (safety net)
    sudo ufw allow 22/tcp > /dev/null
    sudo ufw --force enable > /dev/null

    # Schedule SSH rule removal in 5 minutes
    log_warn "SSH port 22 temporarily open for 5 minutes (safety net)."
    log_warn "Verify Tailscale SSH access works, then wait or run: sudo ufw delete allow 22/tcp"
    echo "sudo ufw delete allow 22/tcp && logger 'UFW: SSH port 22 closed by scheduled task'" | sudo at now + 5 minutes 2>/dev/null || {
        log_warn "Could not schedule automatic SSH cleanup. Run manually after verification:"
        log_warn "  sudo ufw delete allow 22/tcp"
    }

    log_info "Creating NPM stack..."
    mkdir -p "$NPM_DIR"
    cat > "$NPM_DIR/docker-compose.yml" << EOF
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: nginx-proxy-manager
    restart: unless-stopped
    ports:
      # Public ports for reverse proxy
      - "80:80"
      - "443:443"
      # Admin port bound to localhost only (exposed via Tailscale serve)
      - "127.0.0.1:81:81"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    environment:
      - TZ=${TIMEZONE}
EOF

    log_info "Starting Nginx Proxy Manager..."
    cd "$NPM_DIR"
    docker compose up -d

    log_info "Exposing NPM admin panel via Tailscale..."
    sudo tailscale serve --bg http://localhost:81

    # Get Tailscale hostname for display
    TS_FQDN=$(tailscale status --json 2>/dev/null | awk -F'"' '
        /"Self"/ { in_self=1 }
        in_self && /"DNSName"/ { gsub(/\.$/, "", $4); print $4; exit }
    ' || echo "${HOSTNAME}.ts.net")

    echo ""
    log_info "=========================================="
    log_info "Deployment complete!"
    log_info "=========================================="
    echo ""
    echo "Access NPM admin panel at: https://${TS_FQDN}"
    echo "Default login: admin@example.com / changeme"
    echo ""
    echo "Note: Approve exit-node in Tailscale admin console if needed"
    echo ""
    log_warn "SSH port 22 will be closed in 5 minutes."
    log_warn "To cancel: sudo atq (list jobs) then sudo atrm <job-number>"
    echo ""
}

main "$@"
