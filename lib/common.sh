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
  :
}

# ============================================================
# #14 - Enable root auto-login on tty1 for an Alpine/OpenRC LXC.
# Idempotent: safe to call on every install/update.
# ============================================================
enable_tty1_autologin() {
  :
}

# ============================================================
# #15 - Find an existing LXC by tag or hostname (host-side, requires pct).
# Echoes the CTID on match, returns 1 if none found.
#
# Expects HOSTNAME_LXC and LXC_TAG to be set by the caller (as openbao's
# find_existing_lxc already does).
# ============================================================
find_existing_lxc() {
  :
}

# ============================================================
# #15 - Refresh OS packages (Alpine: apk update && apk upgrade).
# Callable both host-side (via pct exec) and inside the LXC.
# ============================================================
refresh_os_packages() {
  :
}
