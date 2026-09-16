#!/usr/bin/env bash
# setup-module: swap
# setup-api: 6
# =============================================================================
#  Component: swap - Create a swapfile when RAM is small and no swap exists
#
#  Small VPS instances routinely run out of memory during container builds. A
#  swapfile is the cheapest fix and costs nothing when unused.
#
#  Sourced by setup.sh, never run on its own. Everything here executes inside
#  the main script's shell: its options (OPT_*), helpers (step, run, run_spin,
#  apt_install, write_file, ok, warn, detail, die, ...) and its error trap.
#  Must define fn_swap. The last line must be the end-of-module marker.
# =============================================================================
[ -n "${SETUP_API:-}" ] || { echo "This is a setup.sh component module; run setup.sh instead." >&2; exit 64; }

fn_swap() {
  step "Swap"

  # A container's swap is whatever the host allots it; swapon is refused there,
  # and the 2 GB file it would take to find that out is pure waste.
  if in_container; then
    step_skip "Container: swap is managed by the host"
    return 0
  fi

  if [ -e /swapfile ] || [ -L /swapfile ] || grep -qE '^/swapfile[[:space:]]' /etc/fstab; then
    step_skip "Existing swapfile or fstab entry preserved"
    return 0
  fi

  local existing
  existing="$(swapon --show --noheadings 2>/dev/null | wc -l || true)"
  if [ "${existing:-0}" -gt 0 ]; then
    step_skip "Swap already configured"
    return 0
  fi

  local mem_mb size_mb
  mem_mb="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
  if [ "$mem_mb" -ge 8192 ]; then
    step_skip "${mem_mb} MiB RAM; no swapfile needed"
    return 0
  fi
  size_mb=$((mem_mb < 2048 ? 2048 : mem_mb))

  local avail_mb
  avail_mb="$(df --output=avail -m / 2>/dev/null | tail -n1 | tr -d ' ' || true)"
  [[ "$avail_mb" =~ ^[0-9]+$ ]] || avail_mb=0
  if [ "$avail_mb" -lt $((size_mb + 2048)) ]; then
    warn "Not enough free disk space for a ${size_mb} MB swapfile; skipping."
    return 0
  fi

  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    detail "Would create a ${size_mb} MB swapfile at /swapfile"
    return 0
  fi

  (umask 077; set -o noclobber; : >/swapfile) || die "Could not safely create /swapfile."
  if ! run_spin "Creating a ${size_mb} MB swapfile" \
    dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=none; then
    run rm -f /swapfile
    warn "Could not allocate swap; continuing without it."
    return 0
  fi
  run chmod 600 /swapfile

  # Swap is a convenience, not a dependency. A filesystem that refuses
  # swapfiles must not abort the rest of the run.
  if ! run mkswap /swapfile || ! run swapon /swapfile; then
    run rm -f /swapfile
    warn "This filesystem refused a swapfile; continuing without swap."
    return 0
  fi

  grep -qE '^/swapfile\b' /etc/fstab || run_sh "printf '/swapfile none swap sw 0 0\n' >> /etc/fstab"
  if write_file /etc/sysctl.d/99-swap.conf 0644 "vm.swappiness = 10
vm.vfs_cache_pressure = 50"; then
    run sysctl -p /etc/sysctl.d/99-swap.conf || warn "Could not apply the swappiness settings."
  fi

  ok "${size_mb} MB swapfile active"
}

# end-of-module
