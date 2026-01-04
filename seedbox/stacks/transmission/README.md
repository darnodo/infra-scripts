# Transmission Stack

BitTorrent client with web interface, accessible via Tailscale.

## Access

- **URL**: https://transmission.taila5ad8.ts.net
- **Default credentials**: Set via `TRANSMISSION_USER` and `TRANSMISSION_PASS` secrets

## Ports

| Port | Protocol | Exposure | Description |
|------|----------|----------|-------------|
| 9091 | TCP | Tailscale only | WebUI |
| 51413 | TCP/UDP | Public | BitTorrent peer port |

## Volumes

| Path in container | Host path | Description |
|-------------------|-----------|-------------|
| `/config` | Docker volume | Transmission configuration |
| `/downloads` | `/srv/seedbox/downloads` | Download directory (local SSD) |
| `/media` | `/mnt/media` | Media library (NFS) |

## Configuration

### Download Paths

In Transmission settings:
- **Download to**: `/downloads`
- **Move completed to**: `/media/downloads` (optional)

### Peer Port

The peer port 51413 is exposed publicly for optimal seeding performance. Ensure your firewall/router allows this port.

## Troubleshooting

```bash
# Check logs
docker logs transmission

# Check Tailscale sidecar
docker exec ts-transmission tailscale status

# Restart stack
cd /srv/seedbox/stacks/transmission
docker compose restart

# Check WebUI is responding
docker exec ts-transmission curl -s http://127.0.0.1:9091
```
