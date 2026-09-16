#!/usr/bin/env bash
# setup-module: firewall
# setup-api: 6
# =============================================================================
#  Component: firewall - Configure the UFW firewall
#
#  Sourced by setup.sh, never run on its own. Everything here executes inside
#  the main script's shell: its options (OPT_*), helpers (step, run, run_spin,
#  apt_install, write_file, ok, warn, detail, die, ...) and its error trap.
#  Must define fn_firewall. The last line must be the end-of-module marker.
# =============================================================================
[ -n "${SETUP_API:-}" ] || { echo "This is a setup.sh component module; run setup.sh instead." >&2; exit 64; }

lockdown_preflight() {
  local iface source cidr local_address local_iface allowed=0
  for iface in ${OPT_LOCKDOWN_INTERFACES//,/ }; do
    ip link show dev "$iface" >/dev/null 2>&1 || die "Lockdown interface does not exist: $iface"
  done
  if [ -n "${SSH_CONNECTION:-}" ]; then
    source="${SSH_CONNECTION%% *}"
    local_address="$(awk '{print $3}' <<<"$SSH_CONNECTION")"
    local_iface="$(ip -o address show | awk -v address="$local_address" '
      {split($4, a, "/"); if (a[1] == address) {split($2, device, "@"); print device[1]; exit}}')"
    # An SSH session addressed to a separate VPN/private interface remains
    # outside this guard. Unknown interface ownership must not imply safety.
    if [ -n "$local_iface" ]; then
      case ",$OPT_LOCKDOWN_INTERFACES," in
        *,"$local_iface",*) ;;
        *) allowed=1 ;;
      esac
    fi
    if [ "$OPT_SSH_ALLOW" != none ]; then
      for cidr in ${OPT_SSH_ALLOW//,/ }; do
        if ipv4_in_cidr "$source" "$cidr"; then allowed=1; fi
      done
    fi
    [ "$allowed" -eq 1 ] || die "Current SSH source $source is not allowed by lockdown. Use a matching IPv4 allowlist, a verified private interface or the provider console."
  else
    warn "Lockdown cannot verify the current SSH source. Keep provider console access; only the configured IPv4 sources can open SSH sessions."
  fi
  detail "Public ingress lockdown: $OPT_LOCKDOWN_INTERFACES; SSH sources: $OPT_SSH_ALLOW"
}

