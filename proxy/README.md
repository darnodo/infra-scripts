# Proxy Server

Deploys a secure reverse proxy with Tailscale + Nginx Proxy Manager.

## Quick Start

```bash
curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/proxy/install.sh | bash
```

## Components

- **Tailscale**: Private network access (SSH, admin panel)
- **Nginx Proxy Manager**: Public reverse proxy (HTTP/HTTPS)
- **UFW**: Firewall (only 80/443 exposed publicly)
- **fail2ban** + **unattended-upgrades**: Basic hardening

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PROXY_HOSTNAME` | `proxy` | Server hostname |
| `TZ` | `Europe/Paris` | Timezone |

Example:

```bash
PROXY_HOSTNAME=myproxy TZ=America/New_York curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/proxy/install.sh | bash
```

## What it does

1. Sets hostname
2. Installs base packages (vim, fail2ban, unattended-upgrades)
3. Installs and connects Tailscale (will prompt for authentication)
4. Configures sysctl for exit-node capability
5. Installs Docker
6. Configures UFW (80/443 public, everything else via Tailscale only)
7. Deploys Nginx Proxy Manager
8. Exposes NPM admin panel via Tailscale serve

## Post-install

- Access NPM admin: `https://proxy.<your-tailnet>.ts.net`
- Default credentials: `admin@example.com` / `changeme`
- Optionally approve exit-node in Tailscale admin console
