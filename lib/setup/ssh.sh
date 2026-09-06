#!/usr/bin/env bash
# setup-module: ssh
# setup-api: 1
# =============================================================================
#  Component: ssh - Create the login account and set the SSH port
#
#  Scope is deliberately narrow: create the login account, append a public key
#  if one was supplied, and set the listening port. Authentication directives -
#  PasswordAuthentication, PermitRootLogin, AllowUsers, AuthenticationMethods -
#  are never written, because getting any of them wrong on an unattended run
#  locks the host out with nobody at the console to undo it. Port is the one
#  exception: it cannot deny a login on its own, and the firewall step needs to
#  agree with it.
#
#  Sourced by setup.sh, never run on its own. Everything here executes inside
#  the main script's shell: its options (OPT_*), helpers (step, run, run_spin,
#  apt_install, write_file, ok, warn, detail, die, ...) and its error trap.
#  Must define fn_ssh. The last line must be the end-of-module marker.
# =============================================================================
[ -n "${SETUP_API:-}" ] || { echo "This is a setup.sh component module; run setup.sh instead." >&2; exit 64; }

ssh_resolve_home() {
  resolve_user_home
  [ -n "$SSH_USER_HOME" ] || die "Could not resolve the home directory of '$OPT_USERNAME'."
}

ssh_create_user() {
  if [ "$OPT_USERNAME" = "root" ]; then
    ssh_resolve_home
    return 0
  fi

  if id -u "$OPT_USERNAME" >/dev/null 2>&1; then
    ok "User '$OPT_USERNAME' already exists"
  else
    run useradd --create-home --shell /bin/bash "$OPT_USERNAME" \
      || die "Failed to create user '$OPT_USERNAME'."
    ok "Created user '$OPT_USERNAME'"
  fi

  # No password is ever set, so login is key-only. sudo therefore has to be
  # passwordless or the account could not administer anything.
  run usermod -aG sudo "$OPT_USERNAME" || true
  local sudoers="/etc/sudoers.d/90-${OPT_USERNAME}-init"
  write_file "$sudoers" 0440 "$OPT_USERNAME ALL=(ALL) NOPASSWD:ALL" || true
  if [ "$OPT_DRY_RUN" -eq 0 ] && [ -f "$sudoers" ]; then
    if have visudo; then
      if ! visudo -cf "$sudoers" >&4 2>&1; then
        run rm -f "$sudoers"
        die "The generated sudoers file was rejected by visudo and has been removed."
      fi
    else
      warn "visudo is unavailable, so the sudoers drop-in could not be validated."
    fi
  fi
  ok "Passwordless sudo configured for '$OPT_USERNAME'"

  ssh_resolve_home
}

ssh_install_pubkey() {
  local pubkey="$1"
  local dir="$SSH_USER_HOME/.ssh"
  local file="$dir/authorized_keys"

  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    detail "Would install public key into $file"
    return 0
  fi

  install -d -m 700 -o "$OPT_USERNAME" -g "$(id -gn "$OPT_USERNAME")" "$dir"
  touch "$file"
  chmod 600 "$file"
  chown "$OPT_USERNAME:$(id -gn "$OPT_USERNAME")" "$file"

  if grep -qxF "$pubkey" "$file" 2>/dev/null; then
    detail "Public key already present in authorized_keys"
  else
    printf '%s\n' "$pubkey" >>"$file"
  fi
}

# Appends a supplied public key, or leaves whatever is already there alone.
# Nothing here can remove an existing key or refuse a login, so there is no
# failure mode that costs access.
ssh_setup_keys() {
  local existing
  existing="$(ssh_count_keys)"

  if [ -n "$OPT_PUBKEY" ]; then
    ssh_install_pubkey "$OPT_PUBKEY"
    SSH_KEY_SOURCE="provided"
    ok "Installed the supplied public key for '$OPT_USERNAME'"
    return 0
  fi

  if [ "$existing" -gt 0 ]; then
    SSH_KEY_SOURCE="existing"
    ok "'$OPT_USERNAME' already has $existing authorized key(s); keeping them"
    return 0
  fi

  SSH_KEY_SOURCE="none"
  detail "No authorized keys for '$OPT_USERNAME' and no --pubkey given; leaving authentication as it is"
  return 0
}

# Port is the only directive this script owns, and it is the only one commented
# out elsewhere. sshd keeps the first value it finds, so a cloud image shipping
# /etc/ssh/sshd_config.d/50-cloud-init.conf with its own Port would otherwise
# silently win. Every other directive in those files is left exactly as it is.
ssh_neutralise_conflicts() {
  local ours="$1"
  local directives='Port'
  local f
  for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [ -f "$f" ] || continue
    [ "$f" = "$ours" ] && continue
    if grep -qE "^[[:space:]]*($directives)[[:space:]]" "$f"; then
      backup_file "$f"
      run sed -i -E "s~^[[:space:]]*($directives)[[:space:]]~# disabled by setup.sh: \\1 ~" "$f"
      detail "Neutralised overlapping directives in $f"
    fi
  done
}

