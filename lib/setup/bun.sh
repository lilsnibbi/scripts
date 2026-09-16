#!/usr/bin/env bash
# setup-module: bun
# setup-api: 4
# =============================================================================
#  Component: bun - Install the Bun JavaScript runtime
#
#  Sourced by setup.sh, never run on its own. Everything here executes inside
#  the main script's shell: its options (OPT_*), helpers (step, run, run_spin,
#  apt_install, write_file, ok, warn, detail, die, ...) and its error trap.
#  Must define fn_bun. The last line must be the end-of-module marker.
# =============================================================================
[ -n "${SETUP_API:-}" ] || { echo "This is a setup.sh component module; run setup.sh instead." >&2; exit 64; }

fn_bun() {
  step "Bun runtime"

  resolve_user_home
  local home="$SSH_USER_HOME"
  [ -n "$home" ] || { warn "Could not resolve a home directory for Bun; skipping."; return 0; }

  if [ -x "$home/.bun/bin/bun" ]; then
    ok "Bun already installed for '$OPT_USERNAME': $("$home/.bun/bin/bun" --version 2>/dev/null || echo unknown)"
    return 0
  fi

  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    detail "Would install Bun into $home/.bun"
    return 0
  fi

  # Same rule as the Dokploy installer: fetch to a file and make sure it is a
  # script before running it, never pipe the network straight into a shell.
  local installer
  installer="$(mktemp)"
  if ! run_spin "Downloading the Bun installer" \
        retry curl -fsSL --connect-timeout 20 --max-time 120 https://bun.sh/install -o "$installer" \
     || ! head -n1 "$installer" | grep -q '^#!' || ! bash -n "$installer"; then
    rm -f "$installer"
    warn "Could not download the Bun installer; continuing without Bun."
    return 0
  fi
  # mktemp creates the file readable by root only; the login account runs it.
  chmod 644 "$installer"

  # The installer needs unzip, installed in preflight, and writes to $HOME;
  # both the home and the target are pinned rather than left to whatever
  # runuser passes through.
  if run_spin "Installing Bun for '$OPT_USERNAME'" \
      runuser -u "$OPT_USERNAME" -- env HOME="$home" BUN_INSTALL="$home/.bun" bash "$installer"; then
    ok "Bun installed: $("$home/.bun/bin/bun" --version 2>/dev/null || echo unknown)"
    detail "Available in new shells; run 'source ~/.bashrc' in this one"
  else
    warn "Bun installation failed; continuing without it."
  fi
  rm -f "$installer"
}

# end-of-module
