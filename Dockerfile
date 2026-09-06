# =============================================================================
#  Test harness for setup.sh
#
#  A full Ubuntu 24.04 image running systemd as PID 1, so the parts of setup.sh
#  that need a real init system -- sshd, ufw, fail2ban, dockerd, Dokploy's swarm
#  services -- behave the way they do on a real VM instead of being stubbed out.
#
#  Build:
#    docker build -t init-scripts-test .
#
#  Run (systemd needs these flags; --privileged is required for iptables,
#  dockerd and swapon):
#    docker run -d --name init-test --privileged --cgroupns=host \
#      --tmpfs /run --tmpfs /run/lock \
#      -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
#      -v "$PWD:/opt/init-scripts" \
#      init-scripts-test
#
#  Exec in and run the script by hand:
#    docker exec -it init-test bash
#    cd /opt/init-scripts && lib/setup.sh --dry-run
#    lib/setup.sh --username=deploy --ssh-port=2222 --ui-allow=10.0.0.0/8
#
#  Reset to a clean machine between attempts:
#    docker rm -f init-test && docker run -d ... (as above)
#
#  Teardown:
#    docker rm -f init-test
# =============================================================================

FROM ubuntu:24.04

# `container=docker` is what systemd looks for to enable its container mode.
ENV container=docker
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus dbus-user-session \
        sudo procps iproute2 iputils-ping iptables kmod \
        ca-certificates curl wget gnupg less nano vim-tiny \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Units that either cannot work in a container or slow the boot to no purpose.
# Leaving them enabled makes `systemctl` report a degraded system, which is
# noise when you are trying to read setup.sh's own output.
RUN systemctl mask \
        dev-hugepages.mount \
        sys-fs-fuse-connections.mount \
        sys-kernel-config.mount \
        sys-kernel-debug.mount \
        sys-kernel-tracing.mount \
        systemd-udevd.service \
        systemd-udev-trigger.service \
        systemd-modules-load.service \
        systemd-journald-audit.socket \
        getty.target \
        console-getty.service

# setup.sh logs to the journal and expects a writable /run.
VOLUME [ "/sys/fs/cgroup" ]

WORKDIR /opt/init-scripts

# systemd wants SIGRTMIN+3 for a clean shutdown; without this `docker stop`
# waits the full timeout and then kills it.
STOPSIGNAL SIGRTMIN+3

CMD [ "/sbin/init" ]
