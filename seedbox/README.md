# Seedbox Server

Deploys a seedbox with Transmission for maintaining Linux ISO mirrors and OS images.

## Quick Start

```bash
NFS_SERVER=nas curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/seedbox/install.sh | bash
```

## Components

- **Transmission**: BitTorrent client with WebUI
- **NFS**: Dual mount to NAS for downloads and media storage
- **Tailscale**: Private access to WebUI
- **Docker**: Container runtime
- **UFW**: Firewall (only peer port exposed publicly)
- **fail2ban** + **unattended-upgrades**: Basic hardening

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NFS_SERVER` | *required* | NAS hostname/IP (Tailscale) |
| `NFS_SHARE_DOWNLOAD` | `/volume2/Downloads` | NFS export for downloads |
| `NFS_SHARE_MEDIA` | `/volume2/Multimédia` | NFS export for media/ISOs |
| `NFS_MOUNT_DOWNLOAD` | `/mnt/download` | Local mount for downloads |
| `NFS_MOUNT_MEDIA` | `/mnt/media` | Local mount for media |
| `SEEDBOX_HOSTNAME` | `seedbox` | Server hostname |
| `PEER_PORT` | `51413` | BitTorrent peer port |
| `TRANSMISSION_USER` | `admin` | WebUI username |
| `TRANSMISSION_PASS` | *auto-generated* | WebUI password |
| `TZ` | `Europe/Paris` | Timezone |

Example with custom settings:

```bash
NFS_SERVER=nas \
NFS_SHARE_DOWNLOAD=/volume1/torrents \
NFS_SHARE_MEDIA=/volume1/iso \
TRANSMISSION_USER=damien \
curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/seedbox/install.sh | bash
```

## Network Access

| Service | Public | Tailscale |
|---------|--------|-----------|
| BitTorrent peers | ✅ Port 51413 | ✅ |
| Transmission WebUI | ❌ | ✅ Port 9091 |
| SSH | ❌ | ✅ Tailscale SSH |
| NFS (to NAS) | ❌ | ✅ |

## Storage Architecture

```
NAS (via Tailscale)                    Seedbox LXC (70GB)
┌─────────────────────┐                ┌─────────────────────┐
│ /volume2/Downloads  │◄──── NFS ────►│ /mnt/download       │
│ (incomplete + temp) │                │   └► /downloads     │
├─────────────────────┤                │      (in container) │
│ /volume2/Multimédia │◄──── NFS ────►│ /mnt/media          │
│ (ISOs, VMDK, QCOW)  │                │   └► /media         │
└─────────────────────┘                │      (in container) │
                                       └─────────────────────┘
```

### Transmission Paths

| Container Path | Host Path | NAS Path | Purpose |
|----------------|-----------|----------|---------|
| `/downloads` | `/mnt/download` | `/volume2/Downloads` | Incomplete + completed torrents |
| `/media` | `/mnt/media` | `/volume2/Multimédia` | Final ISOs, VMDK, QCOW images |

### Recommended Workflow

1. Torrents download to `/downloads` (on NAS via NFS)
2. Once complete, move ISOs to `/media/iso/<distro>/`
3. Proxmox mounts the same NAS share for VM templates

## What it does

1. Sets hostname
2. Installs base packages (vim, fail2ban, unattended-upgrades, nfs-common, at)
3. Installs and connects Tailscale
4. Installs Docker
5. Configures dual NFS mounts to NAS (same as Proxmox)
6. Deploys Transmission container with both mounts
7. Configures UFW (peer port public, WebUI via Tailscale only)
8. Temporarily opens SSH port 22 for 5 minutes (safety net)

## SSH Safety Net

During installation, SSH port 22 is temporarily opened for 5 minutes to prevent lockout if you're connected via public IP. After 5 minutes, it will be automatically closed and only Tailscale SSH will work.

```bash
# List scheduled jobs
sudo atq

# Cancel the scheduled SSH closure (replace N with job number)
sudo atrm N

# Manually close SSH port 22 if needed
sudo ufw delete allow 22/tcp
```

## Directory Structure

Organize your media by type:

```
/mnt/media/
├── iso/
│   ├── debian/
│   │   └── debian-12.7.0-amd64-netinst.iso
│   ├── ubuntu/
│   │   └── ubuntu-24.04.1-live-server-amd64.iso
│   ├── rhel/
│   │   └── rocky-9.4-x86_64-minimal.iso
│   └── proxmox/
│       └── proxmox-ve_8.2-1.iso
├── vmdk/
│   └── windows-server-2022.vmdk
└── qcow/
    └── cloud-init-debian-12.qcow2
```

## NAS Configuration (Synology)

Ensure your NAS exports both shares via NFS:

1. Control Panel → Shared Folder → Edit → NFS Permissions
2. For each share (`Downloads` and `Multimédia`), add rule:
   - Hostname/IP: `*` or Tailscale IP of seedbox (e.g., `100.x.x.x`)
   - Privilege: Read/Write
   - Squash: No mapping
   - Security: sys
   - Enable NFSv4.1: ✅

## Post-install

```bash
# Check NFS mounts
df -h /mnt/download /mnt/media

# View Transmission logs
cd ~/transmission && docker compose logs -f

# Restart Transmission
cd ~/transmission && docker compose restart

# Move completed ISO to final location
mv /mnt/download/debian-12.iso /mnt/media/iso/debian/
```
