# OpenBao

Automated installation and update script for an [OpenBao](https://openbao.org) secrets-manager
server running inside an Alpine LXC on Proxmox.

### Features

Single script, automatic mode selection:

| Context                                              | Action                                                                            |
| ---------------------------------------------------- | --------------------------------------------------------------------------------- |
| From Proxmox host, no existing OpenBao container     | Detects newest Alpine template, creates LXC, installs `bao` + OpenRC service      |
| From Proxmox host, OpenBao container already present | Reuses the existing LXC, refreshes packages, upgrades `bao` to the latest release |
| From inside an LXC, no `bao` binary                  | Installs OpenBao from scratch                                                     |
| From inside an LXC, `bao` already present            | Updates the binary only (no config / data changes)                                |

The container is identified by hostname **and** the `openbao` tag, so it is
re-found across reruns even if the CTID was auto-allocated the first time.

### Requirements

- Proxmox VE host with `pveam`, `pct`, `pvesh`, `jq` available
- Internet access from both the host (template download) and the LXC (binary download)
- Script must be run as **root** on the Proxmox host (enforced; the Web UI shell qualifies)

### Usage

#### Full install (from Proxmox shell)

```bash
bash -c "$(curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/openbao/install.sh)"
```

Re-running the exact same command later upgrades packages inside the LXC and
brings the `bao` binary to the latest release, without touching the config or
the raft data directory.

#### Customisation

Every parameter is exposed as an environment variable:

| Variable           | Default       | Description                                                   |
| ------------------ | ------------- | ------------------------------------------------------------- |
| `CTID`             | auto          | Container ID (auto-allocated via `pvesh get /cluster/nextid`) |
| `OPENBAO_HOSTNAME` | `openbao`     | LXC hostname (also used as raft `node_id`)                    |
| `TEMPLATE`         | auto-detected | Alpine template; auto-detected from `pveam available`         |
| `STORAGE`          | `local-lvm`   | Proxmox storage for the LXC root disk                         |
| `TEMPLATE_STORAGE` | `local`       | Storage where Alpine templates live                           |
| `CORES`            | `2`           | vCPU cores                                                    |
| `RAM`              | `1024`        | RAM in MiB                                                    |
| `DISK`             | `8`           | Root disk size in GB                                          |
| `BRIDGE`           | `vmbr0`       | Network bridge                                                |
| `LXC_TAG`          | `openbao`     | Stable tag used to re-discover the container                  |
| `OPENBAO_VERSION`  | `latest`      | Pin a specific release (e.g. `v2.0.3`) or `latest`            |

```bash
CTID=210 OPENBAO_HOSTNAME=vault CORES=4 RAM=2048 \
  bash -c "$(curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/feat/lxc-OpenBao/openbao/install.sh)"
```

#### First-time initialisation

OpenBao starts sealed. Once the LXC is up:

```bash
pct enter <CTID>
export VAULT_ADDR=http://127.0.0.1:8200
bao operator init        # save the unseal keys + root token somewhere safe
bao operator unseal      # repeat with each key share until unsealed
```

#### Update (from inside the LXC)

```bash
curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/feat/lxc-OpenBao/openbao/install.sh | bash
```

The script auto-detects the presence of `/usr/local/bin/bao` and switches to
update mode. The OpenRC service is stopped, the binary is swapped (the old one
is kept as `bao.bak.<ts>`), then the service is restarted.

### Architecture

- **OS**: latest Alpine LXC template (auto-detected), unprivileged, `nesting=1`
- **Binary**: official `bao` release from `github.com/openbao/openbao`, installed in `/usr/local/bin`
- **Service**: OpenRC, runs as user `openbao`, logs to `/var/log/openbao.log` (rotated daily, 7 days retained)
- **Config**: `/etc/openbao/config.hcl` — raft storage, TLS disabled (terminate TLS at the reverse proxy), `disable_mlock = true` for unprivileged LXC
- **Data**: `/var/lib/openbao/data` (raft)
- **Version tracking**: `/opt/openbao_version.txt` records the currently installed tag for idempotent reruns
