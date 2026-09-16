#!/usr/bin/env bash
# setup-module: tuning
# setup-api: 5
# =============================================================================
#  Component: tuning - Performance tuning: network stack, limits, power, CPU
#  governor
#
#  Performance settings that must be safe wherever the script lands: a Proxmox
#  VM or container, a KVM guest, a VPS, a dedicated box, or a laptop pressed
#  into service as a server. Nothing here assumes an environment; each piece
#  probes for what it needs and skips itself, with a note, when the machine
#  does not have it.
#
#  Sourced by setup.sh, never run on its own. Everything here executes inside
#  the main script's shell: its options (OPT_*), helpers (step, run, run_spin,
#  apt_install, write_file, ok, warn, detail, die, ...) and its error trap.
#  Must define fn_tuning. The last line must be the end-of-module marker.
# =============================================================================
[ -n "${SETUP_API:-}" ] || { echo "This is a setup.sh component module; run setup.sh instead." >&2; exit 64; }

fn_tuning() {
  step "Performance tuning"

  tune_sysctl
  tune_power
  tune_cpu_governor
  tune_ubuntu_noise
  tune_remove_snapd
}

tune_sysctl() {
  # BBR ships as a module in every supported kernel, but is only written to
  # the config once the kernel actually offers it: a sysctl the kernel cannot
  # satisfy would make every future 'sysctl --system' report an error.
  local bbr=""
  if ! in_container; then run modprobe tcp_bbr || true; fi
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    bbr="

# BBR congestion control with fair queueing: measurably better throughput to
# clients on long or lossy paths, no downside on clean ones.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr"
  else
    detail "BBR is not available in this kernel; keeping the default congestion control"
  fi

  local conf
  conf="$(cat <<CONF
# Managed by setup.sh (Server Initialization Suite).
# Performance tuning, safe on any host: VM, laptop, dedicated machine.

# Connection backlogs sized for a reverse proxy in front of containers; the
# distribution defaults predate that kind of workload.
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096

# Containerised apps and file watchers exhaust the inotify defaults constantly.
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512

# Required by Elasticsearch-class containers; harmless for everything else.
vm.max_map_count = 262144${bbr}
CONF
)"

  if in_container; then
    conf="$(printf '%s\n' "$conf" | sed '/^fs\./d; /^vm\./d')"
  fi

  if write_file /etc/sysctl.d/98-server-init-tuning.conf 0644 "$conf"; then
    if run sysctl -p /etc/sysctl.d/98-server-init-tuning.conf; then
      ok "Network and limit tuning applied"
    elif in_container; then
      detail "Tuning applied where the container is allowed to; the rest is the host's"
    else
      warn "Some tuning sysctls were rejected by this kernel; see: ${LOG_HINT}"
    fi
  else
    detail "Tuning sysctls already in place"
  fi
}

# A server must not sleep. On most machines these targets are inert anyway;
# on a laptop they are exactly what takes the host offline hours after the
# run looked successful.
tune_power() {
  if in_container; then
    detail "Container detected; power management belongs to the host"
    return 0
  fi

  if run systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target; then
    detail "Sleep, suspend and hibernate masked"
  else
    warn "Could not mask the systemd sleep targets."
  fi

  # Lid and idle handling only matter when there is a battery or a lid, so the
  # config is only written where a human could later find it and wonder why.
  if [ -d /proc/acpi/button/lid ] || compgen -G '/sys/class/power_supply/BAT*' >/dev/null; then
    local conf
    conf="$(cat <<'CONF'
# Managed by setup.sh (Server Initialization Suite).
# This machine is a server: closing the lid or going idle must not suspend it.
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
CONF
)"
    if write_file /etc/systemd/logind.conf.d/99-server-init.conf 0644 "$conf"; then
      run systemctl restart systemd-logind \
        || warn "Could not restart systemd-logind; the lid settings apply after a reboot."
      ok "Laptop hardware detected: lid close and idle no longer suspend"
    else
      detail "Lid and idle settings already in place"
    fi
  fi
  return 0
}

