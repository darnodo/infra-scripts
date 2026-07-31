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
| `GITEA_HOSTNAME` | `gitea.taila5ad8.ts.net` | Bare tailnet hostname of the Gitea instance, resolved via MagicDNS at service start |
| `GITEA_INSTANCE_URL` | `https://<GITEA_HOSTNAME>` | Full URL used to register the runner. Derived from `GITEA_HOSTNAME` by default but overridable independently — e.g. if Gitea is ever exposed on a different scheme/port than the tailnet default |

#### Runner registration

After installation, enter the LXC and register the runner:

```bash
pct enter <CTID>
cd /var/lib/gitea-runner
su -s /bin/bash gitea-runner -c "act_runner register --instance https://gitea.taila5ad8.ts.net"
rc-service gitea-runner start
```

Use the value of `GITEA_INSTANCE_URL` (printed at the end of installation) as
`--instance`. As of Gitea's move to `tailscale serve --https=443` (#19), the
instance is reachable on 443 with **no port** in the URL — do not register
against the old `:3000` address.

#### Re-registration

The instance URL is frozen into `/var/lib/gitea-runner/.runner` at
registration time. Changing `GITEA_INSTANCE_URL` and re-running this script
does **not** retroactively fix an already-registered runner — the script
detects the mismatch and prints a warning, but never deletes or rewrites
`.runner` on its own (that would silently break a working runner on a
routine rerun).

To point an existing runner at a new instance URL:

```bash
rc-service gitea-runner stop
rm /var/lib/gitea-runner/.runner
cd /var/lib/gitea-runner
su -s /bin/bash gitea-runner -c "act_runner register --instance <new-url>"
rc-service gitea-runner start
```

A fresh registration token from the Gitea UI (Site Administration → Actions →
Runners) is required each time — tokens are single-use.

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
