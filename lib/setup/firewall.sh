#!/usr/bin/env bash
# setup-module: firewall
# setup-api: 2
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

  if ! have ufw; then
    apt_ensure_lists || true
    apt_install "ufw" ufw || die "Could not install ufw."
  fi

  # The first ufw call is where a kernel that cannot load iptables - some
  # unprivileged containers - shows up. Say what to do rather than tracing a
  # bare exit code.
  local ufw_fail="UFW could not apply its rules. If a host firewall guards this machine (a Proxmox container, say), re-run with --exclude=firewall. See: ${LOG_HINT}"

  if [ "$OPT_RESET_FIREWALL" -eq 1 ]; then
    run_sh "ufw --force reset" || die "$ufw_fail"
    warn "Existing UFW rules were wiped by --reset-firewall."
  fi

  run_sh "ufw default deny incoming" || die "$ufw_fail"
  run_sh "ufw default allow outgoing"

  # Allow SSH before enabling; ufw limit also rate-limits repeat connections.
  run_sh "ufw limit ${OPT_SSH_PORT}/tcp comment 'SSH'"
  ok "SSH allowed and rate-limited on ${OPT_SSH_PORT}/tcp"

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
      run_sh "ufw delete allow 3000/tcp" || true
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
