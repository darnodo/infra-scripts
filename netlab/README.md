# Network Lab Server (netlab)

Deploys a network lab server with ContainerLab for network simulation and testing.

## Quick Start

```bash
curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/netlab/install.sh | bash
```

## Components

- **ContainerLab**: Network topology emulation (Nokia SR Linux, Arista cEOS, etc.)
- **Docker**: Container runtime (installed by ContainerLab setup)
- **Tailscale**: Private network access (full access via tailnet)
- **UFW**: Firewall (only custom SSH port exposed publicly)
- **fail2ban** + **unattended-upgrades**: Basic hardening

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NETLAB_HOSTNAME` | `netlab` | Server hostname |
| `SSH_PORT` | `15222` | Public SSH port |
| `TZ` | `Europe/Paris` | Timezone |

Example:

```bash
NETLAB_HOSTNAME=clab01 SSH_PORT=22222 curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/netlab/install.sh | bash
```

## Network Access

| Service | Public | Tailscale |
|---------|--------|-----------|
| SSH | ✅ Port 15222 (configurable) | ✅ Port 22 + Tailscale SSH |
| All other services | ❌ | ✅ |

## What it does

1. Sets hostname
2. Installs base packages (vim, fail2ban, unattended-upgrades)
3. Installs and connects Tailscale
4. Configures sysctl for networking and containerlab
5. Installs ContainerLab + Docker (via official setup script)
6. Configures SSH on custom port
7. Configures UFW (custom SSH port public, everything else via Tailscale)

## Post-install

```bash
# Log out/in or run this to use docker without sudo
newgrp docker

# Verify installation
containerlab version
docker ps

# Deploy a lab
containerlab deploy -t mylab.clab.yml
```

## ContainerLab Resources

- [Documentation](https://containerlab.dev/)
- [Lab Examples](https://containerlab.dev/lab-examples/lab-examples/)
- [Supported Platforms](https://containerlab.dev/manual/kinds/)
