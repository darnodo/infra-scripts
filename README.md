# infra-scripts

Public infrastructure deployment scripts designed to be executed directly via `curl | bash`.

## Philosophy

These scripts automate the deployment of personal infrastructure components. They are:

- **Self-contained**: No external dependencies beyond standard Debian packages
- **Idempotent-ish**: Safe to re-run (where possible)
- **Curl-friendly**: Designed for one-liner deployment from a fresh server

## Available Scripts

| Script | Description | Usage |
|--------|-------------|-------|
| `proxy/install.sh` | Deploy a reverse proxy server with Tailscale + Nginx Proxy Manager | See below |

## Usage

### Proxy Server

Deploys a secure reverse proxy with:
- **Tailscale** for private network access (SSH, admin panel)
- **Nginx Proxy Manager** for public reverse proxy (HTTP/HTTPS)
- **UFW** firewall configured to expose only ports 80/443 publicly
- **fail2ban** and **unattended-upgrades** for basic hardening

```bash
curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/proxy/install.sh | bash
```

#### Environment Variables

You can customize the deployment:

```bash
# Custom hostname (default: proxy)
PROXY_HOSTNAME=myproxy curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/proxy/install.sh | bash

# Custom timezone (default: Europe/Paris)
TZ=America/New_York curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/proxy/install.sh | bash
```

#### Requirements

- Fresh Debian 11/12 installation
- User with sudo privileges (do not run as root)
- Internet access

#### What it does

1. Sets hostname
2. Installs base packages (vim, fail2ban, unattended-upgrades)
3. Installs and connects Tailscale (will prompt for authentication)
4. Configures sysctl for exit-node capability
5. Installs Docker
6. Configures UFW (80/443 public, everything else via Tailscale only)
7. Deploys Nginx Proxy Manager
8. Exposes NPM admin panel via Tailscale serve

#### Post-install

- Access NPM admin: `https://proxy.<your-tailnet>.ts.net`
- Default credentials: `admin@example.com` / `changeme`
- Optionally approve exit-node in Tailscale admin console

## License

MIT - Do whatever you want with these scripts.
