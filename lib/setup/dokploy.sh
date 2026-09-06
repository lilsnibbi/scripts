#!/usr/bin/env bash
# setup-module: dokploy
# setup-api: 2
# =============================================================================
#  Component: dokploy - Install the Dokploy PaaS platform
#
#  Sourced by setup.sh, never run on its own. Everything here executes inside
#  the main script's shell: its options (OPT_*), helpers (step, run, run_spin,
#  apt_install, write_file, ok, warn, detail, die, ...) and its error trap.
#  Must define fn_dokploy. The last line must be the end-of-module marker.
# =============================================================================
[ -n "${SETUP_API:-}" ] || { echo "This is a setup.sh component module; run setup.sh instead." >&2; exit 64; }

dokploy_is_installed() {
  have docker || return 1
  docker info 2>/dev/null | grep -q 'Swarm: active' || return 1
  [ -n "$(docker service ls --filter name=dokploy --quiet 2>/dev/null)" ]
}

# Dokploy's installer aborts if anything holds 80, 443 or 3000. Reporting which
# process holds the port is far more useful than its bare error message.
dokploy_check_ports() {
  local port busy=0
  for port in 80 443 3000; do
    if ss -tulnp 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"; then
      local holder
      holder="$(ss -tulnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | head -n1 | sed 's/.*users:((//' | cut -d, -f1 | tr -d '("' || true)"
      warn "Port ${port} is already in use by: ${holder:-unknown}"
      busy=1
    fi
  done
  return $busy
}

fn_dokploy() {
  step "Dokploy"

  if ! have docker; then
    if [ "$OPT_DRY_RUN" -eq 1 ]; then
      detail "Would install Dokploy once Docker is present"
      return 0
    fi
    warn "Docker is not installed, so Dokploy cannot be installed. Re-run without --exclude=docker."
    return 0
  fi

  if dokploy_is_installed; then
    if [ "$OPT_REINSTALL_DOKPLOY" -eq 0 ]; then
      ok "Dokploy is already installed; leaving it untouched"
      detail "Re-running the installer would leave and re-initialise Docker Swarm"
      detail "Use --reinstall-dokploy to force it, or 'dokploy update' to upgrade"
      DOKPLOY_INSTALLED=1
      restrict_dokploy_ui
      return 0
    fi
    warn "Reinstalling Dokploy: Docker Swarm will be left and re-initialised."
    detail "Removing the existing Dokploy services so the ports are free"
    run docker service rm dokploy dokploy-postgres || true
    run docker rm -f dokploy-traefik || true
    sleep 5
  fi

  if ! dokploy_check_ports; then
    warn "Skipping Dokploy because required ports are occupied. Free 80, 443 and 3000, then re-run with --only=dokploy."
    return 0
  fi

  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    # Deliberately does not set DOKPLOY_INSTALLED: the summary reports what is
    # on the machine, and a dry run installs nothing.
    detail "Would run the Dokploy installer"
    return 0
  fi

  local installer
  installer="$(mktemp)"
  run_spin "Downloading the Dokploy installer" \
    retry curl -fsSL --connect-timeout 20 https://dokploy.com/install.sh -o "$installer" \
    || { rm -f "$installer"; die "Could not download the Dokploy installer."; }

  # Sanity check: a captive portal or error page must not be piped into a shell.
  if ! head -n1 "$installer" | grep -q '^#!'; then
    rm -f "$installer"
    die "The downloaded Dokploy installer is not a shell script. Aborting rather than executing it."
  fi

  info "Running the Dokploy installer (pulls several images; expect 2-5 minutes)"
  if run_spin "Installing Dokploy" bash "$installer"; then
    DOKPLOY_INSTALLED=1
    ok "Dokploy installed"
  else
    rm -f "$installer"
    die "The Dokploy installer failed. See: ${LOG_HINT}"
  fi
  rm -f "$installer"

  wait_for_dokploy
  restrict_dokploy_ui
}

# The swarm service needs a moment to pull and start. Confirming the UI answers
# turns a silent half-finished install into a visible warning.
wait_for_dokploy() {
  local waited=0
  while [ $waited -lt 90 ]; do
    if curl -fsS --max-time 3 -o /dev/null http://127.0.0.1:3000 2>/dev/null; then
      ok "Dokploy UI responding on port 3000"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  warn "Dokploy did not answer on port 3000 within 90s. Check 'docker service ls' and 'docker service logs dokploy'."
  return 0
}

# Restrict the Dokploy UI to specific sources.
#
# UFW cannot do this: Docker's iptables rules run first. The rule has to live in
# the DOCKER-USER chain, and is re-applied at boot by a systemd unit because
# iptables rules do not persist.
# Port 3000 is closed to the internet unless somebody asks for it.
#
# The first visitor to reach an unclaimed Dokploy UI becomes its administrator,
# which makes "reachable by default" the wrong default at any scale: the window
# between this script finishing and a human logging in is exactly the window an
# internet-wide scanner needs. Loopback is unaffected either way - a published
# port reached over 127.0.0.1 never traverses the FORWARD chain - so an SSH
# tunnel still works with no rules at all.
restrict_dokploy_ui() {
  if [ "$OPT_UI_PUBLIC" -eq 1 ]; then
    warn "The Dokploy UI on port 3000 is reachable from the whole internet (--ui-public)."
    detail "Whoever opens it first creates the admin account. Do it now."
    return 0
  fi

  local script=/usr/local/sbin/dokploy-ui-firewall
  local cidrs
  cidrs="$(ui_allow_list)"
  local body
  body="$(cat <<SCRIPT
#!/usr/bin/env bash
# Managed by setup.sh. Restricts the Dokploy UI (port 3000) to allowed sources.
# Docker bypasses UFW, so the rule must sit in the DOCKER-USER chain.
set -euo pipefail

ALLOW="$cidrs"

iptables -N DOKPLOY-UI 2>/dev/null || iptables -F DOKPLOY-UI
for cidr in \${ALLOW//,/ }; do
  iptables -A DOKPLOY-UI -s "\$cidr" -j RETURN
done
iptables -A DOKPLOY-UI -j DROP

iptables -C DOCKER-USER -p tcp --dport 3000 -j DOKPLOY-UI 2>/dev/null \\
  || iptables -I DOCKER-USER -p tcp --dport 3000 -j DOKPLOY-UI
SCRIPT
)"

  write_file "$script" 0755 "$body" || true

  local unit
  unit="$(cat <<UNIT
[Unit]
Description=Restrict the Dokploy UI port to allowed sources
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$script

[Install]
WantedBy=multi-user.target
UNIT
)"
  write_file /etc/systemd/system/dokploy-ui-firewall.service 0644 "$unit" || true

  run systemctl daemon-reload
  run systemctl enable dokploy-ui-firewall.service || true
  if run systemctl restart dokploy-ui-firewall.service; then
    if [ -n "$cidrs" ]; then
      ok "Dokploy UI on port 3000 restricted to: $cidrs"
    else
      ok "Dokploy UI on port 3000 closed to the network"
      detail "Reach it over an SSH tunnel, the Cloudflare tunnel, or reopen it with:"
      detail "  sudo ./setup.sh --only=dokploy --local            (your LAN)"
      detail "  sudo ./setup.sh --only=dokploy --ui-allow=<ip>/32 (one address)"
    fi
  else
    warn "Could not apply the port 3000 restriction; the UI may be publicly reachable."
  fi
}

# end-of-module
