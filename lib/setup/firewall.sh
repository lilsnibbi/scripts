#!/usr/bin/env bash
# setup-module: firewall
# setup-api: 5
# =============================================================================
#  Component: firewall - Configure the UFW firewall
#
#  Sourced by setup.sh, never run on its own. Everything here executes inside
#  the main script's shell: its options (OPT_*), helpers (step, run, run_spin,
#  apt_install, write_file, ok, warn, detail, die, ...) and its error trap.
#  Must define fn_firewall. The last line must be the end-of-module marker.
# =============================================================================
[ -n "${SETUP_API:-}" ] || { echo "This is a setup.sh component module; run setup.sh instead." >&2; exit 64; }

fn_firewall() {
  step "Firewall (UFW)"

  if [ "$OPT_RESET_FIREWALL" -eq 0 ] && has_container_workloads; then
    step_skip "Existing container host: firewall policy preserved"
    return 0
  fi

  # An inactive firewall on an already-serving machine is not a fresh install.
  # Preserve access to panels, game servers and other host services by default.
  if [ "$OPT_RESET_FIREWALL" -eq 0 ] && have ss; then
    local listeners port
    listeners="$(ss -H -lntu 2>/dev/null | awk '{print $5}' || true)"
    for port in $listeners; do
      case "$port" in 127.*|\[::1\]:*|::1:*) continue ;; esac
      port="${port##*:}"
      case "$port" in 22|80|443|"$OPT_SSH_PORT") continue ;; esac
      step_skip "Existing service on port $port: firewall policy preserved"
      return 0
    done
  fi

  if ! have ufw; then
    apt_ensure_lists || true
    apt_install "ufw" ufw || die "Could not install ufw."
  fi

  # The first ufw call is where a kernel that cannot load iptables - some
  # unprivileged containers - shows up. Say what to do rather than tracing a
  # bare exit code.
  local ufw_fail="UFW could not apply its rules. If a host firewall guards this machine (a Proxmox container, say), re-run with --skip=firewall. See: ${LOG_HINT}"

  if [ "$OPT_RESET_FIREWALL" -eq 1 ]; then
    run_sh "ufw --force reset" || die "$ufw_fail"
    warn "Existing UFW rules were wiped by --reset-firewall."
  fi

  if ! ufw status 2>/dev/null | grep -qi '^Status: active'; then
    run_sh "ufw default deny incoming" || die "$ufw_fail"
    run_sh "ufw default allow outgoing"
  fi

  # Allow SSH before enabling; ufw limit also rate-limits repeat connections.
  local ssh_port
  for ssh_port in ${SSH_LISTEN_PORTS:-$OPT_SSH_PORT}; do
    run ufw allow "${ssh_port}/tcp" comment SSH
  done
  ok "Existing SSH listening ports allowed"

  if is_enabled dokploy; then
    run_sh "ufw allow 80/tcp comment 'HTTP (Traefik)'"
    run_sh "ufw allow 443/tcp comment 'HTTPS (Traefik)'"
    run_sh "ufw allow 443/udp comment 'HTTP/3 (Traefik)'"
    # 3000 is the admin UI, not application traffic, so it is not opened just
    # because Dokploy is being installed. --ui-public opts into that.
    if [ "$OPT_UI_PUBLIC" -eq 1 ]; then
      run_sh "ufw allow 3000/tcp comment 'Dokploy UI (--ui-public)'"
      ok "Opened 80/tcp, 443/tcp, 443/udp and 3000/tcp for Dokploy"
    else
      ok "Opened 80/tcp, 443/tcp and 443/udp for Dokploy"
    fi
  fi

  run_sh "ufw --force enable" || die "$ufw_fail"
  ok "UFW enabled"

  # This is not a footnote. Docker inserts its own iptables rules ahead of
  # UFW's, so a published container port is reachable even when UFW claims to
  # deny it. The --ui-allow handling in the Dokploy step is what actually
  # restricts port 3000. Stated as a detail, not a warning: it is true of every
  # Docker host and nothing about this run made it so.
  detail "Docker publishes container ports around UFW; published ports stay open"
}

# end-of-module
