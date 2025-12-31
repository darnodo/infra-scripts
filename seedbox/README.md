# Seedbox Server

Deploys a seedbox with Transmission for maintaining Linux ISO mirrors and OS images.

## Quick Start

```bash
NFS_SERVER=nas TRANSMISSION_PASS=MySecureP@ss123 \
curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/seedbox/install.sh | bash
```

> **⚠️ Important:** Always set `TRANSMISSION_PASS` explicitly. If omitted, a random password is generated and displayed only once at the end of the installation. It cannot be recovered afterward without resetting the config.

## Components

- **Transmission**: BitTorrent client with WebUI
- **NFS**: Dual mount to NAS for downloads and media storage
- **Tailscale**: Private access to WebUI via `tailscale serve`
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
| `TRANSMISSION_PASS` | *auto-generated* | WebUI password (⚠️ set explicitly!) |
| `TZ` | `Europe/Paris` | Timezone |

Example with custom settings:

```bash
NFS_SERVER=nas \
NFS_SHARE_DOWNLOAD=/volume1/torrents \
NFS_SHARE_MEDIA=/volume1/iso \
TRANSMISSION_USER=damien \
TRANSMISSION_PASS=MySecurePassword \
curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/seedbox/install.sh | bash
```

### Password Recovery

If you forgot to set `TRANSMISSION_PASS` and lost the auto-generated password:

```bash
# Option 1: Check the docker-compose.yml (password in clear text)
grep PASS ~/transmission/docker-compose.yml

# Option 2: Reset by editing docker-compose.yml
cd ~/transmission
sed -i 's/PASS=.*/PASS=NewPassword/' docker-compose.yml
docker compose down && docker compose up -d
```

## Network Access

| Service | Public | Tailscale |
|---------|--------|-----------|
| BitTorrent peers | ✅ Port 51413 | ✅ |
| Transmission WebUI | ❌ | ✅ HTTPS via `tailscale serve` |
| SSH | ❌ | ✅ Tailscale SSH |
| NFS (to NAS) | ❌ | ✅ |

### WebUI Access

The WebUI is exposed via Tailscale Serve with automatic HTTPS:

```
https://seedbox.<your-tailnet>.ts.net
```

The WebUI binds to `localhost:9091` and is proxied through `tailscale serve`, ensuring it's never accessible from the public internet.

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
7. Exposes WebUI via `tailscale serve` (HTTPS on tailnet)
8. Configures UFW (peer port public, WebUI via Tailscale only)
9. Temporarily opens SSH port 22 for 5 minutes (safety net)

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

# Check tailscale serve status
tailscale serve status

# Move completed ISO to final location
mv /mnt/download/debian-12.iso /mnt/media/iso/debian/
```

## Troubleshooting

### WebUI not accessible

```bash
# Check tailscale serve is running
tailscale serve status

# Restart if needed
sudo tailscale serve --bg http://localhost:9091

# Check container is running
docker ps | grep transmission

# Check container logs
cd ~/transmission && docker compose logs
```

### Reset Transmission credentials

```bash
cd ~/transmission
docker compose down
# Edit docker-compose.yml to change USER and PASS
vim docker-compose.yml
docker compose up -d
```
