#!/bin/bash
# install.sh - Automated deployment of Network Lab Server with ContainerLab
# Usage: curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/netlab/install.sh | bash

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
HOSTNAME="${NETLAB_HOSTNAME:-netlab}"
SSH_PORT="${SSH_PORT:-15222}"
TIMEZONE="${TZ:-Europe/Paris}"

main() {
    log_info "=== Network Lab Server Deployment ==="
    
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

    log_info "Configuring sysctl for exit-node and containerlab support..."
    cat << EOF | sudo tee /etc/sysctl.d/99-netlab.conf > /dev/null
# IP forwarding for Tailscale exit-node
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
# Recommended for containerlab
net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
EOF
    sudo sysctl -p /etc/sysctl.d/99-netlab.conf > /dev/null 2>&1 || true

    log_info "Installing ContainerLab (includes Docker)..."
    # Disable sshd modification by containerlab setup script (we handle it ourselves)
    export SETUP_SSHD="false"
    curl -sL https://containerlab.dev/setup | sudo -E bash -s "all"

    log_info "Adding current user to docker group..."
    sudo usermod -aG docker "$USER"

    log_info "Configuring SSH on port $SSH_PORT..."
    # Create drop-in config for custom SSH port
    sudo mkdir -p /etc/ssh/sshd_config.d
    cat << EOF | sudo tee /etc/ssh/sshd_config.d/99-netlab.conf > /dev/null
# Custom SSH port for public access
Port $SSH_PORT
# Increase MaxAuthTries for containerlab nodes with many SSH keys
MaxAuthTries 20
EOF
    sudo systemctl restart ssh

    log_info "Configuring UFW firewall..."
    sudo ufw --force reset > /dev/null
    sudo ufw default deny incoming > /dev/null
    sudo ufw default allow outgoing > /dev/null
    # Allow custom SSH port from public internet
    sudo ufw allow ${SSH_PORT}/tcp > /dev/null
    # Allow all traffic on Tailscale interface
    sudo ufw allow in on tailscale0 > /dev/null
    # Temporarily allow SSH port 22 during setup (safety net)
    sudo ufw allow 22/tcp > /dev/null
    sudo ufw --force enable > /dev/null

    # Schedule SSH port 22 rule removal in 5 minutes
    log_warn "SSH port 22 temporarily open for 5 minutes (safety net)."
    log_warn "Verify Tailscale SSH or custom port ${SSH_PORT} works, then wait or run: sudo ufw delete allow 22/tcp"
    echo "sudo ufw delete allow 22/tcp && logger 'UFW: SSH port 22 closed by scheduled task'" | sudo at now + 5 minutes 2>/dev/null || {
        log_warn "Could not schedule automatic SSH cleanup. Run manually after verification:"
        log_warn "  sudo ufw delete allow 22/tcp"
    }

    # Get Tailscale IP for final message
    TS_IP=$(tailscale ip -4)

    echo ""
    log_info "=========================================="
    log_info "Deployment complete!"
    log_info "=========================================="
    echo ""
    echo "Access:"
    echo "  - Public SSH:    ssh -p ${SSH_PORT} ${USER}@<public-ip>"
    echo "  - Tailscale SSH: ssh ${USER}@${TS_IP} (or use Tailscale SSH)"
    echo ""
    echo "ContainerLab is ready. Example usage:"
    echo "  containerlab deploy -t mylab.clab.yml"
    echo "  containerlab inspect"
    echo "  containerlab destroy -t mylab.clab.yml"
    echo ""
    echo "Note: Log out and back in (or run 'newgrp docker') to use docker without sudo"
    echo ""
    log_warn "SSH port 22 will be closed in 5 minutes."
    log_warn "To cancel: sudo atq (list jobs) then sudo atrm <job-number>"
    echo ""
}

main "$@"
