#!/usr/bin/env bash
# setup-module: cloudflared
# setup-api: 4
# =============================================================================
#  Component: cloudflared - Install the Cloudflare Zero Trust tunnel daemon
#
#  Sourced by setup.sh, never run on its own. Everything here executes inside
#  the main script's shell: its options (OPT_*), helpers (step, run, run_spin,
#  apt_install, write_file, ok, warn, detail, die, ...) and its error trap.
#  Must define fn_cloudflared. The last line must be the end-of-module marker.
# =============================================================================
[ -n "${SETUP_API:-}" ] || { echo "This is a setup.sh component module; run setup.sh instead." >&2; exit 64; }

fn_cloudflared() {
  step "Cloudflare Tunnel (cloudflared)"

  if have cloudflared; then
    ok "cloudflared already installed: $(cloudflared --version 2>/dev/null | head -n1 || true)"
    return 0
  fi

  run install -m 0755 -d /usr/share/keyrings
  run_spin "Fetching the Cloudflare signing key" \
    retry curl -fsSL --connect-timeout 15 https://pkg.cloudflare.com/cloudflare-public-v2.gpg \
    -o /usr/share/keyrings/cloudflare-public-v2.gpg \
    || { warn "Could not download the Cloudflare GPG key; skipping cloudflared."; return 0; }
  run chmod a+r /usr/share/keyrings/cloudflare-public-v2.gpg

  write_file /etc/apt/sources.list.d/cloudflared.list 0644 \
    "deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main" || true

  if ! apt_update; then
    # Leave no trace: a repository apt cannot reach would make every future
    # apt-get update on this host fail, long after this optional step is gone.
    run rm -f /etc/apt/sources.list.d/cloudflared.list
    warn "apt-get update failed after adding the Cloudflare repository; skipping cloudflared."
    return 0
  fi

  if apt_install "cloudflared" cloudflared; then
    ok "cloudflared installed: $(cloudflared --version 2>/dev/null | head -n1 || echo unknown)"
    detail "Connect it with: sudo cloudflared service install <tunnel-token>"
  else
    warn "cloudflared installation failed; continuing without it."
  fi
}

# end-of-module
