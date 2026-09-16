#!/usr/bin/env bash
# setup-module: base
# setup-api: 6
# =============================================================================
#  Component: base - Install base utilities
#
#  Sourced by setup.sh, never run on its own. Everything here executes inside
#  the main script's shell: its options (OPT_*), helpers (step, run, run_spin,
#  apt_install, write_file, ok, warn, detail, die, ...) and its error trap.
#  Must define fn_base. The last line must be the end-of-module marker.
# =============================================================================
[ -n "${SETUP_API:-}" ] || { echo "This is a setup.sh component module; run setup.sh instead." >&2; exit 64; }

fn_base() {
  step "Base packages"

  # iproute2 provides ss, which Dokploy's installer uses for its port checks.
  # curl, unzip and ca-certificates were already installed by preflight; they
  # stay in the list so the manifest of what a host has is in one place.
  apt_ensure_lists || die "apt-get update failed. Check network and mirror configuration."

  local pkgs=(
    ca-certificates curl wget gnupg lsb-release apt-transport-https
    git unzip tar jq
    iproute2 net-tools dnsutils psmisc
    sudo
    htop rsync
  )
  if is_enabled ssh; then pkgs+=(openssh-server openssh-client); fi
  if is_enabled firewall; then pkgs+=(ufw); fi

  apt_install "base packages (${#pkgs[@]})" "${pkgs[@]}" || die "Failed to install base packages. See: ${LOG_HINT}"
  ok "Base packages installed"
}

# end-of-module
