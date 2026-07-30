# Gitea Act Runner

Automated installation script for a Gitea Actions runner in an Alpine LXC on Proxmox.

### Features

Single script, three automatic modes:

| Context | Action |
|---------|--------|
| From Proxmox host | Creates Alpine LXC + installs everything |
| From empty LXC | Installs Docker + act_runner + OpenRC service |
| From LXC with act_runner installed | Updates binary to latest version |

### Usage

#### Full install (from Proxmox shell)

```bash
bash -c "$(curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/gitea-runner/install.sh)"
```

The script automatically creates an Alpine LXC (template auto-detected from `pveam available`) with Docker and act_runner.

#### Customization

Environment variables to override defaults:

```bash
CTID=120 HOSTNAME=runner-02 CORES=4 RAM=4096 bash -c "$(curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/gitea-runner/install.sh)"
```

| Variable | Default | Description |
|----------|---------|-------------|
| `CTID` | auto | Container ID |
| `RUNNER_HOSTNAME` | `gitea-runner` | LXC Hostname |
| `TEMPLATE` | auto-detected | Alpine template; auto-detected from `pveam available` |
| `CORES` | `2` | CPU cores |
| `RAM` | `2048` | RAM in MiB |
| `DISK` | `8` | Disk in GB |
| `STORAGE` | `local-lvm` | Proxmox storage for the LXC |
| `BRIDGE` | `vmbr0` | Network bridge |

#### Runner registration

After installation, enter the LXC and register the runner:

```bash
pct enter <CTID>
cd /var/lib/gitea-runner
su -s /bin/bash gitea-runner -c "act_runner register"
rc-service gitea-runner start
```

#### Update

From inside the LXC:

```bash
curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/gitea-runner/install.sh | bash
```

The script detects that act_runner is already installed and switches to update mode automatically. Re-running from the Proxmox host does the same, plus refreshes the LXC's Alpine packages first (`apk update && apk upgrade`).

### Architecture

- **OS**: Alpine 3.23 (LXC non-privileged, nesting active)
- **Docker**: installed via apk, OpenRC service
- **act_runner**: official binary from gitea.com/gitea/act_runner
- **Service**: OpenRC with logs in `/var/log/gitea-runner.log`
- **User**: `gitea-runner` (group `docker`)
