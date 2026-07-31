# infra-scripts

Public infrastructure deployment scripts designed to be executed directly via `curl | bash`.

### Philosophy

These scripts automate the deployment of personal infrastructure components. They are:

- **Self-contained**: No external dependencies beyond standard Debian packages
- **Idempotent-ish**: Safe to re-run (where possible)
- **Curl-friendly**: Designed for one-liner deployment from a fresh server
- **Multi-OS**: Supports Debian and Alpine-based deployments, chosen per-script based on that service's requirements
- **Loopback by default**: Services bind to `127.0.0.1`; Tailscale handles the reverse proxy and TLS termination
- **Log hygiene**: Every long-running service ships with a `logrotate` config (no unbounded log files)
- **Console auto-login**: Proxmox LXCs are configured for root auto-login on `tty1` (fast `pct enter` and Web UI shell access)
- **Keep it simple**: One script per service, plain bash, no frameworks — readability over cleverness

### Available Scripts

| Script                                     | Description                                           | Usage                                                                                                          |
| ------------------------------------------ | ----------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| [`proxy/install.sh`](proxy/)               | Reverse proxy with Tailscale + Nginx Proxy Manager    | `curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/proxy/install.sh` \| `bash`           |
| [`netlab/install.sh`](netlab/)             | Network lab with ContainerLab                         | `curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/netlab/install.sh` \| `bash`          |
| [`gitea-runner/install.sh`](gitea-runner/) | Gitea Act Runner on Alpine LXC (Proxmox)              | `bash -c "$(curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/gitea-runner/install.sh)"` |
| [`gitea/install.sh`](gitea/)               | Gitea Git service on Alpine LXC (Proxmox)             | `bash -c "$(curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/gitea/install.sh)"`        |
| [`openbao/install.sh`](openbao/)           | OpenBao secrets manager on Alpine LXC (Proxmox)       | `bash -c "$(curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/openbao/install.sh)"`      |
| [`komodo/install.sh`](komodo/)             | Komodo (Docker + MongoDB) on Alpine VM                | `bash -c "$(curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/komodo/install.sh)"`       |

### Requirements

- Fresh Debian 12/13 installation (proxy, netlab) or Proxmox VE host (gitea-runner, openbao) or Alpine VM (komodo)
- User with sudo privileges (do not run as root) — except gitea-runner, openbao, and komodo which run as root
- Internet access
