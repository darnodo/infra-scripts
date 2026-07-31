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
#   - ini_set(): OS-agnostic (plain awk/sed, no OS-specific assumptions).
#     Reusable as-is by any script that manages an INI-style config file,
#     regardless of the underlying distro.
#
# Does not set shell options (set -e/-u/-o pipefail): a sourced file must
# not impose those on the caller's shell. Both openbao/install.sh and
# gitea-runner/install.sh already set them before sourcing this file.

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
# #12 - Ensure the given template is downloaded to TEMPLATE_STORAGE, doing a
# `pveam update` first so a stale local cache doesn't silently settle for an
# older version than the one detect_latest_alpine_template() just picked.
# Expects TEMPLATE_STORAGE to be set by the caller.
# ============================================================
ensure_template_present() {
  local tmpl="$1"
  if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$tmpl"; then
    log_info "Downloading template ${tmpl} to storage ${TEMPLATE_STORAGE}..."
    pveam update >/dev/null
    pveam download "$TEMPLATE_STORAGE" "$tmpl"
  else
    log_info "Template ${tmpl} already present on ${TEMPLATE_STORAGE}."
  fi
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
# Callable only from inside the LXC: this is a plain bash function in the
# current process, so it cannot run across a `pct exec ... sh -c` boundary
# without shipping its definition into the container. Host-side callers
# (see openbao/install.sh's update_lxc()) invoke apk update/upgrade inline
# via `pct exec` instead — do not try to dedupe that call site onto this
# function.
# ============================================================
refresh_os_packages() {
  log_info "Refreshing Alpine packages..."
  apk update >/dev/null && apk upgrade >/dev/null
}

# ============================================================
# #18 - Idempotently set KEY = VALUE in SECTION of an INI-style config file
# (e.g. Gitea's app.ini). Merges key by key rather than overwriting the
# whole file, so a rejoué script can add newly-required keys to an already
# customized config without clobbering it.
#
# Usage: ini_set <file> <section> <key> <value>
#
# Behavior:
#   - Missing file/section/key: created.
#   - Key present with a different value: replaced in place.
#   - Key present with the same value: no-op (byte-identical output).
#   - Other sections/keys: never touched — the match is scoped to the
#     given section, so the same key name in a different section (e.g.
#     ENABLED in both [metrics] and [actions]) is left alone.
# Comments, blank lines and section order are preserved. Written atomically
# (tmpfile + mv) so an interrupted run can't leave a corrupt config.
# ============================================================
ini_set() {
  local file="$1" section="$2" key="$3" value="$4"
  local tmp

  if [[ ! -f "$file" ]]; then
    mkdir -p "$(dirname "$file")"
    : > "$file"
  fi

  tmp=$(mktemp "${file}.tmp.XXXXXX")

  # mktemp defaults to 0600 root:root, which would silently lock the
  # service account that owns $file (e.g. gitea:www-data on Gitea's
  # app.ini) out of the config this function just wrote. Carry the
  # original file's mode/ownership onto the replacement before it lands.
  # `stat -c` works identically on GNU coreutils and BusyBox.
  chmod "$(stat -c '%a' "$file")" "$tmp" 2>/dev/null || true
  chown "$(stat -c '%u:%g' "$file")" "$tmp" 2>/dev/null || true

  awk -v section="$section" -v key="$key" -v value="$value" '
    /^\[.*\]$/ {
      if (in_section && !done) {
        printf "%s = %s\n", key, value
        done = 1
      }
      cur = $0
      gsub(/^\[|\]$/, "", cur)
      in_section = (cur == section)
      if (in_section) section_found = 1
      print
      next
    }
    {
      if (in_section && !done && match($0, "^[ \t]*" key "[ \t]*=")) {
        printf "%s = %s\n", key, value
        done = 1
        next
      }
      print
    }
    END {
      if (in_section && !done) {
        printf "%s = %s\n", key, value
        done = 1
      }
      if (!section_found) {
        if (NR > 0) print ""
        printf "[%s]\n", section
        printf "%s = %s\n", key, value
      }
    }
  ' "$file" > "$tmp"

  mv "$tmp" "$file"
}
