#!/usr/bin/env bash
# setup-module: verify
# setup-api: 1
# =============================================================================
#  Component: verify - Check sshd, the firewall and the login account
#
#  The last chance to notice a lockout while there is still a working shell to
#  fix it from. Everything here is read-only: it proves the door opens rather
#  than assuming the previous steps left it that way.
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

  if run_sh "ss -ltnH 'sport = :${OPT_SSH_PORT}' | grep -q ."; then
    ok "sshd is listening on port ${OPT_SSH_PORT}"
  else
    warn "Nothing is listening on port ${OPT_SSH_PORT}. Do not close this session; check 'systemctl status ssh'."
  fi

  if have ufw && run_sh "ufw status | grep -qi '^Status: active'"; then
    detail "UFW active"
  else
    detail "UFW not active"
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
    detail "No authorized_keys for '$OPT_USERNAME'; sshd falls back to whatever it was already configured to accept"
    return 0
  fi

  owner="$(stat -c '%U' "$f" 2>/dev/null || true)"
  perm="$(stat -c '%a' "$f" 2>/dev/null || true)"

  if [ -n "$owner" ] && [ "$owner" != "$OPT_USERNAME" ]; then
    warn "$f is owned by '$owner', not '$OPT_USERNAME'; sshd will ignore it."
  elif [ -n "$perm" ] && [ "$perm" != "600" ] && [ "$perm" != "400" ]; then
    warn "$f is mode $perm; sshd may refuse to read it. Expected 600."
  else
    ok "$(ssh_count_keys) authorized key(s) in place for '$OPT_USERNAME'"
  fi
  return 0
}

# end-of-module
