# Semaphore UI

Deploys [Semaphore UI](https://semaphoreui.com) — the web interface for Ansible and OpenTofu —
into an **Alpine LXC** on Proxmox, from the upstream
[binary release](https://semaphoreui.com/docs/admin-guide/installation/binary-file).

The script binds Semaphore to `127.0.0.1:3000`; [Tailscale](https://tailscale.com) runs inside
the LXC as the reverse proxy and terminates TLS with tailnet certificates.

### Three modes, one entrypoint

| Context | Action |
| --- | --- |
| Proxmox host, no matching LXC | Downloads the newest Alpine template, creates the LXC, installs Semaphore inside it |
| Proxmox host, LXC already exists (hostname or `semaphore` tag) | `apk upgrade` + upgrades the Semaphore binary |
| Inside an LXC | Installs if `/usr/local/bin/semaphore` is missing, otherwise updates |

Detection is automatic: the presence of `pct` decides host vs. container.

### Requirements

- Proxmox VE host, or an Alpine LXC to run it in
- Run as **root** (enforced)
- Internet access

### Usage

From the Proxmox host shell:

```bash
bash -c "$(curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/semaphore/install.sh)"
```

Re-run the same one-liner later to upgrade — it finds the existing container and switches to
update mode.

### Configuration is yours to do

The script stops before `semaphore setup`: the database backend, the encryption key and the
admin account are decisions the operator makes, not the installer. After the LXC is up:

```bash
pct enter <CTID>
semaphore setup                 # BoltDB → /var/lib/semaphore/database.boltdb is the simplest
mv config.json /etc/semaphore/config.json
chown root:semaphore /etc/semaphore/config.json && chmod 640 /etc/semaphore/config.json
chown -R semaphore:semaphore /var/lib/semaphore
rc-service semaphore start
```

`semaphore setup` writes `"interface": ":3000"` (every interface). Set it to
`"127.0.0.1:3000"` — or just re-run the install script, which rewrites the key for you on
every update pass.

The OpenRC service refuses to start while `/etc/semaphore/config.json` is missing, so a
half-finished install fails loudly rather than silently.

### Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `CTID` | _(next free id)_ | Container ID |
| `SEMAPHORE_HOSTNAME` | `semaphore` | LXC hostname, also the Tailscale node name |
| `SEMAPHORE_VERSION` | `latest` | Release tag, e.g. `v2.19.12` |
| `SEMAPHORE_EDITION` | `standard` | `community` picks the `semaphore_community_*` build |
| `SEMAPHORE_LISTEN_ADDR` | `127.0.0.1:3000` | Value forced into `config.json`'s `interface` |
| `TEMPLATE` | _(newest Alpine)_ | Override the auto-detected LXC template |
| `STORAGE` / `TEMPLATE_STORAGE` | `local-lvm` / `local` | Proxmox storages |
| `CORES` / `RAM` / `DISK` | `2` / `2048` / `12` | Container sizing (MB / GB) |
| `BRIDGE` | `vmbr0` | Network bridge |
| `LXC_TAG` | `semaphore` | Tag used to recognise the container on re-runs |
| `TS_AUTHKEY` | _(unset)_ | Tailscale pre-auth key; without it, run `tailscale up` by hand |
| `SCRIPT_URL` | _(main branch)_ | Where the LXC pulls the script from — point it at a branch to test |

### What the LXC gets

- Alpine (newest template Proxmox advertises), unprivileged, `nesting=1`, `/dev/net/tun` mapped
- `semaphore` binary in `/usr/local/bin`, version pinned in `/opt/semaphore_version.txt`
- Ansible, OpenTofu, git, openssh-client, python3 — what Semaphore shells out to
- `gcompat`, because upstream builds against glibc and Alpine is musl
- A `semaphore` system user, `/etc/semaphore` (0750) and `/var/lib/semaphore` (0750)
- OpenRC service `semaphore`, enabled at boot, logging to `/var/log/semaphore.log`
- logrotate config, daily, 7 days
- Tailscale, plus `tailscale serve --https=443` onto the loopback listener
- Root auto-login on tty1 and a MOTD showing version, tailnet FQDN and service state

### Upgrading

Binary upgrades keep a timestamped backup at `/usr/local/bin/semaphore.bak.<epoch>`. The
service is stopped before the swap and restarted after. Nothing touches `config.json` beyond
the `interface` key.
