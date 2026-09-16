#!/usr/bin/env bash
# setup-module: update
# setup-api: 4
# =============================================================================
#  Component: update - Refresh apt indexes and apply every pending upgrade
#
#  Sourced by setup.sh, never run on its own. Everything here executes inside
#  the main script's shell: its options (OPT_*), helpers (step, run, run_spin,
#  apt_install, write_file, ok, warn, detail, die, ...) and its error trap.
#  Must define fn_update. The last line must be the end-of-module marker.
# =============================================================================
[ -n "${SETUP_API:-}" ] || { echo "This is a setup.sh component module; run setup.sh instead." >&2; exit 64; }

# Timezone only. Time synchronisation is checked in preflight, before the first
# apt call, because a wrong clock breaks apt and TLS before this step runs.
configure_timezone() {
  [ -n "$OPT_TIMEZONE" ] && [ "$OPT_TIMEZONE" != "keep" ] || return 0

  local current
  current="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  if [ "$current" = "$OPT_TIMEZONE" ]; then
    detail "Timezone already $OPT_TIMEZONE"
  elif [ ! -f "/usr/share/zoneinfo/$OPT_TIMEZONE" ]; then
    # tzdata is missing rather than the zone being wrong: --timezone was
    # validated at startup, so this can only be the UTC default.
    detail "No zoneinfo on this image; leaving the timezone as ${current:-unknown}"
  elif run timedatectl set-timezone "$OPT_TIMEZONE"; then
    ok "Timezone set to $OPT_TIMEZONE"
  else
    warn "Could not set the timezone to $OPT_TIMEZONE."
  fi
  return 0
}

configure_hostname() {
  [ -n "$OPT_HOSTNAME" ] && [ "$OPT_HOSTNAME" != "$(hostname)" ] || return 0

  # hostnamectl needs systemd-hostnamed over D-Bus, which a container does not
  # always have. Fall back to setting it directly rather than failing the run.
  if ! run hostnamectl set-hostname "$OPT_HOSTNAME"; then
    run hostname "$OPT_HOSTNAME" || true
    write_file /etc/hostname 0644 "$OPT_HOSTNAME" || true
  fi
  # Keep /etc/hosts consistent so sudo does not stall on name resolution.
  if ! grep -qE "^127\.0\.1\.1[[:space:]]+$OPT_HOSTNAME\b" /etc/hosts 2>/dev/null; then
    run_sh "printf '127.0.1.1\t%s\n' '$OPT_HOSTNAME' >> /etc/hosts"
  fi
  ok "Hostname set to $OPT_HOSTNAME"
  if in_container; then
    detail "In a container the host may reset the hostname on restart"
  fi
  return 0
}

fn_update() {
  step "System update"

  configure_timezone
  configure_hostname

  # Preflight may already have refreshed the indexes, seconds ago, to install
  # the prerequisites; a second refresh would only cost time.
  apt_ensure_lists || die "apt-get update failed. Check network and mirror configuration."

  # Respect distribution phasing and never remove packages from a live host.
  local upgrade_opts=("${APT_OPTS[@]}" --with-new-pkgs --no-remove)

  # Simulate the same resolver options used by the real upgrade.
  local pending
  pending="$(apt-get -s upgrade "${upgrade_opts[@]}" 2>/dev/null | grep -c '^Inst ' || true)"
  if [ "${pending:-0}" -gt 0 ]; then
    detail "$pending package(s) to upgrade"
  fi

  # Run it whatever the count says. The simulation is a report, not a gate: it
  # can still disagree with the real resolver, and an upgrade with nothing
  # to do costs about a second.
  run_spin "Upgrading packages (this can take several minutes)" \
    retry apt-get upgrade "${upgrade_opts[@]}" \
    || die "Package upgrade failed. See: ${LOG_HINT}"

  if [ "${pending:-0}" -gt 0 ]; then
    ok "System packages upgraded"
  else
    ok "System already up to date"
  fi

  if [ -f /var/run/reboot-required ]; then
    warn "A reboot is required to finish applying kernel or library updates."
  fi
}

# end-of-module
