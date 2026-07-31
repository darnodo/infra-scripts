# Gitea

Automated installation and update script for a [Gitea](https://about.gitea.com) instance
running inside an Alpine LXC on Proxmox. Replaces a previous deployment via
community-scripts. Migrating the existing instance's data is out of scope —
this script produces a fresh instance.

### Features

Single script, automatic mode selection:

| Context                                            | Action                                                                          |
| --------------------------------------------------- | -------------------------------------------------------------------------------- |
| From Proxmox host, no existing Gitea container      | Detects newest Alpine template, creates LXC, installs Gitea via `apk`            |
| From Proxmox host, Gitea container already present  | Reuses the existing LXC, refreshes packages, reapplies `app.ini`                 |
| From inside an LXC, no `gitea` binary               | Installs Gitea from scratch                                                      |
| From inside an LXC, `gitea` already present          | Refreshes packages and reapplies `app.ini` (no data changes)                     |

The container is identified by hostname **and** the `gitea` tag, so it is
re-found across reruns even if the CTID was auto-allocated the first time.

### Why `apk`, not a downloaded binary

Unlike `openbao/install.sh` and `gitea-runner/install.sh`, which fetch a
GitHub release, Gitea is installed from the Alpine package repositories:

```bash
apk add --no-cache gitea gitea-openrc
```

The official binaries on `dl.gitea.com` are glibc/CGO-linked (SQLite via
CGO), a bad fit for musl. Alpine packages a native musl build of Gitea in
`community`, with a `gitea-openrc` sub-package providing the service. This
script re-verifies on every install that `gitea` is available via `community`
(not `edge`) on the Alpine release in use, and fails loudly instead of
silently pinning `edge/community` if it isn't.

Consequences for the usual pattern:

|         | openbao / gitea-runner        | gitea                                  |
| ------- | ------------------------------ | ---------------------------------------- |
| Install | curl release from GitHub       | `apk add gitea gitea-openrc`             |
| Service | OpenRC unit written by the script | shipped by the package, used as-is    |
| Update  | swap binary + backup           | `refresh_os_packages` (`apk upgrade`)    |
| Version | tracked in `/opt/*_version.txt` | read from `apk list -I`                  |

### Configuration (`app.ini`)

Managed exclusively via `ini_set` (see `lib/common.sh`, #18) — never a
heredoc overwrite. The script owns and merges only the keys listed below;
everything else in the Alpine package's default `app.ini` (repository root,
session provider, etc.) is left untouched.

| Section     | Key                              | Value                                          |
| ----------- | --------------------------------- | ------------------------------------------------ |
| `[server]`  | `PROTOCOL`                        | `http`                                          |
| `[server]`  | `HTTP_ADDR` / `HTTP_PORT`         | `127.0.0.1` / `3000` (loopback; tailscale serve fronts it) |
| `[server]`  | `DOMAIN` / `ROOT_URL`             | `GITEA_DOMAIN` / `GITEA_ROOT_URL` — the **public** URL, not the tailnet one |
| `[server]`  | `DISABLE_SSH`                     | `true` (HTTPS-only usage confirmed)             |
| `[security]`| `INSTALL_LOCK`                    | `true`, written before the service's first start |
| `[security]`| `REVERSE_PROXY_LIMIT`             | `GITEA_REVERSE_PROXY_LIMIT` (default `2`) — **validate this, see below** |
| `[security]`| `REVERSE_PROXY_TRUSTED_PROXIES`   | `GITEA_TRUSTED_PROXIES` — never `*` (CVE-2026-20896) |
| `[service]` | `DISABLE_REGISTRATION`, `REQUIRE_CAPTCHA_FOR_LOGIN`, `ENABLE_CAPTCHA` | `true` |
| `[log]`     | `MODE` / `LEVEL` / `ROOT_PATH`    | `file` / `info` / `/var/log/gitea`              |
| `[log]`     | `COLORIZE`                        | `false` — ANSI codes would break the `<HOST>` match in the fail2ban filter added by #21 |
| `[metrics]` | `ENABLED`, `TOKEN`, `ENABLED_ISSUE_BY_REPOSITORY`, `ENABLED_ISSUE_BY_LABEL` | `true` / generated once / `true` / `true` |
| `[actions]` | `ENABLED`                         | `true`                                          |
| `[database]`| `DB_TYPE` / `PATH`                | `sqlite3` / `/var/lib/gitea/data/gitea.db`      |

The metrics token is generated once (`openssl rand -hex 32`, or supply
`GITEA_METRICS_TOKEN`) and never touched again once present — a rerun that
regenerated it would silently break the Prometheus scrape config.

The admin account is created once, non-interactively, after `INSTALL_LOCK`
is set and the service has started (Gitea's CLI needs a migrated DB). A
rerun skips creation if any admin account already exists, so it never resets
an operator-changed password.

### Usage

#### Full install (from Proxmox shell)

```bash
bash -c "$(curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/gitea/install.sh)"
```

Re-running the exact same command later refreshes Alpine packages and
reapplies `app.ini`, without touching the SQLite data or regenerating the
metrics token / admin account.

#### Customisation

Every parameter is exposed as an environment variable:

| Variable                     | Default                          | Description                                                             |
| ------------------------------ | ----------------------------------- | --------------------------------------------------------------------------- |
| `CTID`                        | auto                                | Container ID (auto-allocated via `pvesh get /cluster/nextid`)               |
| `GITEA_HOSTNAME`               | `gitea`                             | LXC hostname (also used as the tailnet MagicDNS name)                       |
| `TEMPLATE`                     | auto-detected                       | Alpine template; auto-detected from `pveam available`                       |
| `STORAGE`                      | `local-lvm`                         | Proxmox storage for the LXC root disk                                       |
| `TEMPLATE_STORAGE`             | `local`                             | Storage where Alpine templates live                                         |
| `CORES`                        | `2`                                  | vCPU cores                                                                  |
| `RAM`                          | `2048`                              | RAM in MiB                                                                  |
| `DISK`                         | `16`                                | Root disk size in GB                                                       |
| `BRIDGE`                       | `vmbr0`                             | Network bridge                                                             |
| `LXC_TAG`                      | `gitea`                             | Stable tag used to re-discover the container                                |
| `GITEA_DOMAIN`                 | `gitea.arnodo.fr`                   | Public domain                                                              |
| `GITEA_ROOT_URL`               | `https://<GITEA_DOMAIN>/`           | Public URL (used for clone URLs, webhooks, redirects)                       |
| `GITEA_HTTP_ADDR` / `_PORT`    | `127.0.0.1` / `3000`                | Local listener; loopback by default                                        |
| `GITEA_REVERSE_PROXY_LIMIT`    | `2`                                  | Proxy hop count (Traefik + `tailscale serve`) — validate before trusting it  |
| `GITEA_TRUSTED_PROXIES`        | `127.0.0.0/8,::1/128,100.64.0.0/10` | Never set to `*`                                                            |
| `GITEA_METRICS_TOKEN`          | generated                           | Prometheus bearer token; set once, then immutable                          |
| `GITEA_ADMIN_USER`             | `admin`                             | Admin account username                                                     |
| `GITEA_ADMIN_EMAIL`            | `admin@<GITEA_DOMAIN>`              | Admin account email                                                        |
| `GITEA_ADMIN_PASSWORD`         | generated                           | Admin account password, shown once at install time if generated            |
| `SYSLOG_TARGET` / `SYSLOG_PORT`| `proxy.taila5ad8.ts.net` / `5514`   | Where `gitea.log` is forwarded (proxy's generic rsyslog receiver, #20)      |
| `TS_AUTHKEY`                   | _(unset)_                           | Pre-auth key; if unset, finish `tailscale up` manually inside the LXC       |

```bash
CTID=130 GITEA_DOMAIN=git.example.com CORES=4 RAM=4096 \
  bash -c "$(curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/gitea/install.sh)"
```

#### Update (from inside the LXC)

```bash
curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/gitea/install.sh | bash
```

Auto-detected via the presence of the `gitea` binary. Runs
`refresh_os_packages` (which brings `gitea`/`gitea-openrc` to the latest
available build — no separate `apk upgrade gitea` needed), reapplies
`app.ini`, restarts the service, and refreshes the tailnet/rsyslog setup.
Re-running from the Proxmox host does the same after refreshing the LXC.

### Architecture

- **OS**: latest Alpine LXC template (auto-detected), unprivileged, `nesting=1`, `/dev/net/tun` passthrough for Tailscale
- **Package**: `gitea` + `gitea-openrc` from Alpine `community`
- **Service**: OpenRC, as shipped by the package (`supervise-daemon`), runs as user `gitea`
- **Config**: `/etc/gitea/app.ini` — merged via `ini_set`, see table above
- **Data**: `/var/lib/gitea` (SQLite DB, repositories, LFS)
- **Logs**: `/var/log/gitea/gitea.log` (Gitea's structured log, rotated daily/7d) forwarded via rsyslog to the proxy's receiver (#20); `/var/log/gitea/http.log` is the raw process stdout/stderr capture
- **Network**: listener bound to `127.0.0.1:3000`; **Tailscale** runs in the LXC and acts as the reverse proxy (`tailscale serve --https=443`, no port in the resulting URL)

---

## Deployment order — non-negotiable

This issue's script (#19) only produces a working, privately-reachable
instance. Bringing it onto the public domain safely requires the rest of the
milestone, **in this exact order**:

```
#18 → #19 → validation XFF (ci-dessous) → #20 → #21 → #22
```

> Activer le jail fail2ban (#21) **avant** d'avoir validé la chaîne
> `X-Forwarded-For` fait bannir le proxy Traefik lui-même au bout de 5
> échecs, et `gitea.arnodo.fr` devient inaccessible dans son intégralité.

Do not deploy #21 until the procedure below has confirmed `gitea.log`
contains the real client IP, not the proxy's tailnet IP.

## X-Forwarded-For validation procedure

From an IP known to be external to the tailnet (e.g. mobile hotspot),
trigger a failed login against the public URL. Then, inside the LXC:

```bash
grep "Failed authentication" /var/log/gitea/gitea.log | tail -1
```

| Result           | Interpretation                          | Action                                            |
| ------------------ | ------------------------------------------ | ---------------------------------------------------- |
| Real public IP    | Correct                                   | Proceed to #20                                     |
| `100.x.x.x`       | XFF not unwound far enough                 | Increase `GITEA_REVERSE_PROXY_LIMIT`, rerun the script |
| `127.0.0.1`       | `tailscale serve` masks everything        | Verify `127.0.0.0/8` is in `GITEA_TRUSTED_PROXIES` |

As long as that line does not show the real client IP, #21 stays
undeployed.
