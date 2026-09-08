#!/usr/bin/env bash
# setup-module: docker
# setup-api: 3
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

  # Legacy packages conflict with docker-ce and must go first.
  local legacy=(docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc)
  local installed=()
  local p
  for p in "${legacy[@]}"; do
    if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "^install ok installed"; then
      installed+=("$p")
    fi
  done
  if [ ${#installed[@]} -gt 0 ]; then
    detail "Removing conflicting packages: ${installed[*]}"
    run apt-get remove "${APT_OPTS[@]}" "${installed[@]}" || true
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
      retry curl -fsSL --connect-timeout 15 "https://download.docker.com/linux/${repo_os}/gpg" \
      -o /etc/apt/keyrings/docker.asc \
      || die "Could not download the Docker GPG key."
    run chmod a+r /etc/apt/keyrings/docker.asc

    write_file /etc/apt/sources.list.d/docker.list 0644 \
      "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${repo_os} ${OS_CODENAME} stable" || true
    # Remove the deb822 file a previous version of this script may have written.
    run rm -f /etc/apt/sources.list.d/docker.sources

    apt_update || die "apt-get update failed after adding the Docker repository."
    apt_install "Docker Engine" docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
      || die "Docker installation failed. See: ${LOG_HINT}"
    ok "Docker installed: $(docker --version 2>/dev/null || echo unknown)"
  fi

  # Unbounded container logs are a classic way for an unattended server to fill
  # its disk months later.
  configure_docker_daemon

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
  },
  "live-restore": false
}'

  if [ ! -f "$f" ]; then
    write_file "$f" 0644 "$desired" && detail "Container log rotation configured"
    return 0
  fi

  # An existing daemon.json is merged rather than replaced, so Dokploy's or the
  # operator's own settings survive a re-run.
  if have jq && [ "$OPT_DRY_RUN" -eq 0 ]; then
    local merged
    if merged="$(jq -s '.[0] * .[1]' "$f" <(printf '%s' "$desired") 2>/dev/null)" && [ -n "$merged" ]; then
      if [ "$merged" != "$(cat "$f")" ]; then
        backup_file "$f"
        printf '%s\n' "$merged" >"$f"
        run systemctl restart docker || warn "Docker did not restart cleanly after the daemon.json update."
        detail "Merged log rotation settings into the existing daemon.json"
      fi
      return 0
    fi
  fi
  warn "Left the existing /etc/docker/daemon.json untouched; container log rotation not applied."
}

# end-of-module
