# Semaphore UI

Installs [Semaphore UI](https://semaphoreui.com), the web interface for Ansible and OpenTofu,
into an Alpine LXC on Proxmox, from the upstream
[binary release](https://semaphoreui.com/docs/admin-guide/installation/binary-file).

Semaphore binds to `127.0.0.1:3000`. [Tailscale](https://tailscale.com) runs inside the LXC as
the reverse proxy and terminates TLS with tailnet certificates.

### Three modes, one entrypoint

| Context                                                        | Action                                                                              |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Proxmox host, no matching LXC                                  | Downloads the newest Alpine template, creates the LXC, installs Semaphore inside it |
| Proxmox host, LXC already exists (hostname or `semaphore` tag) | `apk upgrade`, then upgrades the Semaphore binary                                   |
| Inside an LXC                                                  | Installs if `/usr/local/bin/semaphore` is missing, otherwise updates                |

The presence of `pct` is what decides host or container. You never pass a flag.

### Requirements

- A Proxmox VE host, or an Alpine LXC to run it in
- Run as root. The script checks.
- Internet access

### Usage

From the Proxmox host shell:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/darnodo/infra-scripts/main/semaphore/install.sh)"
```

Run the same one-liner again later to upgrade. It finds the existing container and switches to
update mode.

### Configuration

The script writes `/etc/semaphore/config.json` and runs the migrations, so `semaphore setup`
never has to run. The wizard is not worth the trouble anyway: it defaults to MySQL, and since
2.19 it panics outright on its own BoltDB option. SQLite is the obvious backend for a single
node, and the upstream binary carries a pure-Go driver, so there is nothing to compile.

```json
{
  "dialect": "sqlite",
  "sqlite": { "host": "/var/lib/semaphore/database.sqlite" },
  "interface": "127.0.0.1",
  "port": ":3000",
  "tmp_path": "/var/lib/semaphore/tmp",
  "cookie_hash": "...", "cookie_encryption": "...", "access_key_encryption": "..."
}
```

Semaphore joins `interface` and `port` to build its bind address, so the host and the port
go in separate keys. Put `127.0.0.1:3000` in `interface` alone and the server panics on
`too many colons in address`.

The three secrets are 32 random bytes each, generated on first install. Back this file up: if
you lose `access_key_encryption`, every credential Semaphore has stored becomes unreadable.
An existing `config.json` is never overwritten.

What is left to you is the admin account:

```bash
pct enter <CTID>
semaphore users add --admin --login damien --name Damien \
    --email damien@example.com --password '...' \
    --config=/etc/semaphore/config.json
rc-service semaphore start
```

For a real database, edit `config.json` to a `mysql` or `postgres` dialect and re-run the
script. It leaves the file alone apart from `interface` and `port`, which it pins back to
the loopback on every pass.

The OpenRC service refuses to start while `/etc/semaphore/config.json` is missing, so a
half-finished install fails where you can see it.

### Environment variables

| Variable                       | Default               | Description                                                       |
| ------------------------------ | --------------------- | ----------------------------------------------------------------- |
| `CTID`                         | _(next free id)_      | Container ID                                                      |
| `SEMAPHORE_HOSTNAME`           | `semaphore`           | LXC hostname, also the Tailscale node name                        |
| `SEMAPHORE_VERSION`            | `latest`              | Release tag, e.g. `v2.19.12`                                      |
| `SEMAPHORE_EDITION`            | `community`           | `standard` picks the licence-gated Pro build instead              |
| `SEMAPHORE_LISTEN_ADDR`        | `127.0.0.1:3000`      | Split across `config.json`'s `interface` and `port`               |
| `TEMPLATE`                     | _(newest Alpine)_     | Override the auto-detected LXC template                           |
| `STORAGE` / `TEMPLATE_STORAGE` | `local-lvm` / `local` | Proxmox storages                                                  |
| `CORES` / `RAM` / `DISK`       | `2` / `2048` / `12`   | Container sizing (MB / GB)                                        |
| `BRIDGE`                       | `vmbr0`               | Network bridge                                                    |
| `LXC_TAG`                      | `semaphore`           | Tag used to recognise the container on re-runs                    |
| `TS_AUTHKEY`                   | _(unset)_             | Tailscale pre-auth key. Without it, run `tailscale up` by hand    |
| `SCRIPT_URL`                   | _(main branch)_       | Where the LXC pulls the script from. Point it at a branch to test |

### What the LXC gets

- Alpine (newest template Proxmox advertises), unprivileged, `nesting=1`, `/dev/net/tun` mapped
- The `semaphore` binary in `/usr/local/bin`, version pinned in `/opt/semaphore_version.txt`.
  This is the community build, a static CGO-free binary, so `gcompat` is unnecessary.
- Ansible, OpenTofu, git, openssh-client, python3, which is what Semaphore shells out to
- A `semaphore` system user, `/etc/semaphore` (0750) and `/var/lib/semaphore` (0750)
- `config.json` (0640, `root:semaphore`) and a migrated SQLite database
- An OpenRC service `semaphore`, enabled at boot, logging to `/var/log/semaphore.log`,
  with `/usr/local/bin` on its PATH so the tasks it spawns can find the binary
- A logrotate config, daily, 7 days
- Tailscale, plus `tailscale serve --https=443` pointed at the loopback listener
- Root auto-login on tty1, and a MOTD showing the version, the tailnet FQDN and service state

### Upgrading

Binary upgrades keep a timestamped backup at `/usr/local/bin/semaphore.bak.<epoch>`. The
service stops before the swap and restarts after, then `semaphore migrate` brings the schema
forward. Nothing touches `config.json` beyond the `interface` and `port` keys.
