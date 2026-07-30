# lib/common.sh - Shared helpers for Proxmox LXC creator scripts.
#
# Sourced (not executed) by openbao/install.sh and gitea-runner/install.sh.
# Assumes the sourcing script already defines log_info/log_warn/log_error
# (both scripts do, identically) — this file does not redefine them.
#
# Contract for future LXC creator scripts:
#   - detect_latest_alpine_template(): Alpine only. A future Debian-based
#     script needs its own detect_latest_debian_template() (same pattern:
#     pveam available + sort -V + hardcoded fallback) — do not overload
#     this function with an OS parameter.
#   - enable_tty1_autologin(): implements the Alpine/OpenRC autologin
#     mechanism (inittab + agetty). A future Debian-based script needs a
#     distinct function (systemd container-getty override) rather than a
#     branch inside this one.
#   - find_existing_lxc(): OS-agnostic, works by tag/hostname via `pct
#     config`. Reusable as-is by any LXC creator script.
#   - refresh_os_packages(): Alpine only (apk update && apk upgrade). A
#     future Debian-based script needs its own apt-get variant.

set -euo pipefail

# ============================================================
# #12 - Detect newest Alpine LXC template available from the Proxmox repos.
# Echoes the template filename. Falls back to a hardcoded known-good
# template if `pveam` is unavailable or returns nothing.
# ============================================================
detect_latest_alpine_template() {
  local tmpl
  tmpl=$(pveam available --section system 2>/dev/null \
    | awk '/^system[[:space:]]+alpine-/ {print $2}' \
    | sort -V \
    | tail -n1)

  if [[ -z "$tmpl" ]]; then
    log_warn "Could not query pveam; falling back to a known-good Alpine template."
    tmpl="alpine-3.22-default_20250617_amd64.tar.xz"
  fi
  log_info "Selected Alpine template: $tmpl"
  echo "$tmpl"
}

# ============================================================
# #14 - Enable root auto-login on tty1 for an Alpine/OpenRC LXC.
# Idempotent: safe to call on every install/update.
# ============================================================
enable_tty1_autologin() {
  log_info "Enabling console auto-login on tty1..."
  # Alpine ships busybox getty by default; agetty (from util-linux) is what
  # supports --autologin.
  apk add --no-cache agetty >/dev/null 2>&1 || apk add --no-cache util-linux >/dev/null

  # Replace any existing tty1 entry, then append our autologin line. Doing it
  # in two steps (delete + append) is more robust than an in-place sed against
  # a pattern that may drift across Alpine releases.
  sed -i '/^tty1::/d' /etc/inittab
  echo 'tty1::respawn:/sbin/agetty --autologin root --noclear 38400 tty1' >> /etc/inittab

  # Tell PID 1 to re-read /etc/inittab so the change takes effect without a reboot.
  kill -HUP 1 2>/dev/null || true

  # Kick any getty/agetty still attached to tty1 so init respawns it *now* with
  # the new line — otherwise the first web-console session lands on the stale
  # process and the operator has to type `exit` once before autologin kicks in.
  pkill -KILL -f '(getty|agetty).*tty1' 2>/dev/null || true
}

# ============================================================
# #15 - Find an existing LXC by tag or hostname (host-side, requires pct).
# Echoes the CTID on match, returns 1 if none found.
#
# Expects HOSTNAME_LXC and LXC_TAG to be set by the caller (as openbao's
# find_existing_lxc already does).
# ============================================================
find_existing_lxc() {
  local id host tags
  while read -r id _; do
    [[ -z "$id" || "$id" == "VMID" ]] && continue
    host=$(pct config "$id" 2>/dev/null | awk -F': ' '/^hostname:/ {print $2}' || true)
    tags=$(pct config "$id" 2>/dev/null | awk -F': ' '/^tags:/ {print $2}' || true)
    if [[ "$host" == "$HOSTNAME_LXC" ]] || [[ ",${tags//;/,}," == *",${LXC_TAG},"* ]]; then
      echo "$id"
      return 0
    fi
  done < <(pct list | awk 'NR>1 {print $1}')
  return 1
}

# ============================================================
# #15 - Refresh OS packages (Alpine: apk update && apk upgrade).
# Callable both host-side (via pct exec) and inside the LXC.
# ============================================================
refresh_os_packages() {
  log_info "Refreshing Alpine packages..."
  apk update >/dev/null && apk upgrade >/dev/null
}
