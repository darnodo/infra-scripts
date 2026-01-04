# Portainer Stack

Docker management UI, accessible via Tailscale.

## Access

- **URL**: https://portainer.taila5ad8.ts.net
- **Initial setup**: Create admin account on first access

## Ports

| Port | Protocol | Exposure | Description |
|------|----------|----------|-------------|
| 9000 | TCP | Tailscale only | WebUI |

## Features

- View and manage all Docker containers
- View logs in real-time
- Execute commands in containers
- Manage Docker networks and volumes
- Deploy stacks from templates

## First Setup

1. Access https://portainer.taila5ad8.ts.net
2. Create an admin account
3. Select "Docker" as environment type
4. Connect to local Docker socket

## Troubleshooting

```bash
# Check logs
docker logs portainer

# Check Tailscale sidecar
docker exec ts-portainer tailscale status

# Restart stack
cd /srv/seedbox/stacks/portainer
docker compose restart
```

## Note

Portainer is optional and mainly useful for:
- Visual monitoring of containers
- Quick access to logs
- Emergency container management

All deployments should still go through Gitea Actions for proper version control.
