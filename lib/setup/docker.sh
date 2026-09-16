#!/usr/bin/env bash
# setup-module: docker
# setup-api: 5
# =============================================================================
#  Component: docker - Install Docker CE with container log rotation
#
#  Docker is installed from Docker's own apt repository rather than left to
#  Dokploy's installer, which pins an exact version and apt-mark holds it.
#  Installing it first means Dokploy detects Docker and skips that entirely.
#
#  Sourced by setup.sh, never run on its own. Everything here executes inside
#  the main script's shell: its options (OPT_*), helpers (step, run, run_spin,
#  apt_install, write_file, ok, warn, detail, die, ...) and its error trap.
#  Must define fn_docker. The last line must be the end-of-module marker.
# =============================================================================
[ -n "${SETUP_API:-}" ] || { echo "This is a setup.sh component module; run setup.sh instead." >&2; exit 64; }

fn_docker() {
  step "Docker"

  # Never replace a working runtime (including distro Docker or Podman), or
  # rewrite/restart a daemon serving existing containers.
  if have docker; then
    if docker version >/dev/null 2>&1; then
      ok "Existing Docker-compatible runtime preserved"
      return 0
    fi
    if [ "$OPT_DRY_RUN" -eq 1 ]; then
      warn "Existing Docker daemon is unavailable; a modifying run would stop here."
      return 0
    fi
    die "Docker is installed but unavailable. Restore the existing daemon before retrying; its packages and configuration were preserved."
  fi

  # Do not remove another workload's runtime to make room for Docker CE.
  local legacy=(docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc)
  local installed=()
  local p
  for p in "${legacy[@]}"; do
    if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "^install ok installed"; then
      installed+=("$p")
    fi
  done
  if [ ${#installed[@]} -gt 0 ]; then
    die "Existing container runtime packages (${installed[*]}) were preserved. Resolve the runtime installation before installing Docker CE."
  fi

  if have docker && docker version >/dev/null 2>&1; then
    ok "Docker already installed: $(docker --version 2>/dev/null || echo unknown)"
  else
    local repo_os="$OS_ID"
    case "$OS_ID" in
      debian|ubuntu) ;;
      *) repo_os="debian"; case " ${ID_LIKE:-} " in *ubuntu*) repo_os="ubuntu" ;; esac ;;
    esac

    run install -m 0755 -d /etc/apt/keyrings
    run_spin "Fetching the Docker signing key" \
      retry curl -fsSL --connect-timeout 15 --max-time 120 "https://download.docker.com/linux/${repo_os}/gpg" \
      -o /etc/apt/keyrings/docker.asc \
      || die "Could not download the Docker GPG key."
    run chmod a+r /etc/apt/keyrings/docker.asc

    write_file /etc/apt/sources.list.d/docker.list 0644 \
      "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${repo_os} ${OS_CODENAME} stable" || true
    # Remove the deb822 file a previous version of this script may have written.
    run rm -f /etc/apt/sources.list.d/docker.sources

    apt_update || die "apt-get update failed after adding the Docker repository."
    # Package installation starts dockerd, so write defaults before that start.
    configure_docker_daemon
    apt_install "Docker Engine" docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
      || die "Docker installation failed. See: ${LOG_HINT}"
    ok "Docker installed: $(docker --version 2>/dev/null || echo unknown)"
  fi

  run systemctl enable docker || true
  run systemctl start docker \
    || die "Docker failed to start. In a Proxmox LXC container this needs the 'nesting' feature (and 'keyctl' when unprivileged). See: ${LOG_HINT}"

  if [ "$OPT_USERNAME" != "root" ]; then
    run usermod -aG docker "$OPT_USERNAME" || true
    detail "'$OPT_USERNAME' added to the docker group (effective at next login)"
  fi
}

configure_docker_daemon() {
  local f=/etc/docker/daemon.json
  local desired='{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "5"
  }
}'

  if [ ! -f "$f" ]; then
    write_file "$f" 0644 "$desired" && detail "Container log rotation configured"
    return 0
  fi

  detail "Existing Docker daemon configuration preserved"
}

# end-of-module