# Only where the kernel exposes frequency scaling - dedicated machines and
# laptops. A VM's frequency policy belongs to the hypervisor, and such guests
# simply have no scaling_governor files, so this skips itself there. A
# container sees the host's sysfs, read-only, so it is checked first: writing
# a unit that fails at every boot helps nobody.
tune_cpu_governor() {
  if in_container; then
    detail "Container detected; the CPU governor belongs to the host"
    return 0
  fi

  if ! compgen -G '/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor' >/dev/null; then
    detail "No CPU frequency scaling exposed (normal for a VM); governor left alone"
    return 0
  fi

  local script=/usr/local/sbin/cpu-performance-governor
  local body
  body="$(cat <<'SCRIPT'
#!/usr/bin/env bash
# Managed by setup.sh. Sets every CPU that supports it to the performance
# governor; CPUs whose driver does not offer it are left alone.
set -euo pipefail
shopt -s nullglob
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  avail="${gov%/scaling_governor}/scaling_available_governors"
  { [ -r "$avail" ] && grep -qw performance "$avail"; } || continue
  echo performance > "$gov"
done
SCRIPT
)"
  write_file "$script" 0755 "$body" || true

  local unit
  unit="$(cat <<UNIT
[Unit]
Description=Set the performance CPU frequency governor

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$script

[Install]
WantedBy=multi-user.target
UNIT
)"
  write_file /etc/systemd/system/cpu-performance-governor.service 0644 "$unit" || true

  run systemctl daemon-reload
  run systemctl enable cpu-performance-governor.service || true
  if run systemctl restart cpu-performance-governor.service; then
    ok "CPU governor set to performance (re-applied at boot by a systemd unit)"
  else
    warn "Could not set the performance CPU governor."
  fi
}

# Ubuntu-only background noise: the apport crash collector, the MOTD news
# fetcher, and Ubuntu Pro's apt advertisements. None of them earns its keep on
# a machine provisioned by the hundred.
tune_ubuntu_noise() {
  [ "$OS_ID" = "ubuntu" ] || return 0

  if systemctl cat apport.service >/dev/null 2>&1; then
    run systemctl disable --now apport.service || true
    if [ -f /etc/default/apport ]; then
      run sed -i 's/^enabled=.*/enabled=0/' /etc/default/apport
    fi
    detail "apport crash reporting disabled"
  fi

  if [ -f /etc/default/motd-news ]; then
    run sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news
  fi
  run systemctl mask motd-news.timer || true
  if have pro; then
    run pro config set apt_news=false || true
  fi
  detail "MOTD news and apt advertisements disabled"
  return 0
}

# Off by default: snapd is dead weight on a Docker host - background refreshes,
# loop mounts, a couple hundred MB of RAM - but removing a package manager is
# opinionated enough that it has to be asked for with --remove-snapd.
tune_remove_snapd() {
  [ "$OPT_REMOVE_SNAPD" -eq 1 ] || return 0

  if ! have snap && ! dpkg-query -W snapd >/dev/null 2>&1; then
    detail "snapd is not installed"
    return 0
  fi

  # Remove installed snaps first so the purge does not fight their mounts.
  # Two passes, because bases and core refuse to go while a snap still uses
  # them and 'snap list' does not order by dependency.
  if [ "$OPT_DRY_RUN" -eq 0 ] && have snap; then
    local pass s
    for pass in 1 2; do
      for s in $(snap list 2>/dev/null | awk 'NR>1 {print $1}'); do
        run snap remove --purge "$s" || true
      done
    done
  fi

  run systemctl disable --now snapd.socket snapd.service snapd.seeded.service || true
  if run_spin "Removing snapd" retry apt-get purge "${APT_OPTS[@]}" snapd; then
    run apt-mark hold snapd || true
    run rm -rf /snap /var/snap /var/lib/snapd /root/snap
    ok "snapd removed; the package is held so nothing reinstalls it"
  else
    warn "Could not remove snapd; continuing with it installed."
  fi
}

# end-of-module
