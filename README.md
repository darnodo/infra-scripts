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
| [`proxy/install.sh`](proxy/) | Reverse proxy with Tailscale + Nginx Proxy Manager | `curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/proxy/install.sh \| bash` |

## Requirements

- Fresh Debian 11/12 installation
- User with sudo privileges (do not run as root)
- Internet access

## License

MIT
