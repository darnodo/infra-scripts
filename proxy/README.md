# Proxy Server

Deploys a secure reverse proxy with Tailscale + Nginx Proxy Manager.

## Quick Start

```bash
curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/proxy/install.sh | bash
```

## Components

- **Tailscale**: Private network access (SSH, admin panel)
- **Nginx Proxy Manager**: Public reverse proxy (HTTP/HTTPS)
- **UFW**: Firewall (only 80/443 exposed publicly)
- **fail2ban** + **unattended-upgrades**: Basic hardening

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PROXY_HOSTNAME` | `proxy` | Server hostname |
| `TZ` | `Europe/Paris` | Timezone |

Example:

```bash
PROXY_HOSTNAME=myproxy TZ=America/New_York curl -fsSL https://gitea.arnodo.fr/Damien/infra-scripts/raw/branch/main/proxy/install.sh | bash
```

## What it does

1. Sets hostname
2. Installs base packages (vim, fail2ban, unattended-upgrades, at)
3. Installs and connects Tailscale (will prompt for authentication)
4. Configures sysctl for exit-node capability
5. Installs Docker
6. Configures UFW (80/443 public, everything else via Tailscale only)
7. Deploys Nginx Proxy Manager
8. Exposes NPM admin panel via Tailscale serve
9. Temporarily opens SSH port 22 for 5 minutes (safety net)

## SSH Safety Net

During installation, SSH port 22 is temporarily opened for 5 minutes to prevent lockout if you're connected via public IP. After 5 minutes, it will be automatically closed and only Tailscale SSH will work.

```bash
# List scheduled jobs
sudo atq

# Cancel the scheduled SSH closure (replace N with job number)
sudo atrm N

# Manually close SSH port 22 if needed
sudo ufw delete allow 22/tcp
```

## Post-install

- Access NPM admin: `https://proxy.<your-tailnet>.ts.net`
- Default credentials: `admin@example.com` / `changeme`
- Optionally approve exit-node in Tailscale admin console

## Centralized log reception (rsyslog)

A fail2ban jail running inside an exposed service's own LXC only ever sees
this proxy's tailnet IP as the connection source, so it would end up
banning the proxy itself instead of the actual client. Detection has to
stay where the signal is (the service's application log); banning has to
happen here, where public connections terminate. Services forward their
logs to this proxy over TCP so a jail here can act on them.

| File | Purpose |
|------|---------|
| `/etc/rsyslog.d/10-remote-receiver.conf` | Generic `imtcp` listener only (`module`/`input`), port `RSYSLOG_PORT` (default `5514`). No rules here — see why below. |
| `/etc/rsyslog.d/50-<service>.conf` | One per exposed service. Routes by tag/programname into that service's own logfile for its dedicated fail2ban jail, then `stop`s so the message doesn't also fall through to the catch-all. |
| `/etc/rsyslog.d/90-remote-fallback.conf` | Catch-all: anything a `50-<service>.conf` didn't claim (or before one exists yet) lands in `/var/log/remote/<sender-hostname>.log`. |
| `/etc/logrotate.d/remote-logs` | Rotation for everything under `/var/log/remote/` (`copytruncate`, so fail2ban never loses its file descriptor across a rotation). |

rsyslog loads `/etc/rsyslog.d/*.conf` in filename order, and rules within a
ruleset run in the order they were loaded — a catch-all in `10-` would fire
on *every* message before a `50-<service>.conf` ever got a look, doubling
every claimed message into both files. Keeping the listener in `10-`, routing
in `50-`, and the catch-all in `90-` puts them in the right order without
depending on load-order accidents.

Adding a new exposed service is a matter of dropping its `50-<service>.conf`
here — nothing else in this list needs to change. A minimal example that
routes messages tagged `myservice` into their own file instead of the
generic catch-all:

```
$RuleSet remoteLogs
if $programname == 'myservice' then {
    action(type="omfile" file="/var/log/myservice/myservice.log")
    stop
}
$RuleSet RSYSLOG_DefaultRuleset
```

Deliberately on the legacy `$RuleSet <name>` directive rather than the
modern `ruleset(name="...") { ... }` object syntax: rsyslog rejects a named
ruleset declared with that object syntax more than once ("ruleset ...
specified more than once"), which breaks the moment a second
`50-<service>.conf` (or `90-remote-fallback.conf`) tries to add its own
rules to the same `remoteLogs` ruleset. `$RuleSet <name>` is a context
selector, not a one-shot declaration — any number of files can reopen it to
append rules, which is the entire point of this pattern.

`RSYSLOG_PORT` and `RSYSLOG_BIND_ADDR` (default `0.0.0.0`) are overridable
via environment. The default bind is safe as-is: UFW's default-deny only
opens `80/tcp` and `443/tcp` publicly, so port `5514` is reachable
exclusively over `tailscale0` regardless of the bind address. Binding to
the tailnet IP directly was considered and rejected — it would require
`tailscale up` to have already succeeded before rsyslog is configured,
which complicates the script's flow (a missing `TS_AUTHKEY` is tolerated
today). The residual risk is log injection from anything that reaches the
port (which can trigger a false fail2ban ban); narrow `RSYSLOG_BIND_ADDR`
to a specific tailnet IP if that risk becomes a concern.
