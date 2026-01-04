#!/bin/bash
# install.sh - Seedbox Server Initial Setup
# Usage: curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/seedbox/install.sh | bash
#
# This script prepares the server for Docker-based seedbox deployment.
# Services are deployed separately via Gitea Actions.

set -euo pipefail

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Configuration (can be overridden via environment)
HOSTNAME="${SEEDBOX_HOSTNAME:-seedbox}"
NFS_SERVER="${NFS_SERVER:-}"
NFS_SHARE_MEDIA="${NFS_SHARE_MEDIA:-/volume2/Multimédia}"
NFS_MOUNT_MEDIA="${NFS_MOUNT_MEDIA:-/mnt/media}"
NFS_OPTS="defaults,_netdev,nofail,x-systemd.automount,x-systemd.mount-timeout=30s"
SEEDBOX_DIR="/srv/seedbox"
REPO_URL="${REPO_URL:-https://gitea.arnodo.fr/Damien/infra-scripts.git}"

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

main() {
    log_info "=== Seedbox Server Setup ==="
    
    check_root
    check_debian

    # Step 1: System update
    log_info "Updating system..."
    sudo apt-get update -qq
    sudo apt-get upgrade -y -qq

    # Step 2: Set hostname
    log_info "Setting hostname to: $HOSTNAME"
    echo "$HOSTNAME" | sudo tee /etc/hostname > /dev/null
    sudo hostnamectl set-hostname "$HOSTNAME"

    # Step 3: Install base packages
    log_info "Installing base packages..."
    sudo apt-get install -y -qq \
        vim \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        fail2ban \
        unattended-upgrades \
        nfs-common \
        ufw \
        at \
        git \
        rsync \
        > /dev/null

    # Ensure atd service is running (needed for delayed SSH lockdown)
    sudo systemctl enable --now atd

    # Step 4: Install Tailscale
    log_info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh

    log_info "Connecting to Tailscale..."
    sudo tailscale up
    
    # Get Tailscale hostname for display
    TS_FQDN=$(tailscale status --json 2>/dev/null | awk -F'"' '
        /"Self"/ { in_self=1 }
        in_self && /"DNSName"/ { gsub(/\.$/, "", $4); print $4; exit }
    ' || echo "${HOSTNAME}.ts.net")

    # Step 5: Install Docker
    log_info "Installing Docker..."
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    
    # shellcheck disable=SC1091
    sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin \
        > /dev/null

    # Step 6: Configure Docker for user
    log_info "Adding current user to docker group..."
    sudo usermod -aG docker "$USER"

    # Step 7: Configure UFW firewall (initial - SSH still open on public)
    log_info "Configuring UFW firewall (initial setup)..."
    sudo ufw --force reset > /dev/null
    sudo ufw default deny incoming > /dev/null
    sudo ufw default allow outgoing > /dev/null
    # SSH temporarily on all interfaces (will be locked down after Tailscale is confirmed)
    sudo ufw allow 22/tcp > /dev/null
    # BitTorrent peer port (public)
    sudo ufw allow 51413/tcp > /dev/null
    sudo ufw allow 51413/udp > /dev/null
    # Allow all traffic on Tailscale interface
    sudo ufw allow in on tailscale0 > /dev/null
    sudo ufw --force enable > /dev/null

    # Step 8: Schedule SSH lockdown via 'at' (2 minutes delay for safety)
    log_info "Scheduling SSH lockdown to Tailscale-only in 2 minutes..."
    log_warn "IMPORTANT: Reconnect via Tailscale SSH within 2 minutes!"
    log_warn "  ssh ${USER}@${TS_FQDN}"
    
    echo "sudo ufw delete allow 22/tcp" | at now + 2 minutes 2>/dev/null || {
        log_warn "Failed to schedule SSH lockdown via 'at'. Manual lockdown required."
        log_warn "Run manually after confirming Tailscale access: sudo ufw delete allow 22/tcp"
    }

    # Step 9: Create directory structure
    log_info "Creating directory structure..."
    sudo mkdir -p "$SEEDBOX_DIR"
    sudo chown -R "$USER:$USER" "$SEEDBOX_DIR"

    # Step 10: Configure NFS mount (if NFS_SERVER provided)
    if [[ -n "$NFS_SERVER" ]]; then
        log_info "Configuring NFS mount..."
        sudo mkdir -p "$NFS_MOUNT_MEDIA"
        
        if ! grep -q "${NFS_SERVER}:${NFS_SHARE_MEDIA}" /etc/fstab; then
            log_info "Adding NFS mount: ${NFS_SERVER}:${NFS_SHARE_MEDIA} -> ${NFS_MOUNT_MEDIA}"
            echo "${NFS_SERVER}:${NFS_SHARE_MEDIA} ${NFS_MOUNT_MEDIA} nfs ${NFS_OPTS} 0 0" | sudo tee -a /etc/fstab > /dev/null
        fi
        
        sudo mount -a || log_warn "NFS mount failed - ensure NAS is accessible via Tailscale"
    else
        log_warn "NFS_SERVER not set. NFS mount skipped. Set it later if needed."
    fi

    # Step 11: Clone repository (sparse checkout for seedbox/ only)
    log_info "Cloning seedbox configuration..."
    if [[ -d "${SEEDBOX_DIR}/.git" ]]; then
        cd "$SEEDBOX_DIR"
        git pull origin main || log_warn "Git pull failed"
    else
        # Clean any existing content
        rm -rf "${SEEDBOX_DIR:?}"/*
        rm -rf "${SEEDBOX_DIR}"/.[!.]* 2>/dev/null || true
        
        cd "$SEEDBOX_DIR"
        git init
        git remote add origin "$REPO_URL"
        
        # Configure sparse checkout to only get seedbox/ directory
        git sparse-checkout init --cone
        git sparse-checkout set seedbox
        
        # Fetch and checkout
        git fetch origin main
        git checkout main
        
        # Move contents of seedbox/ to root and clean up
        if [[ -d "${SEEDBOX_DIR}/seedbox" ]]; then
            # Move all files including hidden ones
            shopt -s dotglob
            mv "${SEEDBOX_DIR}/seedbox"/* "${SEEDBOX_DIR}/" 2>/dev/null || true
            shopt -u dotglob
            rmdir "${SEEDBOX_DIR}/seedbox" 2>/dev/null || true
        fi
        
        # Disable sparse checkout now that we have the files
        git sparse-checkout disable 2>/dev/null || true
    fi

    # Step 12: Configure MOTD
    log_info "Configuring MOTD..."
    sudo chmod -x /etc/update-motd.d/* 2>/dev/null || true
    
    cat << 'MOTD' | sudo tee /etc/update-motd.d/00-seedbox > /dev/null
#!/bin/bash
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
echo "Docker Seedbox Server"
echo "─────────────────────────────────────────"
echo "Access:"
echo "  • SSH        : ${TS_FQDN} (Tailscale only)"
echo "  • Seeding    : Public port 51413"
echo ""
echo "Services: (via Tailscale)"
docker ps --format '  • {{.Names}} : {{.Status}}' 2>/dev/null || echo "  Docker not running"
echo ""
echo "Storage:"
echo "  • Downloads  : /downloads (local RAID)"
echo "  • Media      : /mnt/media (NFS)"
echo ""
echo "Useful commands:"
echo "  cd /srv/seedbox && docker compose ls"
echo "  docker logs -f <container>"
echo "─────────────────────────────────────────"
echo ""
MOTD
    sudo chmod +x /etc/update-motd.d/00-seedbox

    # Final summary
    echo ""
    log_info "==========================================="
    log_info "Server setup complete!"
    log_info "==========================================="
    echo ""
    log_warn "⚠️  SSH LOCKDOWN SCHEDULED IN 2 MINUTES!"
    log_warn "    Reconnect NOW via Tailscale:"
    echo ""
    echo "    ssh ${USER}@${TS_FQDN}"
    echo ""
    echo "Server accessible at:"
    echo "  SSH: ssh user@${TS_FQDN}"
    echo ""
    echo "Directory structure:"
    echo "  ${SEEDBOX_DIR}/"
    echo "  ├── stacks/          # Docker Compose stacks"
    echo "  └── .env             # Secrets (created by Gitea Actions)"
    echo ""
    echo "Storage:"
    echo "  • Downloads: /downloads (local RAID - 3.4T)"
    echo "  • Media:     /mnt/media (NFS)"
    echo ""
    echo "NFS mount:"
    if [[ -n "$NFS_SERVER" ]]; then
        echo "  ${NFS_SERVER}:${NFS_SHARE_MEDIA} -> ${NFS_MOUNT_MEDIA}"
    else
        echo "  Not configured. Run with NFS_SERVER=<ip> to configure."
    fi
    echo ""
    echo "Next steps:"
    echo "  1. Reconnect via Tailscale SSH IMMEDIATELY"
    echo "  2. Configure Gitea secrets (see README.md)"
    echo "  3. Push to main branch to trigger deployment"
    echo "  4. Services will be available at <service>.taila5ad8.ts.net"
    echo ""
    log_info "SSH access via Tailscale: ssh user@${TS_FQDN}"
    echo ""
}

main "$@"
