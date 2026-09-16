#!/usr/bin/env bash
# setup-module: fail2ban
# setup-api: 4
# =============================================================================
#  Component: fail2ban - Install and pre-configure fail2ban for SSH
#
#  Sourced by setup.sh, never run on its own. Everything here executes inside
#  the main script's shell: its options (OPT_*), helpers (step, run, run_spin,
#  apt_install, write_file, ok, warn, detail, die, ...) and its error trap.
#  Must define fn_fail2ban. The last line must be the end-of-module marker.
# =============================================================================
[ -n "${SETUP_API:-}" ] || { echo "This is a setup.sh component module; run setup.sh instead." >&2; exit 64; }

fn_fail2ban() {
  step "fail2ban"

  # python3-systemd is required for the systemd backend. Ubuntu 24.04 and
  # Debian 12 no longer guarantee /var/log/auth.log exists, so the file backend
  # fails at startup; reading the journal instead is the reliable option.
  apt_ensure_lists || true
  apt_install "fail2ban" fail2ban python3-systemd || die "Could not install fail2ban."

  if [ -f /etc/fail2ban/jail.local ] && ! grep -q '^# Managed by setup.sh (Server Initialization Suite).' /etc/fail2ban/jail.local; then
    detail "Existing fail2ban policy preserved"
    return 0
  fi
  local jail=/etc/fail2ban/jail.d/90-server-init.local
  local content
  content="$(cat <<CONF
# Managed by setup.sh (Server Initialization Suite).

[DEFAULT]
# Read the systemd journal rather than /var/log/auth.log, which does not exist
# on distributions that ship without rsyslog.
backend = systemd

bantime  = 1h
findtime = 10m
maxretry = 4
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = $OPT_SSH_PORT
maxretry = 3
bantime  = 1h

[recidive]
# Hosts that keep coming back after a ban get a much longer one.
enabled  = true
# fail2ban writes its own bans to this file, not to the journal, so this jail
# must override the systemd default and poll the file it names.
backend  = auto
logpath  = /var/log/fail2ban.log
bantime  = 1w
findtime = 1d
maxretry = 5
CONF
)"

  write_file "$jail" 0644 "$content" || true
  if [ -f /etc/fail2ban/jail.local ] && grep -q '^# Managed by setup.sh (Server Initialization Suite).' /etc/fail2ban/jail.local; then
    run rm -f /etc/fail2ban/jail.local
  fi

  # The recidive jail reads fail2ban's own log file, so it must exist.
  run touch /var/log/fail2ban.log

  run systemctl enable fail2ban || true
  if run systemctl restart fail2ban; then
    ok "fail2ban active, watching SSH on port $OPT_SSH_PORT"
  else
    warn "fail2ban failed to start. See 'journalctl -u fail2ban'."
  fi
}

# end-of-module
