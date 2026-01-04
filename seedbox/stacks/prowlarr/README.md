# Prowlarr Stack

Indexer manager for Sonarr, Radarr, and other *arr applications.

## Access

- **URL**: https://prowlarr.taila5ad8.ts.net
- **Initial setup**: Configure on first access (no default credentials)

## Ports

| Port | Protocol | Exposure | Description |
|------|----------|----------|-------------|
| 9696 | TCP | Tailscale only | WebUI |

## Features

- Centralized indexer management
- Automatic sync with Sonarr/Radarr
- Support for Usenet and Torrent indexers
- Built-in indexer testing

## Configuration

### Connect to Sonarr

1. In Prowlarr: **Settings → Apps → Add**
2. Select "Sonarr"
3. Prowlarr Server: `http://localhost:9696` (or use Tailscale hostname)
4. Sonarr Server: `http://sonarr.taila5ad8.ts.net` or internal Docker network
5. API Key: Get from Sonarr **Settings → General**

### Add Indexers

1. Go to **Indexers → Add**
2. Search for your preferred indexer
3. Configure credentials if required
4. Test and save

## Troubleshooting

```bash
# Check logs
docker logs prowlarr

# Check Tailscale sidecar
docker exec ts-prowlarr tailscale status

# Restart stack
cd /srv/seedbox/stacks/prowlarr
docker compose restart

# Check WebUI is responding
docker exec ts-prowlarr curl -s http://127.0.0.1:9696
```

## Integration Notes

Prowlarr can communicate with other *arr apps via:
1. **Tailscale hostnames** (e.g., `sonarr.taila5ad8.ts.net`) - Recommended
2. **Docker network** - Requires additional network configuration
