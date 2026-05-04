# infra-scripts

Public infrastructure deployment scripts designed to be executed directly via `curl | bash`.

### Philosophy

These scripts automate the deployment of personal infrastructure components. They are:

- **Self-contained**: No external dependencies beyond standard Debian packages
- **Idempotent-ish**: Safe to re-run (where possible)
- **Curl-friendly**: Designed for one-liner deployment from a fresh server
- **Multi-OS**: Supports Debian and Alpine-based deployments

### Available Scripts

| Script | Description | Usage |
|--------|-------------|-------|
| [`proxy/install.sh`](proxy/) | Reverse proxy with Tailscale + Nginx Proxy Manager | `curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/proxy/install.sh` \| `bash` |
| [`netlab/install.sh`](netlab/) | Network lab with ContainerLab | `curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/netlab/install.sh` \| `bash` |
| [`seedbox/install.sh`](seedbox/) | ISO seedbox with Transmission + NFS | `NFS_SERVER=<nas> curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/seedbox/install.sh` \| `bash` |
| [`gitea-runner/install.sh`](gitea-runner/) | Gitea Act Runner on Alpine LXC (Proxmox) | `bash -c "$(curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/gitea-runner/install.sh)"` |

### Requirements

- Fresh Debian 12/13 installation (proxy, netlab, seedbox) or Proxmox VE host (gitea-runner)
- User with sudo privileges (do not run as root) — except gitea-runner which runs as root on Proxmox
- Internet access