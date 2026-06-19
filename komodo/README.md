# Komodo

Automated installation script for [Komodo](https://komo.do) — Docker + a MongoDB-backed Core + Periphery stack — running inside an **Alpine Linux VM**.

Follows the upstream [MongoDB quick start](https://komo.do/docs/setup/mongo): MongoDB stores all
resource configuration, audit logs, users, and system state. The Core exposes the API/UI on
loopback only; [Tailscale](https://tailscale.com) (running on the VM) acts as the reverse
proxy and terminates TLS via tailnet certificates.

### Why a VM, not an LXC?

Komodo Periphery binds `/var/run/docker.sock` and `/proc` from the host into a container so it
can manage other containers and report system stats. In an unprivileged LXC this clashes with
the cgroup / docker-in-docker constraints Proxmox imposes. A regular VM keeps it boring — the
script can just run `apk add docker` and let dockerd own the kernel namespace.

### Features

| Context                                                     | Action                                                                                                          |
| ----------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Fresh Alpine VM (no `/opt/komodo/compose.env`)              | Enables the `community` repo, installs Docker + Tailscale, generates secrets, writes compose files, pulls + ups |
| Re-run on an existing install (`/opt/komodo/compose.env` already there) | Preserves the generated secrets, re-pulls the latest images, and recreates the stack             |

### Requirements

- Alpine Linux **VM** (`/etc/alpine-release` must exist), not an LXC
- Internet access from the VM
- Run as **root** (enforced)

### Usage

#### Install / update

```bash
bash -c "$(curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/komodo/install.sh)"
```

The script prints the generated `KOMODO_DATABASE_PASSWORD`, `KOMODO_WEBHOOK_SECRET`, and
`KOMODO_JWT_SECRET` at the end. They are also written to `/opt/komodo/compose.env`
(`chmod 600`, root-only).

The initial admin user is `admin` / `changeme` — change it from the UI immediately after first
login.

#### Customisation

Every parameter is exposed as an environment variable:

| Variable             | Default                              | Description                                                                                                                                                |
| -------------------- | ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `KOMODO_DIR`         | `/opt/komodo`                        | Where the compose files and env file live                                                                                                                  |
| `KOMODO_HOSTNAME`    | `komodo`                             | Hostname used when running `tailscale up`                                                                                                                  |
| `KOMODO_LISTEN_ADDR` | `127.0.0.1:9120`                     | Host-side bind for Core's HTTP listener. Loopback by default — Tailscale fronts it.                                                                        |
| `KOMODO_HOST`        | `https://komodo.taila5ad8.ts.net`    | Written verbatim into `compose.env`; used by Komodo for OAuth / webhook URL suggestions. Set this to whatever your tailnet (or external reverse proxy) is. |
| `TS_AUTHKEY`         | _(unset)_                            | Pre-auth key (generate at <https://login.tailscale.com/admin/settings/keys>). If unset, finish `tailscale up` manually inside the VM.                      |

All other Komodo / Periphery variables are written with the upstream defaults — edit
`/opt/komodo/compose.env` if you need to tune them, then:

```bash
cd /opt/komodo
docker compose --env-file compose.env -f mongo.compose.yaml up -d
```

#### Tailscale reverse proxy

Komodo Core binds to `127.0.0.1:9120` only — Tailscale (running on the VM, **not** in a
container) is the reverse proxy and terminates TLS via tailnet certificates.

If `TS_AUTHKEY` was supplied at install time, the script runs `tailscale up` and
`tailscale serve --bg --https=443 http://127.0.0.1:9120` automatically. Komodo then becomes
reachable at `https://<hostname>.<tailnet>.ts.net` (matching `KOMODO_HOST`).

Otherwise, finish setup manually inside the VM:

```bash
tailscale up --ssh --hostname komodo
tailscale serve --bg --https=443 http://127.0.0.1:9120
tailscale status        # confirms the tailnet FQDN
```

> HTTPS in `tailscale serve` requires HTTPS to be enabled on your tailnet
> (Admin console → DNS → HTTPS Certificates).

### Architecture

- **OS**: Alpine VM with the `community` apk repo enabled (required for `docker`)
- **Engine**: `docker` + `docker-cli-compose` (the `docker compose` v2 plugin), OpenRC service `docker` enabled at boot
- **Stack**: `mongo`, `ghcr.io/moghtech/komodo-core:2`, `ghcr.io/moghtech/komodo-periphery:2` — see [upstream `mongo.compose.yaml`](https://komo.do/docs/setup/mongo)
- **Compose files**: `/opt/komodo/mongo.compose.yaml` + `/opt/komodo/compose.env` (`chmod 600`)
- **Network**: Core's `ports:` mapping is rewritten to `${KOMODO_LISTEN_ADDR}:9120` so only the loopback (and Tailscale serve) can reach it; Periphery has no host port
- **Reverse proxy**: Tailscale runs natively on the VM (not in a container) and publishes the loopback listener via `tailscale serve --https=443`
- **Secrets**: `KOMODO_DATABASE_PASSWORD`, `KOMODO_WEBHOOK_SECRET`, `KOMODO_JWT_SECRET` are auto-generated (`openssl rand -hex …`) on first install and preserved across re-runs
- **Logs**: Docker `json-file` driver capped at `max-size=10m`, `max-file=3` per container (`/etc/docker/daemon.json`)
