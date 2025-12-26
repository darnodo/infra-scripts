#!/bin/bash
# install.sh - Automated deployment of Seedbox Server with Transmission
# Usage: NFS_SERVER=<nas-ip> curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/seedbox/install.sh | bash

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

check_required_vars() {
    if [[ -z "${NFS_SERVER:-}" ]]; then
        log_error "NFS_SERVER environment variable is required."
        log_error "Usage: NFS_SERVER=<nas-ip-or-hostname> curl -fsSL ... | bash"
        exit 1
    fi
}

# Generate random password if not provided
generate_password() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16
}

# Configuration variables (can be overridden via environment)
HOSTNAME="${SEEDBOX_HOSTNAME:-seedbox}"
NFS_SHARE="${NFS_SHARE:-/volume1/iso}"
NFS_MOUNT="${NFS_MOUNT:-/mnt/iso}"
PEER_PORT="${PEER_PORT:-51413}"
TIMEZONE="${TZ:-Europe/Paris}"
TRANSMISSION_USER="${TRANSMISSION_USER:-admin}"
TRANSMISSION_PASS="${TRANSMISSION_PASS:-$(generate_password)}"
TRANSMISSION_DIR="$HOME/transmission"

main() {
    log_info "=== Seedbox Server Deployment ==="
    
    check_root
    check_debian
    check_required_vars

    log_info "Setting hostname to: $HOSTNAME"
    echo "$HOSTNAME" | sudo tee /etc/hostname > /dev/null
    sudo hostnamectl set-hostname "$HOSTNAME"

    log_info "Installing base packages..."
    sudo apt update -qq
    sudo apt install -y -qq vim ca-certificates curl gnupg lsb-release fail2ban unattended-upgrades nfs-common > /dev/null

    log_info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh

    log_info "Connecting to Tailscale..."
    sudo tailscale up --ssh

    log_info "Installing Docker..."
    sudo mkdir -m 0755 -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update -qq
    sudo apt install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null

    log_info "Adding current user to docker group..."
    sudo usermod -aG docker "$USER"

    log_info "Configuring NFS mount: ${NFS_SERVER}:${NFS_SHARE} -> ${NFS_MOUNT}"
    sudo mkdir -p "$NFS_MOUNT"
    
    # Add to fstab if not already present
    if ! grep -q "${NFS_SERVER}:${NFS_SHARE}" /etc/fstab; then
        echo "${NFS_SERVER}:${NFS_SHARE} ${NFS_MOUNT} nfs4 rw,soft,intr,timeo=150,retrans=3,_netdev 0 0" | sudo tee -a /etc/fstab > /dev/null
    fi
    
    # Mount NFS
    sudo mount -a || log_warn "NFS mount failed - ensure NAS is accessible via Tailscale"

    log_info "Creating Transmission stack..."
    mkdir -p "$TRANSMISSION_DIR"
    
    # Get Tailscale subnet for whitelist
    TS_IP=$(tailscale ip -4)
    
    cat > "$TRANSMISSION_DIR/docker-compose.yml" << EOF
services:
  transmission:
    image: linuxserver/transmission:latest
    container_name: transmission
    restart: unless-stopped
    ports:
      # Peer port - public for seeding
      - "${PEER_PORT}:${PEER_PORT}"
      - "${PEER_PORT}:${PEER_PORT}/udp"
      # WebUI - bound to Tailscale IP only
      - "${TS_IP}:9091:9091"
    volumes:
      - ./config:/config
      - ${NFS_MOUNT}:/downloads
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=${TIMEZONE}
      - USER=${TRANSMISSION_USER}
      - PASS=${TRANSMISSION_PASS}
      - PEERPORT=${PEER_PORT}
EOF

    log_info "Starting Transmission..."
    cd "$TRANSMISSION_DIR"
    docker compose up -d

    log_info "Configuring UFW firewall..."
    sudo ufw --force reset > /dev/null
    sudo ufw default deny incoming > /dev/null
    sudo ufw default allow outgoing > /dev/null
    # Allow BitTorrent peer port from public internet
    sudo ufw allow ${PEER_PORT}/tcp > /dev/null
    sudo ufw allow ${PEER_PORT}/udp > /dev/null
    # Allow all traffic on Tailscale interface
    sudo ufw allow in on tailscale0 > /dev/null
    sudo ufw --force enable > /dev/null

    log_info "Configuring MOTD..."
    sudo chmod -x /etc/update-motd.d/* 2>/dev/null || true
    
    cat << MOTD | sudo tee /etc/update-motd.d/00-seedbox > /dev/null
#!/bin/bash
echo ""
echo " ____  _____ _____ ____  ____   _____  __"
echo "/ ___|| ____| ____|  _ \| __ ) / _ \ \\\/ /"
echo "\___ \|  _| |  _| | | | |  _ \| | | \  /"
echo " ___) | |___| |___| |_| | |_) | |_| /  \\\\"
echo "|____/|_____|_____|____/|____/ \___/_/\_\\\\"
echo ""
echo "ISO Seedbox Server - Transmission"
echo "─────────────────────────────────────────"
echo "Access:"
echo "  • WebUI     : http://\$(tailscale ip -4):9091"
echo "  • SSH       : Tailscale only"
echo "  • Seeding   : Public port ${PEER_PORT}"
echo ""
echo "Storage:"
echo "  • NFS Mount : ${NFS_MOUNT}"
echo ""
echo "Useful commands:"
echo "  cd ~/transmission && docker compose logs -f"
echo "  df -h ${NFS_MOUNT}"
echo "─────────────────────────────────────────"
echo ""
MOTD
    sudo chmod +x /etc/update-motd.d/00-seedbox

    echo ""
    log_info "=========================================="
    log_info "Deployment complete!"
    log_info "=========================================="
    echo ""
    echo "Transmission WebUI:"
    echo "  URL      : http://${TS_IP}:9091"
    echo "  Username : ${TRANSMISSION_USER}"
    echo "  Password : ${TRANSMISSION_PASS}"
    echo ""
    echo "Storage:"
    echo "  NFS      : ${NFS_SERVER}:${NFS_SHARE}"
    echo "  Mount    : ${NFS_MOUNT}"
    echo ""
    echo "Peer port  : ${PEER_PORT} (public)"
    echo ""
    echo "Save these credentials! The password was auto-generated."
    echo ""
}

main "$@"
