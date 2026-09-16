#!/usr/bin/env bash
# setup-module: verify
# setup-api: 6
# =============================================================================
#  Component: verify - Check sshd, the firewall and the login account
#
#  The last chance to notice a lockout while there is still a working shell to
#  fix it from. Everything here is read-only. These local checks do not prove
#  that a real remote login, application deployment or reboot will succeed.
#
#  Sourced by setup.sh, never run on its own. Everything here executes inside
#  the main script's shell: its options (OPT_*), helpers (step, run, run_spin,
#  apt_install, write_file, ok, warn, detail, die, ...) and its error trap.
#  Must define fn_verify. The last line must be the end-of-module marker.
# =============================================================================
[ -n "${SETUP_API:-}" ] || { echo "This is a setup.sh component module; run setup.sh instead." >&2; exit 64; }

fn_verify() {
  step "Verify access"

  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    detail "Would verify sshd, the firewall and the account's authorized_keys"
    return 0
  fi

  if is_enabled ssh; then
    run sshd -t || die "Final SSH configuration validation failed. Keep this session open."
    local port
    for port in ${SSH_LISTEN_PORTS:-$OPT_SSH_PORT}; do
      run_sh "ss -ltnH 'sport = :${port}' | grep -q ." \
        || die "Nothing is listening on SSH port $port. Keep this session open and check 'systemctl status ssh'."
    done
    if [ "$OPT_SSH_KEY_ONLY" -eq 1 ]; then ssh_validate_key_policy; fi
    ok "SSH listening ports and configuration verified"
  fi

  if have ufw && run_sh "ufw status | grep -qi '^Status: active'"; then
    detail "UFW active"
  else
    [ "$FIREWALL_APPLIED" -eq 0 ] || die "UFW was configured but is no longer active."
    detail "UFW not active"
  fi

  if [ -n "$OPT_LOCKDOWN_INTERFACES" ] || [ -f /etc/systemd/system/server-init-ingress.service ]; then
    run systemctl is-active --quiet server-init-ingress.service \
      && run /usr/local/sbin/server-init-ingress --check \
      || die "Persistent public ingress protection failed final verification."
  fi
  if [ "$DOCKER_REQUIRED" -eq 1 ]; then
    run timeout 10 docker info || die "Docker is unavailable after provisioning."
  fi
  if [ "$FAIL2BAN_CONFIGURED" -eq 1 ]; then
    run timeout 5 fail2ban-client status sshd || die "The fail2ban SSH jail is unavailable."
  fi
  if [ "$DOKPLOY_INSTALLED" -eq 1 ]; then
    dokploy_services_ready || die "Dokploy services became unhealthy before setup completed."
    run systemctl is-active --quiet dokploy-ui-firewall.service \
      || die "Dokploy UI firewall is inactive."
  fi

  verify_authorized_keys
}

# Reports on authorized_keys without judging it. Password authentication is
# whatever the system already had, so an empty file is not necessarily a
# problem - but a key file sshd will silently ignore, because the ownership or
# mode is wrong, is worth saying out loud.
verify_authorized_keys() {
  local f perm owner

  resolve_user_home
  if [ -z "$SSH_USER_HOME" ]; then
    detail "Home directory for '$OPT_USERNAME' is unknown; skipping the key check"
    return 0
  fi
  f="$(ssh_authorized_keys_path)"

  if [ ! -s "$f" ]; then
    [ "$OPT_SSH_KEY_ONLY" -eq 0 ] || die "Key-only SSH is enabled but '$OPT_USERNAME' has no authorized_keys."
    detail "No authorized_keys for '$OPT_USERNAME'; sshd falls back to whatever it was already configured to accept"
    return 0
  fi

  owner="$(stat -c '%U' "$f" 2>/dev/null || true)"
  perm="$(stat -c '%a' "$f" 2>/dev/null || true)"

  if [ -n "$owner" ] && [ "$owner" != "$OPT_USERNAME" ]; then
    [ "$OPT_SSH_KEY_ONLY" -eq 0 ] || die "Key-only SSH account has an unexpected authorized_keys owner: $owner."
    warn "$f is owned by '$owner', not '$OPT_USERNAME'; sshd will ignore it."
  elif [ -n "$perm" ] && [ "$perm" != "600" ] && [ "$perm" != "400" ]; then
    [ "$OPT_SSH_KEY_ONLY" -eq 0 ] || die "Key-only SSH account has unexpected authorized_keys permissions: $perm."
    warn "$f is mode $perm; sshd may refuse to read it. Expected 600."
  else
    ok "$(ssh_count_keys) authorized key(s) in place for '$OPT_USERNAME'"
  fi
  return 0
}

# end-of-module
