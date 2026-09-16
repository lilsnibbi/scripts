#!/usr/bin/env bash
# setup-module: ssh
# setup-api: 6
# =============================================================================
#  Component: ssh - Create the login account and set the SSH port
#
#  Configure the account and port, preserving authentication by default.
#  On eligible --local computers a Match block permits the selected account's
#  existing password from RFC1918 sources. Configuration changes are rolled
#  back if syntax, effective-policy validation or the service restart fails.
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

  [ ! -L "$dir" ] && [ ! -L "$file" ] || die "Refusing to change symlinked SSH key paths."

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
    # Preserve the last existing key when its line has no terminating newline.
    if [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then printf '\n' >>"$file"; fi
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

# Port directives accumulate. Replace them only when the caller explicitly
# asks for a different port; all authentication directives remain untouched.
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
  ssh_write_file "$dir/10-port.conf" 0644 "$content"
  run systemctl daemon-reload
  detail "ssh.socket configured to listen on port $OPT_SSH_PORT"
  return 0
}

ssh_restart() {
  local unit="ssh"
  systemctl list-unit-files ssh.service >/dev/null 2>&1 || unit="sshd"

  if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    run systemctl restart ssh.socket || die "Could not restart ssh.socket."
    run systemctl restart "$unit" || die "Could not restart $unit."
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

ssh_write_file() {
  if [ -f "$1" ] && [ "$(cat "$1")" = "$3" ]; then return 0; fi
  if [ "$OPT_DRY_RUN" -eq 1 ]; then log "would write: $1"; return 0; fi
  mkdir -p "$(dirname "$1")" || die "Could not create SSH configuration directory."
  printf '%s\n' "$3" >"$1" || die "Could not write SSH configuration: $1"
  chmod "$2" "$1" || die "Could not set SSH configuration permissions: $1"
}

# Keep Match out of the global drop-in: its scope would otherwise leak into
# subsequent global-only directives. Insert before the main file's first Match,
# after global settings, and remove exactly our marked block on a normal rerun.
ssh_local_config() {
  local enabled="$1" user="$2"
  awk -v enabled="$enabled" -v user="$user" -v cidrs="$UI_LOCAL_CIDRS" '
    function emit() {
      if (enabled != 1 || emitted) return
      print "# BEGIN setup.sh local SSH"
      print "Match User " user " Address " cidrs
      print "    PasswordAuthentication yes"
      # Explicit alternatives avoid OpenSSH bug 3657 (any after a non-any
      # global AuthenticationMethods fails on Ubuntu 22.04/24.04).
      print "    AuthenticationMethods publickey password"
      print "    PubkeyAuthentication yes"
      print "    PermitEmptyPasswords no"
      if (user == "root") print "    PermitRootLogin yes"
      print "Match all"
      print "# END setup.sh local SSH"
      emitted=1
    }
    $0 == "# BEGIN setup.sh local SSH" { if (inside) exit 65; inside=1; next }
    $0 == "# END setup.sh local SSH" { if (!inside) exit 65; inside=0; next }
    inside { next }
    tolower($1) == "match" { emit() }
    { print }
    END { if (inside) exit 65; emit() }
  '
}

# Run in a subshell so this transaction's traps cannot replace framework traps.
ssh_configure() (
  local ours=/etc/ssh/sshd_config.d/00-server-init.conf
  local auth=/etc/ssh/sshd_config.d/00-server-init-auth.conf
  local main=/etc/ssh/sshd_config
  local snapshot="" committed=0 restarting=0 f i content err rc=0 restore_failed=0
  local -a paths=()
  if [ "$OPT_SSH_PORT_SET" -eq 0 ]; then
    # Leave all existing ports and socket addresses intact on normal reruns.
    detail "Preserving existing SSH listening configuration"
  fi
  if [ "$OPT_DRY_RUN" -eq 0 ]; then
    mkdir -p /run/sshd
    if ! err="$(sshd -t 2>&1)"; then
      die "Existing sshd configuration is invalid; SSH was not changed: $err"
    fi
    paths=("$main" "$ours" "$auth" /etc/systemd/system/ssh.socket.d/10-port.conf)
    for f in /etc/ssh/sshd_config.d/*.conf; do
      [ -f "$f" ] && [ "$f" != "$ours" ] && [ "$f" != "$auth" ] && paths+=("$f")
    done
    for f in "${paths[@]}"; do
      [ ! -L "$f" ] || die "Refusing to rewrite symlinked SSH configuration: $f"
    done
    snapshot="$(mktemp -d)"
    # Arm rollback only after every snapshot has been made successfully.
    for i in "${!paths[@]}"; do
      f="${paths[$i]}"
      if [ -e "$f" ]; then cp -p "$f" "$snapshot/$i"; fi
    done
    trap '
      rc=$?
      trap - EXIT ERR INT TERM
      if [ "$committed" -eq 0 ]; then
        restore_failed=0
        for i in "${!paths[@]}"; do
          f="${paths[$i]}"
          if [ -e "$snapshot/$i" ]; then
            cp -p "$snapshot/$i" "$f" || restore_failed=1
          else
            rm -f "$f" || restore_failed=1
          fi
        done
        if [ "$restore_failed" -eq 1 ]; then
          warn "SSH rollback was incomplete. Recovery copies are in $snapshot; keep this session open."
          exit 1
        fi
        if [ "$restarting" -eq 1 ]; then
          systemctl daemon-reload >&4 2>&1 || true
          if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
            systemctl restart ssh.socket >&4 2>&1 || true
          fi
          systemctl restart ssh >&4 2>&1 || systemctl restart sshd >&4 2>&1 || true
        fi
        warn "SSH configuration restored after failure. Keep this session open and verify access."
      fi
      rm -r -- "$snapshot"
      exit "$rc"
    ' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
  fi

  if [ "$OPT_SSH_PORT_SET" -eq 1 ] || [ "$OPT_SSH_KEY_ONLY" -eq 1 ]; then
    ssh_ensure_include
  fi
  if [ "$OPT_SSH_PORT_SET" -eq 1 ]; then
    ssh_neutralise_conflicts "$ours"
  fi

  if [ "$OPT_SSH_KEY_ONLY" -eq 1 ]; then
    ssh_write_file "$auth" 0644 '# Managed by setup.sh. Explicit --ssh-key-only policy.
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
PermitRootLogin prohibit-password'
  fi

  # Global port settings must stay outside the conditional LAN policy.
  content="$(cat <<CONF
# Managed by setup.sh (Server Initialization Suite) — do not edit by hand.
#
# Other Port directives were disabled to avoid accumulating old listeners.
#
# Port is the only setting in this drop-in. An eligible --local exception is
# managed separately at the end of the main config's global section.

Port $OPT_SSH_PORT
CONF
)"

  # No backup here: this file is fully managed and regenerated from scratch, so
  # a .bak of it carries no information. Backups are for files the system owns.
  if [ "$OPT_SSH_PORT_SET" -eq 1 ]; then ssh_write_file "$ours" 0644 "$content"; fi

  if [ "$OPT_DRY_RUN" -eq 0 ]; then
    content="$(ssh_local_config "$LOCAL_ACCESS_ENABLED" "$OPT_USERNAME" <"$main")" \
      || die "Malformed managed local SSH block; refusing to change it."
    # Write failures must abort the transaction; write_file returns 1 for an
    # unchanged file, so compare first instead of masking its write failures.
    if [ "$(cat "$main")" != "$content" ]; then
      printf '%s\n' "$content" >"$main"
    fi
    if ! err="$(sshd -t 2>&1)"; then die "Generated sshd configuration is invalid: $err"; fi
    if local_access_enabled; then
      ssh_validate_local_policy
    fi
    if [ "$OPT_SSH_KEY_ONLY" -eq 1 ]; then ssh_validate_key_policy; fi
    detail "sshd configuration validated"
  elif local_access_enabled; then
    detail "Would enable RFC1918 SSH password login for '$OPT_USERNAME'"
  fi

  if [ "$OPT_SSH_PORT_SET" -eq 1 ]; then
    # Keep the new port reachable even if the later firewall component fails
    # or was excluded. Existing rules and the old access path remain intact.
    if have ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
      run ufw allow "${OPT_SSH_PORT}/tcp" comment SSH \
        || die "Could not allow the new SSH port before restarting sshd."
    fi
    ssh_apply_socket_port
  fi
  if [ "$OPT_DRY_RUN" -eq 0 ]; then
    local changed=0
    for i in "${!paths[@]}"; do
      f="${paths[$i]}"
      if [ -e "$snapshot/$i" ]; then
        cmp -s "$snapshot/$i" "$f" || changed=1
      elif [ -e "$f" ]; then
        changed=1
      fi
    done
    if [ "$changed" -eq 0 ] && { systemctl is-active --quiet ssh || systemctl is-active --quiet sshd; }; then
      committed=1
      detail "SSH configuration unchanged; no restart needed"
      return 0
    fi
  fi
  restarting=1
  ssh_restart
  committed=1
)

ssh_validate_key_policy() {
  local addr effective root_policy connection="${SSH_CONNECTION:-}"
  # Include the current source when available; representative addresses also
  # catch common Match blocks. No local check proves real authentication.
  for addr in 198.51.100.1 10.0.0.1 2001:db8::1 ${connection%% *}; do
    effective="$(sshd -T -C "user=$OPT_USERNAME,addr=$addr,host=$addr" 2>&1)" \
      || die "Could not evaluate key-only SSH policy: $effective"
    grep -qx 'pubkeyauthentication yes' <<<"$effective" \
      && grep -qx 'passwordauthentication no' <<<"$effective" \
      && grep -qx 'kbdinteractiveauthentication no' <<<"$effective" \
      && grep -qx 'authenticationmethods publickey' <<<"$effective" \
      || die "Existing SSH configuration overrides the requested key-only policy for $addr."
    root_policy="$(sshd -T -C "user=root,addr=$addr,host=$addr" 2>&1)" \
      || die "Could not evaluate root SSH policy."
    grep -qEx 'permitrootlogin (prohibit-password|without-password)' <<<"$root_policy" \
      && grep -qx 'pubkeyauthentication yes' <<<"$root_policy" \
      && grep -qx 'authenticationmethods publickey' <<<"$root_policy" \
      || die "Existing SSH configuration prevents the requested root key access for Dokploy at $addr."
  done
}

ssh_validate_local_policy() {
  local addr effective
  for addr in 10.0.0.1 172.16.0.1 192.168.0.1; do
    effective="$(sshd -T -C "user=$OPT_USERNAME,addr=$addr,host=$addr" 2>&1)" \
      || die "Could not evaluate local SSH policy: $effective"
    if ! grep -qx 'passwordauthentication yes' <<<"$effective" \
       || ! grep -qx 'authenticationmethods publickey password' <<<"$effective" \
       || ! grep -qx 'pubkeyauthentication yes' <<<"$effective" \
       || ! grep -qx 'permitemptypasswords no' <<<"$effective"; then
      die "An existing Match rule overrides the LAN SSH exception for $addr."
    fi
    if [ "$OPT_USERNAME" = root ] && ! grep -qx 'permitrootlogin yes' <<<"$effective"; then
      die "An existing Match rule blocks root LAN SSH login."
    fi
  done
}

fn_ssh() {
  step "SSH access"
  if ! have sshd || ! have visudo; then
    apt_ensure_lists || die "Could not refresh SSH dependency indexes."
    apt_install "SSH and sudo" openssh-server openssh-client sudo || die "Could not install SSH dependencies."
  fi
  if [ -n "$OPT_PUBKEY" ] && [ "$OPT_DRY_RUN" -eq 0 ]; then
    ssh-keygen -lf /dev/stdin <<<"$OPT_PUBKEY" >&4 2>&1 || die "The supplied public key is invalid."
  fi
  ssh_create_user
  ssh_setup_keys
  ssh_configure

  if local_access_enabled; then
    ok "sshd port $OPT_SSH_PORT: LAN password login enabled for '$OPT_USERNAME'"
    if [ "$OPT_DRY_RUN" -eq 0 ] && [ "$(passwd -S "$OPT_USERNAME" | awk '{print $2}')" != P ]; then
      warn "'$OPT_USERNAME' needs an unlocked password: run 'sudo passwd $OPT_USERNAME'. No password was set or unlocked by setup."
    fi
  elif [ "$OPT_SSH_KEY_ONLY" -eq 1 ]; then
    ok "sshd listening on port $OPT_SSH_PORT (keys required; root keys permitted)"
  else
    ok "sshd listening on port $OPT_SSH_PORT (system authentication preserved)"
  fi

  if [ "$OPT_SSH_KEY_ONLY" -eq 1 ]; then
    warn "SSH now requires keys; root key login remains available for Dokploy. Keep this session and provider console access until a new $OPT_USERNAME login works."
  fi

  if [ "$OPT_SSH_PORT_SET" -eq 1 ]; then
    warn "SSH now listens on port $OPT_SSH_PORT. Verify a new session works before closing this one."
  fi
}

# end-of-module
