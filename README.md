# infra-scripts

Public infrastructure deployment scripts designed to be executed directly via `curl | bash`.

### Philosophy

These scripts automate the deployment of personal infrastructure components. They are:

- **Self-contained**: one file per service, no external dependencies beyond the distro's packages
- **Idempotent-ish**: safe to re-run (where possible)
- **Curl-friendly**: designed for one-liner deployment from a fresh host
- **Context-aware**: the same script creates the LXC from the Proxmox host, or updates the service from inside it
- **Loopback by default**: services bind to `127.0.0.1`; Tailscale handles the reverse proxy and TLS termination
- **Log hygiene**: every long-running service ships with a `logrotate` config (no unbounded log files)
- **Keep it simple**: plain bash, no frameworks — readability over cleverness

### Available Scripts

| Script | Description | Usage |
| --- | --- | --- |
| [`semaphore/install.sh`](semaphore/) | Semaphore UI (Ansible / OpenTofu) in an Alpine LXC | `bash -c "$(curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/semaphore/install.sh)"` |

### Requirements

- Proxmox VE host (or the target LXC, for update runs)
- Run as root
- Internet access
