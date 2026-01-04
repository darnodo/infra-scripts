# Seedbox Server

Docker-based seedbox with Tailscale integration. Each service runs in its own container with a Tailscale sidecar for secure HTTPS access via your tailnet.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         SEEDBOX                                 │
│                                                                 │
│  Tailscale Host (SSH only)                                     │
│  └─► seedbox.taila5ad8.ts.net                                  │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Docker Stacks                                           │   │
│  │                                                         │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐    │   │
│  │  │ Transmission│  │ Prowlarr    │  │ Sonarr      │    │   │
│  │  │ + ts-sidecar│  │ + ts-sidecar│  │ + ts-sidecar│    │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘    │   │
│  │        │                │                │             │   │
│  │        ▼                ▼                ▼             │   │
│  │   transmission.    prowlarr.        sonarr.           │   │
│  │   taila5ad8.ts.net taila5ad8.ts.net taila5ad8.ts.net │   │
│  │                                                         │   │
│  │  ┌─────────────┐                                       │   │
│  │  │ Portainer   │  (optional, for monitoring)          │   │
│  │  │ + ts-sidecar│                                       │   │
│  │  └─────────────┘                                       │   │
│  │        │                                                │   │
│  │        ▼                                                │   │
│  │   portainer.taila5ad8.ts.net                           │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  Storage:                                                      │
│  ├─ /downloads (local RAID - 3.4T)                            │
│  └─ /mnt/media (NFS from NAS)                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Start

### 1. Server Installation

```bash
# With NFS mount
NFS_SERVER=nas curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/seedbox/install.sh | bash

# Without NFS (configure later)
curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/seedbox/install.sh | bash
```

### 2. Configure Gitea Secrets

Go to **Gitea > Repository > Settings > Secrets and Variables > Actions** and add:

| Secret | Description | Example |
|--------|-------------|---------|
| `TS_AUTHKEY` | Tailscale OAuth client secret | `tskey-client-xxxxx-yyyyyyyy` |
| `SEEDBOX_SSH_KEY` | SSH private key (ed25519) | `-----BEGIN OPENSSH PRIVATE KEY-----...` |
| `TRANSMISSION_USER` | Transmission WebUI username | `admin` |
| `TRANSMISSION_PASS` | Transmission WebUI password | `your-secure-password` |

#### Creating Tailscale OAuth Client

1. Go to https://login.tailscale.com/admin/settings/oauth
2. Click "Generate OAuth Client"
3. Scopes: `devices:write`
4. Copy the **Client Secret** (starts with `tskey-client-`)

#### Creating SSH Deploy Key

```bash
# Generate key pair
ssh-keygen -t ed25519 -f seedbox-deploy -N "" -C "gitea-deploy"

# Add public key to seedbox
ssh debian@seedbox.taila5ad8.ts.net "cat >> ~/.ssh/authorized_keys" < seedbox-deploy.pub

# Copy private key content to Gitea secret SEEDBOX_SSH_KEY
cat seedbox-deploy
```

#### Tailscale ACL Configuration

