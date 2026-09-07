# infra-scripts

Public infrastructure deployment scripts, meant to be run straight from `curl | bash`.

### Philosophy

- One file per service. No dependencies beyond what the distro ships.
- Safe to re-run, wherever that is achievable.
- Written for a one-liner from a fresh host.
- The same script creates the LXC from the Proxmox host and updates the service from inside it. It works out which one it is on its own.
- Services bind to `127.0.0.1`. Tailscale is the reverse proxy and terminates TLS.
- Anything long-running ships with a `logrotate` config, so no log file grows without bound.
- Plain bash, no frameworks. Readability beats cleverness.

### Available scripts

| Script | Description | Usage |
| --- | --- | --- |
| [`semaphore/install.sh`](semaphore/) | Semaphore UI (Ansible / OpenTofu) in an Alpine LXC | `bash -c "$(curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/semaphore/install.sh)"` |

### Requirements

- A Proxmox VE host, or the target LXC for update runs
- Run as root
- Internet access
