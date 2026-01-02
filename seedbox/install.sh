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
# Note: uses head -c with || true to avoid SIGPIPE with pipefail
generate_password() {
    head -c 100 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16 || true
}

# Get Tailscale FQDN hostname from Self.DNSName
# Extracts DNSName from the Self object in tailscale status --json
get_tailscale_hostname() {
    local dns_name
    # Use awk to extract Self.DNSName specifically (not from peers)
    # Looks for DNSName within the Self block
    dns_name=$(tailscale status --json 2>/dev/null | awk -F'"' '
        /"Self"/ { in_self=1 }
        in_self && /"DNSName"/ { gsub(/\.$/, "", $4); print $4; exit }
    ' || true)
    
    if [[ -z "$dns_name" ]]; then
        # Fallback: use hostname + default tailnet domain hint
        dns_name="${HOSTNAME}.ts.net"
        log_warn "Could not determine Tailscale FQDN, using fallback: $dns_name"
    fi
    echo "$dns_name"
}

# Configuration variables (can be overridden via environment)
HOSTNAME="${SEEDBOX_HOSTNAME:-seedbox}"
# NFS shares configuration
NFS_SHARE_DOWNLOAD="${NFS_SHARE_DOWNLOAD:-/volume2/Downloads}"
NFS_SHARE_MEDIA="${NFS_SHARE_MEDIA:-/volume2/Multimédia}"
NFS_MOUNT_DOWNLOAD="${NFS_MOUNT_DOWNLOAD:-/mnt/download}"
NFS_MOUNT_MEDIA="${NFS_MOUNT_MEDIA:-/mnt/media}"
# NFS mount options (same as Proxmox)
NFS_OPTS="defaults,_netdev,nofail,x-systemd.automount,x-systemd.mount-timeout=30s"
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
    sudo apt-get update -qq
    sudo apt-get install -y -qq vim ca-certificates curl gnupg lsb-release fail2ban unattended-upgrades nfs-common ufw at > /dev/null

    log_info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh

    log_info "Connecting to Tailscale..."
    sudo tailscale up --ssh

    log_info "Installing Docker..."
    # Use official Docker installation method (DEB822 format)
    # See: https://docs.docker.com/engine/install/debian/
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    
    # Add Docker repository using DEB822 format (.sources)
    # shellcheck disable=SC1091
    sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    sudo apt-get update -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null

    log_info "Adding current user to docker group..."
    sudo usermod -aG docker "$USER"

    log_info "Configuring NFS mounts..."
    sudo mkdir -p "$NFS_MOUNT_DOWNLOAD" "$NFS_MOUNT_MEDIA"
    
    # Add download share to fstab if not already present
    if ! grep -q "${NFS_SERVER}:${NFS_SHARE_DOWNLOAD}" /etc/fstab; then
        log_info "Adding NFS mount: ${NFS_SERVER}:${NFS_SHARE_DOWNLOAD} -> ${NFS_MOUNT_DOWNLOAD}"
        echo "${NFS_SERVER}:${NFS_SHARE_DOWNLOAD} ${NFS_MOUNT_DOWNLOAD} nfs ${NFS_OPTS} 0 0" | sudo tee -a /etc/fstab > /dev/null
    fi
    
    # Add media share to fstab if not already present
    if ! grep -q "${NFS_SERVER}:${NFS_SHARE_MEDIA}" /etc/fstab; then
        log_info "Adding NFS mount: ${NFS_SERVER}:${NFS_SHARE_MEDIA} -> ${NFS_MOUNT_MEDIA}"
        echo "${NFS_SERVER}:${NFS_SHARE_MEDIA} ${NFS_MOUNT_MEDIA} nfs ${NFS_OPTS} 0 0" | sudo tee -a /etc/fstab > /dev/null
    fi
    
    # Mount NFS shares
    sudo mount -a || log_warn "NFS mount failed - ensure NAS is accessible via Tailscale"

    log_info "Creating Transmission stack..."
    mkdir -p "$TRANSMISSION_DIR"
    
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
      # WebUI - bound to localhost only (exposed via tailscale serve)
      - "127.0.0.1:9091:9091"
    volumes:
      - ./config:/config
      # Downloads: incomplete and complete torrents
      - ${NFS_MOUNT_DOWNLOAD}:/downloads
      # Media: final destination for completed ISOs and images
      - ${NFS_MOUNT_MEDIA}:/media
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
    # Use sg to run docker compose with the new docker group membership
    sg docker -c "docker compose up -d"

    log_info "Exposing Transmission WebUI via Tailscale..."
    sudo tailscale serve --bg http://localhost:9091

    # Get Tailscale hostname for final message
    TS_HOSTNAME=$(get_tailscale_hostname)

    log_info "Configuring UFW firewall..."
    sudo ufw --force reset > /dev/null
    sudo ufw default deny incoming > /dev/null
    sudo ufw default allow outgoing > /dev/null
    # Allow BitTorrent peer port from public internet
    sudo ufw allow ${PEER_PORT}/tcp > /dev/null
    sudo ufw allow ${PEER_PORT}/udp > /dev/null
    # Allow all traffic on Tailscale interface
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

    log_info "Configuring MOTD..."
    sudo chmod -x /etc/update-motd.d/* 2>/dev/null || true
    
    cat << 'MOTD' | sudo tee /etc/update-motd.d/00-seedbox > /dev/null
#!/bin/bash
# Get Tailscale FQDN from Self.DNSName
TS_FQDN=$(tailscale status --json 2>/dev/null | awk -F'"' '
    /"Self"/ { in_self=1 }
    in_self && /"DNSName"/ { gsub(/\.$/, "", $4); print $4; exit }
')
[[ -z "$TS_FQDN" ]] && TS_FQDN="$(hostname).ts.net"

echo ""
echo " ____  _____ _____ ____  ____   _____  __"
echo "/ ___|| ____| ____| _ \| __ ) / _ \ \/ /"
echo "\___ \|  _| |  _| | | | |  _ \| | | \  /"
echo " ___) | |___| |___| |_| | |_) | |_| /  \\"
echo "|____/|_____|_____|____/|____/ \___/_/\_\\"
echo ""
echo "ISO Seedbox Server - Transmission"
echo "─────────────────────────────────────────"
echo "Access:"
echo "  • WebUI     : https://${TS_FQDN}"
echo "  • SSH       : Tailscale only"
echo "  • Seeding   : Public port 51413"
echo ""
echo "Storage:"
echo "  • Downloads : /mnt/download"
echo "  • Media     : /mnt/media"
echo ""
echo "Useful commands:"
echo "  cd ~/transmission && docker compose logs -f"
echo "  df -h /mnt/download /mnt/media"
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
    echo "  URL      : https://${TS_HOSTNAME}"
    echo "  Username : ${TRANSMISSION_USER}"
    echo "  Password : ${TRANSMISSION_PASS}"
    echo ""
    echo "Storage (NFS mounts):"
    echo "  Downloads : ${NFS_SERVER}:${NFS_SHARE_DOWNLOAD} -> ${NFS_MOUNT_DOWNLOAD}"
    echo "  Media     : ${NFS_SERVER}:${NFS_SHARE_MEDIA} -> ${NFS_MOUNT_MEDIA}"
    echo ""
    echo "Transmission paths:"
    echo "  /downloads -> ${NFS_MOUNT_DOWNLOAD} (incomplete + complete torrents)"
    echo "  /media     -> ${NFS_MOUNT_MEDIA} (final destination for ISOs)"
    echo ""
    echo "Peer port  : ${PEER_PORT} (public)"
    echo ""
    log_warn "SSH port 22 will be closed in 5 minutes."
    log_warn "To cancel: sudo atq (list jobs) then sudo atrm <job-number>"
    echo ""
    echo "Save these credentials! The password was auto-generated."
    echo ""
}

main "$@"
