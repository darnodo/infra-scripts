# Sonarr Stack

TV series management and automation.

## Access

- **URL**: https://sonarr.taila5ad8.ts.net
- **Initial setup**: Configure on first access (no default credentials)

## Ports

| Port | Protocol | Exposure | Description |
|------|----------|----------|-------------|
| 8989 | TCP | Tailscale only | WebUI |

## Volumes

| Path in container | Host path | Description |
|-------------------|-----------|-------------|
| `/config` | Docker volume | Sonarr configuration |
| `/downloads` | `/downloads` | Download directory (local RAID) |
| `/media` | `/mnt/media` | Media library (NFS) |

## Configuration

### Root Folders

1. Go to **Settings → Media Management → Root Folders**
2. Add `/media/TV` or your preferred path

### Download Client

1. Go to **Settings → Download Clients → Add**
2. Select "Transmission"
3. Host: `transmission.taila5ad8.ts.net`
4. Port: `443`
5. Use SSL: ✅
6. Username/Password: Your Transmission credentials

### Connect to Prowlarr

1. Go to **Settings → Indexers**
2. Prowlarr will auto-sync indexers if configured correctly

### Quality Profiles

Configure in **Settings → Profiles** based on your preferences.

## Troubleshooting

```bash
# Check logs
docker logs sonarr

# Check Tailscale sidecar
docker exec ts-sonarr tailscale status

# Restart stack
cd /srv/seedbox/stacks/sonarr
docker compose restart

# Check WebUI is responding
docker exec ts-sonarr curl -s http://127.0.0.1:8989
```

## Recommended Folder Structure

```
/mnt/media/
├── TV/
│   ├── Show Name (Year)/
│   │   ├── Season 01/
│   │   └── Season 02/
│   └── Another Show/
└── downloads/
    └── completed/
```

## API Key

Find your API key in **Settings → General → Security**.
This is needed for Prowlarr integration.