# Restrict the explicitly named public interfaces before DNAT, covering both
# host services and forwarded/published container ports. Docker bridge/overlay
# traffic stays on its own interfaces; do not exempt packets by private source IP.
configure_ingress_guard() {
  local script=/usr/local/sbin/server-init-ingress body unit
  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    detail "Would install persistent ingress lockdown before starting services"
    return 0
  fi
  if ! have iptables || ! have ip6tables || ! have iptables-restore || ! have ip6tables-restore; then
    apt_ensure_lists || die "Could not refresh ingress firewall dependencies."
    apt_install "ingress firewall" iptables || die "Could not install ingress firewall tools."
  fi
  body="$(printf '#!/usr/bin/env bash\nset -euo pipefail\nINTERFACES=%q\nALLOW=%q\nPORTS=%q\n' \
    "$OPT_LOCKDOWN_INTERFACES" "$OPT_SSH_ALLOW" "${SSH_GUARD_PORTS:-$OPT_SSH_PORT}")
$(cat <<'SCRIPT'
# Managed by setup.sh. --check verifies without altering live rules.
mode="${1:-apply}"
[[ "$mode" = apply || "$mode" = --check ]] || exit 64
rule() {
  expected=$((expected + 1))
  if [ "$mode" = --check ]; then
    "$tool" -w 10 -t mangle -C SERVER-INIT-IN "$@"
  else
    printf -- '-A SERVER-INIT-IN'
    printf ' %s' "$@"
    printf '\n'
  fi
}
rules() {
  local cidr port
  rule -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  rule -m conntrack --ctstate INVALID -j DROP
  if [ "$family" = 4 ]; then
    rule -p udp --sport 67 --dport 68 -j RETURN
    rule -p icmp -j RETURN
    if [ "$ALLOW" != none ]; then
      for cidr in ${ALLOW//,/ }; do
        for port in $PORTS; do
          rule -p tcp -s "$cidr" --dport "$port" -m addrtype --dst-type LOCAL -j RETURN
        done
      done
    fi
  else
    rule -p udp --sport 547 --dport 546 -j RETURN
    # IPv6 neighbour discovery, path MTU and other control traffic must work.
    rule -p ipv6-icmp -j RETURN
  fi
  rule -j DROP
}
apply_family() {
  local tool="$1" restore="$2" family="$3" iface expected=0 count
  if [ "$mode" = --check ]; then
    rules
    count="$("$tool" -w 10 -t mangle -S SERVER-INIT-IN | grep -c '^-A ')"
    [ "$count" -eq "$expected" ]
    for iface in ${INTERFACES//,/ }; do
      "$tool" -w 10 -t mangle -C PREROUTING -i "$iface" -j SERVER-INIT-IN
    done
    return 0
  fi
  {
    printf '*mangle\n:SERVER-INIT-IN - [0:0]\n-F SERVER-INIT-IN\n'
    rules
    for iface in ${INTERFACES//,/ }; do
      if ! "$tool" -w 10 -t mangle -C PREROUTING -i "$iface" -j SERVER-INIT-IN 2>/dev/null; then
        printf -- '-I PREROUTING 1 -i %s -j SERVER-INIT-IN\n' "$iface"
      fi
    done
    printf 'COMMIT\n'
  } | "$restore" --wait 10 --noflush
}
apply_family iptables iptables-restore 4
if [ -s /proc/net/if_inet6 ] || [ -d /proc/sys/net/ipv6 ]; then
  apply_family ip6tables ip6tables-restore 6
fi
SCRIPT
)"
  write_file "$script" 0755 "$body" || true
  unit="$(cat <<UNIT
[Unit]
Description=Block public service ingress before Docker destination translation
DefaultDependencies=no
After=local-fs.target systemd-modules-load.service
Before=network-pre.target docker.service ssh.service ssh.socket shutdown.target
Wants=network-pre.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$script
ExecReload=$script

[Install]
WantedBy=multi-user.target
RequiredBy=docker.service ssh.service ssh.socket
UNIT
)"
  write_file /etc/systemd/system/server-init-ingress.service 0644 "$unit" || true
  run systemctl daemon-reload
  run systemctl enable server-init-ingress.service || die "Could not enable ingress firewall persistence."
  run systemctl reload-or-restart server-init-ingress.service || die "Ingress lockdown failed; do not proceed with installation."
  run "$script" --check || die "Ingress lockdown rules did not verify."
  ok "Public interfaces restricted; only allowlisted IPv4 SSH, established replies and network control traffic permitted"
}

fn_firewall() {
  step "Firewall (UFW)"

  if [ "$OPT_RESET_FIREWALL" -eq 0 ] && has_container_workloads; then
    step_skip "Existing container host: firewall policy preserved"
    return 0
  fi

  # An inactive firewall on an already-serving machine is not a fresh install.
  # Preserve access to panels, game servers and other host services by default.
  if [ "$OPT_RESET_FIREWALL" -eq 0 ] && have ss; then
    local listeners port protocol
    listeners="$(ss -H -lntu 2>/dev/null | awk '{print $1, $5}' || true)"
    while read -r protocol port; do
      [ -n "$port" ] || continue
      case "$port" in 127.*|\[::1\]:*|::1:*) continue ;; esac
      port="${port##*:}"
      # DHCP clients and time synchronisation are normal on fresh servers.
      case "$protocol:$port" in udp:68|udp:546|udp:123) continue ;; esac
      case "$port" in 22|80|443|"$OPT_SSH_PORT") continue ;; esac
      step_skip "Existing service on port $port: firewall policy preserved"
      return 0
    done <<<"$listeners"
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

  # Allow SSH before enabling. The pre-DNAT guard independently constrains
  # sources even when existing UFW rules are broader.
  local ssh_port cidr
  for ssh_port in ${SSH_GUARD_PORTS:-$OPT_SSH_PORT}; do
    if [ -n "$OPT_LOCKDOWN_INTERFACES" ]; then
      if [ "$OPT_SSH_ALLOW" != none ]; then
        for cidr in ${OPT_SSH_ALLOW//,/ }; do
          run ufw allow from "$cidr" to any port "$ssh_port" proto tcp comment SSH
        done
      fi
      if is_enabled dokploy; then
        # Dokploy's host terminal connects to its Docker gateway over SSH.
        # Interface-bound rules cannot be used by spoofed public source IPs.
        run ufw allow in on docker_gwbridge to any port "$ssh_port" proto tcp comment 'Dokploy host SSH'
        run ufw allow in on docker0 to any port "$ssh_port" proto tcp comment 'Dokploy host SSH'
      fi
    else
      run ufw allow "${ssh_port}/tcp" comment SSH
    fi
  done
  ok "Existing SSH listening ports allowed"

  if is_enabled dokploy && [ -z "$OPT_LOCKDOWN_INTERFACES" ]; then
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
  FIREWALL_APPLIED=1
  ok "UFW enabled"

  # This is not a footnote. Docker inserts its own iptables rules ahead of
  # UFW's, so a published container port is reachable even when UFW claims to
  # deny it. The --ui-allow handling in the Dokploy step is what actually
  # restricts port 3000. Stated as a detail, not a warning: it is true of every
  # Docker host and nothing about this run made it so.
  if [ -n "$OPT_LOCKDOWN_INTERFACES" ]; then
    detail "Public container ports are blocked by the separate ingress guard"
  else
    detail "Docker publishes container ports around UFW; published ports stay open"
  fi
}

# end-of-module
