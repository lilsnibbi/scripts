#!/usr/bin/env bash
# setup-module: dokploy
# setup-api: 4
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
  [ "$(docker service inspect --format '{{.Spec.Name}}' dokploy 2>/dev/null)" = dokploy ]
}

# Dokploy's installer aborts if anything holds 80, 443 or 3000. Reporting which
# process holds the port is far more useful than its bare error message.
dokploy_check_ports() {
  if ! have ss; then
    if [ "$OPT_DRY_RUN" -eq 1 ]; then return 0; fi
    die "Cannot check Dokploy ports: ss (iproute2) is unavailable."
  fi
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
      detail "Use Dokploy's documented update procedure to upgrade"
      DOKPLOY_INSTALLED=1
      restrict_dokploy_ui
      return 0
    fi
    warn "Reinstalling Dokploy: Docker Swarm will be left and re-initialised."
    restrict_dokploy_ui
    detail "Removing the existing Dokploy services so the ports are free"
    run docker service rm dokploy dokploy-postgres || true
    run docker rm -f dokploy-traefik || true
    sleep 5
  elif has_container_workloads; then
    warn "Existing container/Swarm host detected; skipping Dokploy to preserve its workloads."
    return 0
  fi

  if [ -e /.dockerenv ] || [ -e /run/.containerenv ]; then
    warn "Dokploy cannot be installed inside a Docker/Podman container; skipping."
    return 0
  fi

  if ! have ss; then
    apt_ensure_lists || die "Could not refresh port-check dependency indexes."
    apt_install "port checks" iproute2 || die "Could not install iproute2."
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
    retry curl -fsSL --connect-timeout 20 --max-time 120 https://dokploy.com/install.sh -o "$installer" \
    || { rm -f "$installer"; die "Could not download the Dokploy installer."; }

  # Sanity check: a captive portal or error page must not be piped into a shell.
  if ! head -n1 "$installer" | grep -q '^#!' || ! bash -n "$installer"; then
    rm -f "$installer"
    die "The downloaded Dokploy installer is not a shell script. Aborting rather than executing it."
  fi

  # Install access controls before the first-run administrator UI can bind.
  restrict_dokploy_ui

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

# Filter local-destination traffic before Docker DNAT, including Swarm ingress
# and IPv6 userland-proxy traffic. The loopback interface is explicitly exempt.
restrict_dokploy_ui() {
  local script=/usr/local/sbin/dokploy-ui-firewall cidrs body unit
  cidrs="$(ui_allow_list)"
  if [ "$OPT_UI_PUBLIC" -eq 1 ]; then
    warn "Dokploy UI is public; claim the administrator account immediately."
  fi
  if ! have iptables || ! have ip6tables || ! have iptables-restore || ! have ip6tables-restore; then
    apt_ensure_lists || die "Could not refresh firewall dependency indexes."
    apt_install "Dokploy firewall" iptables || die "Could not install Dokploy firewall tools."
  fi
  body="$(printf '#!/usr/bin/env bash\nset -euo pipefail\nALLOW=%q\nPUBLIC=%q\n' "$cidrs" "$OPT_UI_PUBLIC")
$(cat <<'SCRIPT'
# Managed by setup.sh. Only traffic to this host's TCP port 3000 is filtered.
apply_family() {
  local tool="$1" restore="$2" family="$3" cidr
  # iptables-restore commits a complete chain in one transaction; a failed
  # update retains the previous rules instead of flushing a live allowlist.
  {
    printf '*mangle\n:DOKPLOY-UI - [0:0]\n-F DOKPLOY-UI\n'
    printf -- '-A DOKPLOY-UI -i lo -j RETURN\n'
    if [ "$PUBLIC" -eq 0 ]; then
      if [ "$family" = 4 ]; then
        for cidr in ${ALLOW//,/ }; do
          printf -- '-A DOKPLOY-UI -s %s -j RETURN\n' "$cidr"
        done
      fi
      printf -- '-A DOKPLOY-UI -j DROP\n'
    else
      printf -- '-A DOKPLOY-UI -j RETURN\n'
    fi
    printf 'COMMIT\n'
  } | "$restore" --wait 10 --noflush
  "$tool" -w 10 -t mangle -C PREROUTING -p tcp --dport 3000 -m addrtype --dst-type LOCAL -j DOKPLOY-UI 2>/dev/null \
    || "$tool" -w 10 -t mangle -I PREROUTING 1 -p tcp --dport 3000 -m addrtype --dst-type LOCAL -j DOKPLOY-UI
}
apply_family iptables iptables-restore 4
# A missing IPv6 firewall is fatal when IPv6 is enabled; never silently expose it.
if [ -s /proc/net/if_inet6 ] || [ -d /proc/sys/net/ipv6 ]; then
  apply_family ip6tables ip6tables-restore 6
fi
# Retire the old, post-DNAT IPv4 rule only after the replacement is active.
while iptables -w 10 -C DOCKER-USER -p tcp --dport 3000 -j DOKPLOY-UI 2>/dev/null; do
  iptables -w 10 -D DOCKER-USER -p tcp --dport 3000 -j DOKPLOY-UI
done
SCRIPT
)"
  write_file "$script" 0755 "$body" || true
  unit="$(cat <<UNIT
[Unit]
Description=Restrict Dokploy UI before Docker starts
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$script

[Install]
RequiredBy=docker.service
WantedBy=multi-user.target
UNIT
)"
  write_file /etc/systemd/system/dokploy-ui-firewall.service 0644 "$unit" || true
  run systemctl daemon-reload
  run systemctl enable dokploy-ui-firewall.service || die "Could not enable Dokploy firewall persistence."
  run systemctl restart dokploy-ui-firewall.service \
    || die "Could not apply Dokploy UI protection. Check the host firewall before proceeding."
  if [ "$OPT_UI_PUBLIC" -eq 1 ]; then
    ok "Dokploy UI public access configured"
  elif [ -n "$cidrs" ]; then
    ok "Dokploy UI restricted to: $cidrs (IPv6 blocked)"
  else
    ok "Dokploy UI closed to the network; use an SSH tunnel"
  fi
}

# end-of-module
