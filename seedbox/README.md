# Seedbox Server

Deploys a seedbox with Transmission for maintaining Linux ISO mirrors.

## Quick Start

```bash
NFS_SERVER=nas.tailnet.ts.net curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/seedbox/install.sh | bash
```

## Components

- **Transmission**: BitTorrent client with WebUI
- **NFS v4.1**: Mount to NAS for ISO storage
- **Tailscale**: Private access to WebUI
- **Docker**: Container runtime
- **UFW**: Firewall (only peer port exposed publicly)
- **fail2ban** + **unattended-upgrades**: Basic hardening

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NFS_SERVER` | *required* | NAS hostname/IP (Tailscale) |
| `NFS_SHARE` | `/volume1/iso` | NFS export path on NAS |
| `NFS_MOUNT` | `/mnt/iso` | Local mount point |
| `SEEDBOX_HOSTNAME` | `seedbox` | Server hostname |
| `PEER_PORT` | `51413` | BitTorrent peer port |
| `TRANSMISSION_USER` | `admin` | WebUI username |
| `TRANSMISSION_PASS` | *auto-generated* | WebUI password |
| `TZ` | `Europe/Paris` | Timezone |

Example with custom settings:

```bash
NFS_SERVER=nas.tailnet.ts.net \
NFS_SHARE=/volume1/linux-iso \
TRANSMISSION_USER=damien \
TRANSMISSION_PASS=mysecurepass \
curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/seedbox/install.sh | bash
```

## Network Access

| Service | Public | Tailscale |
|---------|--------|-----------|
| BitTorrent peers | ✅ Port 51413 | ✅ |
| Transmission WebUI | ❌ | ✅ Port 9091 |
| SSH | ❌ | ✅ Tailscale SSH |
| NFS (to NAS) | ❌ | ✅ |

## What it does

1. Sets hostname
2. Installs base packages (vim, fail2ban, unattended-upgrades, nfs-common)
3. Installs and connects Tailscale
4. Installs Docker
5. Configures NFS mount to NAS (via Tailscale)
6. Deploys Transmission container
7. Configures UFW (peer port public, WebUI via Tailscale only)

## Directory Structure

Organize your downloads by distribution:

```
/mnt/iso/
├── debian/
│   ├── debian-12.7.0-amd64-netinst.iso
│   └── debian-11.11.0-amd64-netinst.iso
├── ubuntu/
│   ├── ubuntu-24.04.1-live-server-amd64.iso
│   └── ubuntu-22.04.5-live-server-amd64.iso
├── rhel/
│   ├── rocky-9.4-x86_64-minimal.iso
│   └── almalinux-9.4-x86_64-minimal.iso
└── proxmox/
    └── proxmox-ve_8.2-1.iso
```

## NAS Configuration (Synology)

Ensure your NAS exports the share via NFS v4.1:

1. Control Panel → Shared Folder → Edit → NFS Permissions
2. Add rule:
   - Hostname/IP: Tailscale IP of seedbox (e.g., `100.x.x.x`)
   - Privilege: Read/Write
   - Squash: No mapping
   - Security: sys
   - Enable NFSv4.1: ✅

## Post-install

```bash
# Check NFS mount
df -h /mnt/iso

# View Transmission logs
cd ~/transmission && docker compose logs -f

# Restart Transmission
cd ~/transmission && docker compose restart
```