Add this tag to your Tailscale ACL policy (https://login.tailscale.com/admin/acls):

```json
{
  "tagOwners": {
    "tag:container": ["autogroup:admins"]
  }
}
```

### 3. Deploy Services

Push to the `main` branch to trigger deployment:

```bash
git push origin main
```

Or create a PR for validation first.

## Services

| Service | URL | Port | Description |
|---------|-----|------|-------------|
| Transmission | `transmission.taila5ad8.ts.net` | 9091 | BitTorrent client |
| Prowlarr | `prowlarr.taila5ad8.ts.net` | 9696 | Indexer manager |
| Sonarr | `sonarr.taila5ad8.ts.net` | 8989 | TV series manager |
| Portainer | `portainer.taila5ad8.ts.net` | 9000 | Docker management UI |

## Directory Structure

```
/srv/seedbox/
├── stacks/
│   ├── transmission/
│   │   ├── docker-compose.yml
│   │   └── serve.json
│   ├── prowlarr/
│   │   ├── docker-compose.yml
│   │   └── serve.json
│   ├── sonarr/
│   │   ├── docker-compose.yml
│   │   └── serve.json
│   └── portainer/
│       ├── docker-compose.yml
│       └── serve.json
└── .env                        # Secrets (created by pipeline)

/downloads/                     # Local RAID storage (3.4T)
/mnt/media/                     # NFS mount from NAS
```

## Adding a New Service

1. Create a new directory in `stacks/`:

```bash
mkdir -p seedbox/stacks/myservice
```

2. Create `docker-compose.yml`:

```yaml
services:
  ts-myservice:
    image: tailscale/tailscale:latest
    hostname: myservice
    environment:
      - TS_AUTHKEY=${TS_AUTHKEY}
      - TS_EXTRA_ARGS=--advertise-tags=tag:container
      - TS_STATE_DIR=/var/lib/tailscale
      - TS_SERVE_CONFIG=/config/serve.json
      - TS_USERSPACE=false
    volumes:
      - ts-state:/var/lib/tailscale
      - ./serve.json:/config/serve.json:ro
    devices:
      - /dev/net/tun:/dev/net/tun
    cap_add:
      - net_admin
    restart: unless-stopped

  myservice:
    image: myservice/image:latest
    container_name: myservice
    network_mode: service:ts-myservice
    depends_on:
      - ts-myservice
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Paris
    volumes:
      - config:/config
      - /downloads:/downloads
      - /mnt/media:/media
    restart: unless-stopped

volumes:
  ts-state:
  config:
```

3. Create `serve.json`:

```json
{
  "TCP": {
    "443": {
      "HTTPS": true
    }
  },
  "Web": {
    "myservice.taila5ad8.ts.net:443": {
      "Handlers": {
        "/": {
          "Proxy": "http://127.0.0.1:PORT"
        }
      }
    }
  }
}
```

4. Commit and push:

```bash
git add seedbox/stacks/myservice/
git commit -m "feat(seedbox): add myservice stack"
git push origin main
```

## Removing a Service

### Option A: Via Git (recommended)

1. Remove the stack directory:

```bash
rm -rf seedbox/stacks/myservice/
git add -A
git commit -m "feat(seedbox): remove myservice stack"
git push origin main
```

2. Manually stop containers on seedbox:

```bash
ssh debian@seedbox.taila5ad8.ts.net
cd /srv/seedbox/stacks/myservice
docker compose down -v
```

3. Remove Tailscale device from admin console

### Option B: Manual (emergency)

```bash
ssh debian@seedbox.taila5ad8.ts.net
cd /srv/seedbox/stacks/myservice
docker compose down -v
rm -rf /srv/seedbox/stacks/myservice
# Remove device from https://login.tailscale.com/admin/machines
```

## Updating Services

### Update Docker Images

The pipeline automatically pulls latest images on each deployment. To force an update:

```bash
# Trigger a new deployment by making any change
git commit --allow-empty -m "chore: trigger deployment"
git push origin main
```

### Manual Update

```bash
ssh debian@seedbox.taila5ad8.ts.net
cd /srv/seedbox/stacks/transmission
docker compose pull
docker compose up -d
```

## Network Access

| Service | Public | Tailscale |
|---------|--------|-----------|
| SSH | ❌ | ✅ `seedbox.taila5ad8.ts.net` |
| Transmission WebUI | ❌ | ✅ HTTPS via sidecar |
| Transmission Peer | ✅ Port 51413 | ✅ |
| Prowlarr | ❌ | ✅ HTTPS via sidecar |
| Sonarr | ❌ | ✅ HTTPS via sidecar |
| Portainer | ❌ | ✅ HTTPS via sidecar |

## Troubleshooting

### Check container status

```bash
docker ps -a
docker logs ts-transmission
docker logs transmission
```

### Check Tailscale sidecar

```bash
docker exec ts-transmission tailscale status
docker exec ts-transmission tailscale serve status
```

### Restart a stack

```bash
cd /srv/seedbox/stacks/transmission
docker compose restart
```

### View all Tailscale devices

```bash
tailscale status
```

### Force re-authentication of sidecar

```bash
cd /srv/seedbox/stacks/transmission
docker compose down
docker volume rm transmission_ts-state
docker compose up -d
```

## NAS Configuration (Synology)

Ensure your NAS exports the media share via NFS:

1. **Control Panel → Shared Folder → Edit → NFS Permissions**
2. Add rule:
   - Hostname/IP: `100.64.0.0/10` (Tailscale subnet) or specific IP
   - Privilege: Read/Write
   - Squash: No mapping
   - Security: sys
   - Enable NFSv4.1: ✅

## Post-install Verification

```bash
# Check downloads mount
df -h /downloads

# Check NFS mount
df -h /mnt/media

# Check Docker
docker ps

# Check Tailscale devices
tailscale status

# Test service access
curl -k https://transmission.taila5ad8.ts.net
```
