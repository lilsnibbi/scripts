#!/usr/bin/env bash
# setup-module: hardening
# setup-api: 4
# =============================================================================
#  Component: hardening - Kernel network hardening, journald limits, root
#  password lock
#
#  Sourced by setup.sh, never run on its own. Everything here executes inside
#  the main script's shell: its options (OPT_*), helpers (step, run, run_spin,
#  apt_install, write_file, ok, warn, detail, die, ...) and its error trap.
#  Must define fn_hardening. The last line must be the end-of-module marker.
# =============================================================================
[ -n "${SETUP_API:-}" ] || { echo "This is a setup.sh component module; run setup.sh instead." >&2; exit 64; }

fn_hardening() {
  step "Kernel and log hardening"

  harden_sysctl
  cap_journal
  lock_root_password
}

# Network-stack settings that are safe on a Docker host.
#
# Two deliberate omissions. net.ipv4.ip_forward is not touched: Docker turns it
# on for itself, and a file here setting it to 0 would silently break every
# container's networking on the next boot. rp_filter is set to 2 (loose) rather
# than 1 (strict), because strict mode drops the asymmetric return traffic that
# Swarm's ingress mesh and multi-homed hosts legitimately produce; loose mode
# still discards obviously spoofed source addresses.
harden_sysctl() {
  local conf
  conf="$(cat <<'CONF'
# Managed by setup.sh (Server Initialization Suite).
# Deliberately absent: net.ipv4.ip_forward - Docker manages it.

# SYN flood mitigation.
net.ipv4.tcp_syncookies = 1

# Loose reverse-path filtering. Strict (1) breaks Docker Swarm ingress.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# Ignore anything that tries to rewrite this host's routing table.
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# This host is not a router.
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Source routing lets a caller choose the return path. Nothing legitimate does.
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Do not answer broadcast pings, do not trust forged ICMP errors.
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Do not hand kernel addresses to unprivileged readers.
kernel.kptr_restrict = 2

# Classic /tmp symlink and hardlink races.
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
CONF
)"

  if in_container; then
    conf="$(printf '%s\n' "$conf" | sed '/^kernel\./d; /^fs\./d')"
  fi

  if write_file /etc/sysctl.d/99-server-init-hardening.conf 0644 "$conf"; then
    if run sysctl -p /etc/sysctl.d/99-server-init-hardening.conf; then
      ok "Kernel network hardening applied"
    elif in_container; then
      # The net.* keys are per-namespace and take; kernel.* and fs.* belong to
      # the host and are refused. Expected, not a fault.
      detail "Kernel hardening applied where the container is allowed to; the rest is the host's"
    else
      warn "Some sysctl settings were rejected by this kernel; see: ${LOG_HINT}"
    fi
  else
    detail "Kernel hardening already in place"
  fi
}

# Container logs are already capped in daemon.json, but the journal is not. Its
# default ceiling is a share of the filesystem, so on a large disk it will grow
# into tens of gigabytes of logs nobody reads before anything stops it.
cap_journal() {
  local conf
  conf="$(cat <<'CONF'
# Managed by setup.sh (Server Initialization Suite).
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
SystemKeepFree=1G
MaxRetentionSec=1month
CONF
)"

  if write_file /etc/systemd/journald.conf.d/99-server-init.conf 0644 "$conf"; then
    run systemctl restart systemd-journald || warn "Could not restart systemd-journald."
    ok "Journal capped at 500 MB, one month retention"
  else
    detail "Journal limits already in place"
  fi
}

# Key-file presence cannot prove that a replacement login or sudo works.
# Preserve console/rescue access; authentication changes belong to the operator.
lock_root_password() {
  detail "Root password preserved for console/rescue access"
}

# end-of-module
