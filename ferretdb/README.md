# FerretDB

Automated installation and update script for [FerretDB](https://www.ferretdb.io) — a truly
open-source, MongoDB-compatible database — running inside a **Debian LXC** on Proxmox.

Built to give [LibreChat](https://www.librechat.ai) a drop-in MongoDB replacement without
running MongoDB itself (whose recent releases break on current kernels).

### Why Debian and not Alpine?

FerretDB v2 is two pieces:

1. the **FerretDB proxy** (a static Go binary), and
2. **PostgreSQL + Microsoft's DocumentDB extension**, the mandatory storage engine.

The DocumentDB extension is a compiled C PostgreSQL extension and is published **only** as
`deb`/`rpm` packages (`deb11`, `deb12`, `ubuntu`, `rhel`) — there is **no Alpine/musl build**.
So, unlike the `openbao`/`gitea-runner` Alpine LXCs in this repo, this stack runs on Debian 12
(`deb12`, the newest target the extension ships for).

### Features

Single script, automatic mode selection:

| Context                                               | Action                                                                                   |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| From Proxmox host, no existing FerretDB container     | Detects newest Debian template, creates LXC, installs PostgreSQL + DocumentDB + FerretDB |
| From Proxmox host, FerretDB container already present | Reuses the existing LXC, refreshes packages, upgrades the FerretDB stack to latest       |
| From inside an LXC, no `ferretdb` binary              | Installs the full stack from scratch                                                     |
| From inside an LXC, `ferretdb` already present        | Updates the packages only (no config / role / data changes)                              |

The container is identified by hostname **and** the `ferretdb` tag, so it is re-found across
reruns even if the CTID was auto-allocated the first time.

### Requirements

- Proxmox VE host with `pveam`, `pct`, `pvesh`, `jq` available
- Internet access from both the host (template download) and the LXC (package downloads)
- Script must be run as **root** on the Proxmox host (enforced; the Web UI shell qualifies)

### Usage

#### Full install (from Proxmox shell)

```bash
bash -c "$(curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/ferretdb/install.sh)"
```

The script prints the generated password and the ready-to-paste `MONGO_URI` at the end.
**Save them** — the password is not persisted on the Proxmox host.

Re-running the exact same command later upgrades packages inside the LXC and brings the
FerretDB stack to the latest release, without touching the config, role, or PostgreSQL data.

#### Customisation

Every parameter is exposed as an environment variable:

| Variable               | Default         | Description                                                                                                                            |
| ---------------------- | --------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `CTID`                 | auto            | Container ID (auto-allocated via `pvesh get /cluster/nextid`)                                                                          |
| `FERRETDB_HOSTNAME`    | `ferretdb`      | LXC hostname                                                                                                                           |
| `TEMPLATE`             | auto-detected   | Debian template; auto-detected from `pveam available`                                                                                  |
| `STORAGE`              | `local-lvm`     | Proxmox storage for the LXC root disk                                                                                                  |
| `TEMPLATE_STORAGE`     | `local`         | Storage where Debian templates live                                                                                                    |
| `CORES`                | `2`             | vCPU cores                                                                                                                             |
| `RAM`                  | `2048`          | RAM in MiB (Postgres + FerretDB)                                                                                                       |
| `DISK`                 | `16`            | Root disk size in GB                                                                                                                   |
| `BRIDGE`               | `vmbr0`         | Network bridge                                                                                                                         |
| `LXC_TAG`              | `ferretdb`      | Stable tag used to re-discover the container                                                                                           |
| `PG_VERSION`           | `17`            | PostgreSQL major version (from PGDG)                                                                                                   |
| `DOCUMENTDB_TAG`       | `latest`        | DocumentDB release tag (couples documentdb + FerretDB versions); pin e.g. `v0.107.0-ferretdb-2.7.0`                                    |
| `DOCUMENTDB_DISTRO`    | `deb12`         | Distro target in the documentdb deb filename. Escape hatch for a future `deb13` (set with `TEMPLATE`)                                  |
| `FERRETDB_LISTEN_ADDR` | `0.0.0.0:27017` | TCP listener. Exposed on all interfaces — it is a database other hosts must reach.                                                     |
| `FERRETDB_USER`        | `ferretdb`      | App user — both the PostgreSQL role and the MongoDB user LibreChat authenticates as                                                    |
| `FERRETDB_PASSWORD`    | auto-generated  | Auto-generated (`openssl rand -hex 24`) when unset; printed in the final summary                                                       |
| `TS_AUTHKEY`           | _(unset)_       | Pre-auth key (generate at <https://login.tailscale.com/admin/settings/keys>). If unset, finish `tailscale up` manually inside the LXC. |

```bash
CTID=220 FERRETDB_HOSTNAME=mongo RAM=4096 DISK=32 \
  bash -c "$(curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/ferretdb/install.sh)"
```

#### Wiring LibreChat

LibreChat talks to FerretDB exactly as it would to MongoDB. Point its `MONGO_URI` at the
container and **remove the bundled `mongodb` service** so it doesn't start:

```env
# LibreChat .env
MONGO_URI=mongodb://ferretdb:<password>@<lxc-ip-or-tailnet-fqdn>:27017/LibreChat
```

If you run LibreChat with the upstream `docker-compose.yml`, drop the dependency on the local
Mongo service in `docker-compose.override.yml`:

```yaml
services:
  api:
    environment:
      - MONGO_URI=mongodb://ferretdb:<password>@<lxc-ip>:27017/LibreChat
  # disable the bundled mongodb service (don't start it)
  mongodb:
    profiles: [donotstart]
```

LibreChat creates the `LibreChat` database on first connection and stores all conversations
and settings there.

#### Tailscale

The LXC joins the tailnet (`tailscale up --ssh`) so LibreChat on another node can reach the
database over the tailnet. Unlike the `openbao` script there is **no `tailscale serve`** — the
MongoDB wire protocol is raw TCP, not HTTP, so the listener is exposed directly on
`0.0.0.0:27017` (LAN + tailnet) by design.

If `TS_AUTHKEY` was supplied the node is brought up automatically; otherwise finish it
manually inside the LXC:

```bash
pct enter <CTID>
tailscale up --ssh --hostname ferretdb
tailscale status        # prints the tailnet FQDN
```

> Because the listener is on `0.0.0.0`, restrict access with your tailnet ACLs and/or a host
> firewall — anyone who can route to TCP 27017 can attempt to authenticate.

#### Update (from inside the LXC)

```bash
curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/ferretdb/install.sh | bash
```

The script auto-detects the presence of `/usr/bin/ferretdb` and switches to update mode:
packages are upgraded (including the DocumentDB extension via
`ALTER EXTENSION documentdb UPDATE`) and the services are restarted. The config, the
PostgreSQL role, and the data are left untouched.

### Architecture

- **OS**: latest Debian LXC template (auto-detected), unprivileged, `nesting=1`, `/dev/net/tun` passthrough for Tailscale
- **Storage engine**: PostgreSQL `17` (PGDG) + the DocumentDB extension (`pg_documentdb`, `pg_cron`), loopback-only on `127.0.0.1:5432`
- **Proxy**: official `ferretdb` deb from `github.com/FerretDB/FerretDB`, systemd unit, listening on `0.0.0.0:27017`
- **Auth**: MongoDB client credentials map to PostgreSQL roles; the app role is a superuser so the single homelab user can manage collections and Mongo users (`documentdb.enableUserCrud`)
- **Network**: FerretDB exposed on `0.0.0.0:27017`; Tailscale runs in the LXC for tailnet reachability (no `serve`)
- **Config**: `/etc/postgresql/17/main/conf.d/documentdb.conf` (extension settings) and `/etc/systemd/system/ferretdb.service.d/override.conf` (`FERRETDB_POSTGRESQL_URL`, `FERRETDB_LISTEN_ADDR`)
- **Logs**: PostgreSQL via its stock `logrotate`; FerretDB via journald, capped at `SystemMaxUse=200M`
- **Version tracking**: `/opt/ferretdb_version.txt` records the installed DocumentDB tag for idempotent reruns
