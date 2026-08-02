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
- **Keep it simple**: One script per service, plain bash, no frameworks — readability over cleverness

### Available Scripts

| Script                          | Description                             | Usage                                                                                                     |
| -------------------------------- | ---------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| [`netlab/install.sh`](netlab/) | Network lab with ContainerLab           | `curl -fsSL https://raw.githubusercontent.com/darnodo/infra-scripts/main/netlab/install.sh` \| `bash`     |
| [`komodo/install.sh`](komodo/) | Komodo (Docker + MongoDB) on Alpine VM  | `bash -c "$(curl -fsSL https://raw.githubusercontent.com/darnodo/infra-scripts/main/komodo/install.sh)"`  |

### Requirements

- Fresh Debian 12/13 installation (netlab) or Alpine VM (komodo)
- User with sudo privileges (do not run as root) — except komodo, which runs as root
- Internet access
