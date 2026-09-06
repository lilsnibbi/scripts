#!/usr/bin/env bash
# setup-module: unattended
# setup-api: 2
# =============================================================================
#  Component: unattended - Enable automatic security updates
#
#  Runs last, so it can never contend with this script for the apt lock.
#
#  The configuration deliberately restricts itself to the security pocket, never
#  reboots on its own unless asked, and excludes the Docker packages: an
#  automatic Docker or containerd upgrade restarts the daemon underneath running
#  containers.
#
#  Sourced by setup.sh, never run on its own. Everything here executes inside
#  the main script's shell: its options (OPT_*), helpers (step, run, run_spin,
#  apt_install, write_file, ok, warn, detail, die, ...) and its error trap.
#  Must define fn_unattended. The last line must be the end-of-module marker.
# =============================================================================
[ -n "${SETUP_API:-}" ] || { echo "This is a setup.sh component module; run setup.sh instead." >&2; exit 64; }

fn_unattended() {
  step "Automatic security updates"

  apt_ensure_lists || true
  apt_install "unattended-upgrades" unattended-upgrades apt-listchanges || {
    warn "Could not install unattended-upgrades; skipping."
    return 0
  }

  local origins
  if [ "$OS_ID" = "ubuntu" ]; then
    # Origins-Pattern entries must be key=value pairs. The shorter
    # "Ubuntu:noble-security" form belongs to Allowed-Origins, and putting it
    # here makes unattended-upgrade fail to parse its own configuration.
    origins='        "origin=Ubuntu,archive=${distro_codename}-security";
        "origin=UbuntuESMApps,archive=${distro_codename}-apps-security";
        "origin=UbuntuESM,archive=${distro_codename}-infra-security";'
  else
    origins='        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";'
  fi

  # Installing a kernel patch does not activate it. Without a reboot the host
  # keeps running the vulnerable image indefinitely, and across a fleet nobody
  # reboots by hand - so the choice is an explicit maintenance window or an
  # explicit decision to stay on the old kernel.
  local reboot_policy
  if [ -n "$OPT_AUTO_REBOOT" ]; then
    reboot_policy="// Reboot inside the window given by --auto-reboot.
Unattended-Upgrade::Automatic-Reboot \"true\";
Unattended-Upgrade::Automatic-Reboot-WithUsers \"true\";
Unattended-Upgrade::Automatic-Reboot-Time \"${OPT_AUTO_REBOOT}\";"
  else
    reboot_policy='// Never reboot on its own; pass --auto-reboot=HH:MM to allow it.
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";'
  fi

  local conf
  conf="$(cat <<CONF
// Managed by setup.sh (Server Initialization Suite).
// Security updates only, Docker left alone.

// #clear discards whatever the shipped 50unattended-upgrades put in these
// lists, so the effective configuration is exactly what is written below
// rather than the union of both files. Allowed-Origins is cleared as well:
// unattended-upgrade merges it with Origins-Pattern, and Ubuntu's default
// entry for the plain release pocket would let through non-security updates.
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
$origins
};

// Upgrading these restarts the Docker daemon under running containers.
#clear Unattended-Upgrade::Package-Blacklist;
Unattended-Upgrade::Package-Blacklist {
        "docker-ce";
        "docker-ce-cli";
        "containerd.io";
        "docker-buildx-plugin";
        "docker-compose-plugin";
};

$reboot_policy

// Apply upgrades one at a time so an interruption leaves a recoverable state.
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";

// Stop /boot filling up with old kernels, a common cause of later apt failures.
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Virtual machines report no AC power.
Unattended-Upgrade::OnlyOnACPower "false";
Unattended-Upgrade::Skip-Updates-On-Metered-Connections "true";

// Keep the config files that are already on disk.
Dpkg::Options {
        "--force-confdef";
        "--force-confold";
};

Unattended-Upgrade::SyslogEnable "true";
CONF
)"

  write_file /etc/apt/apt.conf.d/52-server-init 0644 "$conf" || true

  local periodic
  periodic="$(cat <<'CONF'
// Managed by setup.sh (Server Initialization Suite).
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
CONF
)"
  write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 "$periodic" || true

  if [ "$OPT_DRY_RUN" -eq 0 ]; then
    if unattended-upgrade --dry-run --debug >&4 2>&1; then
      detail "Configuration validated with a dry run"
    else
      warn "'unattended-upgrades --dry-run' reported a problem; see: ${LOG_HINT}"
    fi
  fi

  run systemctl enable --now unattended-upgrades.service || true
  if [ -n "$OPT_AUTO_REBOOT" ]; then
    ok "Security updates applied automatically; reboots at ${OPT_AUTO_REBOOT} when needed"
  else
    ok "Security updates applied automatically; reboots stay manual"
    detail "Kernel patches need a reboot; --auto-reboot=HH:MM schedules one"
  fi
}

# end-of-module