ssh_ensure_include() {
  local main=/etc/ssh/sshd_config
  if [ ! -f "$main" ]; then
    warn "/etc/ssh/sshd_config is missing; is openssh-server installed?"
    return 0
  fi
  grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$main" 2>/dev/null && return 0
  backup_file "$main"
  if [ "$OPT_DRY_RUN" -eq 0 ]; then
    printf 'Include /etc/ssh/sshd_config.d/*.conf\n\n' | cat - "$main" >"${main}.new"
    mv "${main}.new" "$main"
    chmod 644 "$main"
  fi
  detail "Added the sshd_config.d Include directive"
}

# Ubuntu 24.04 and Debian 13 start sshd through ssh.socket, where the Port
# directive in sshd_config is ignored entirely. The listening port has to be
# changed on the socket unit instead.
ssh_apply_socket_port() {
  systemctl list-unit-files ssh.socket >/dev/null 2>&1 || return 0
  systemctl is-enabled ssh.socket >/dev/null 2>&1 || return 0

  local dir=/etc/systemd/system/ssh.socket.d
  local content
  content="$(printf '[Socket]\nListenStream=\nListenStream=%s' "$OPT_SSH_PORT")"
  write_file "$dir/10-port.conf" 0644 "$content" || true
  run systemctl daemon-reload
  detail "ssh.socket configured to listen on port $OPT_SSH_PORT"
  return 0
}

ssh_restart() {
  local unit="ssh"
  systemctl list-unit-files ssh.service >/dev/null 2>&1 || unit="sshd"

  if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    run systemctl restart ssh.socket || warn "Could not restart ssh.socket."
    run systemctl restart "$unit" || true
  else
    run systemctl restart "$unit" || die "sshd failed to restart. Existing sessions stay open; fix the config before disconnecting."
  fi

  # Existing sessions survive a restart, so a failure here is recoverable, but
  # it must be loud.
  if [ "$OPT_DRY_RUN" -eq 0 ] && ! systemctl is-active --quiet "$unit" \
     && ! systemctl is-active --quiet ssh.socket; then
    die "sshd is not running after the restart. Do not close this session; see: ${LOG_HINT}"
  fi
}

# sshd -t can fail for reasons that have nothing to do with this configuration
# (a broken host key, a bad directive someone else left behind). Rejecting our
# drop-in in that case would silently discard the port change, so when
# validation fails the baseline is tested too and only a genuine regression is
# fatal.
validate_sshd_config() {
  local ours="$1" err

  if err="$(sshd -t 2>&1)"; then
    detail "sshd configuration validated"
    return 0
  fi

  log "sshd -t failed with our drop-in: $err"
  mv "$ours" "${ours}.rejected"

  local baseline_err
  if baseline_err="$(sshd -t 2>&1)"; then
    # The baseline is fine, so the fault is ours. Leave SSH untouched.
    rm -f "${ours}.rejected"
    die "The generated sshd configuration was rejected: ${err}. It has been removed and SSH is unchanged."
  fi

  # The baseline is broken too, so this is pre-existing and not something the
  # drop-in caused. Keep the drop-in and make the real problem visible.
  mv "${ours}.rejected" "$ours"
  warn "sshd reports a pre-existing problem: ${baseline_err}"
  warn "The port drop-in was applied anyway. Fix the above before relying on it."
  return 0
}

fn_ssh() {
  step "SSH access"

  ssh_create_user
  ssh_setup_keys

  local ours=/etc/ssh/sshd_config.d/00-server-init.conf
  ssh_ensure_include
  ssh_neutralise_conflicts "$ours"

  # One directive. Everything this file used to set - PermitRootLogin,
  # PasswordAuthentication, AllowUsers, AuthenticationMethods, MaxAuthTries,
  # the KexAlgorithms/Ciphers/MACs lists - is gone on purpose. Any of them can
  # refuse a login, and an unattended run has nobody to notice.
  local content
  content="$(cat <<CONF
# Managed by setup.sh (Server Initialization Suite) — do not edit by hand.
#
# This file sorts first inside sshd_config.d on purpose: sshd keeps the first
# value it sees for a directive, so nothing later can move the port back.
#
# Port is the only setting managed here. Authentication is left to the system's
# own configuration.

Port $OPT_SSH_PORT
CONF
)"

  # No backup here: this file is fully managed and regenerated from scratch, so
  # a .bak of it carries no information. Backups are for files the system owns.
  write_file "$ours" 0644 "$content" || true

  if [ "$OPT_DRY_RUN" -eq 0 ]; then
    # sshd -t needs the privilege separation directory, which normally only
    # exists once sshd has run at least once.
    mkdir -p /run/sshd
    validate_sshd_config "$ours"
  fi

  ssh_apply_socket_port
  ssh_restart

  ok "sshd listening on port $OPT_SSH_PORT (authentication left unchanged)"

  if [ "$OPT_SSH_PORT" != "22" ]; then
    warn "SSH now listens on port $OPT_SSH_PORT. Verify a new session works before closing this one."
  fi
}

# end-of-module
