# Order of Operations

This document describes exactly what `setup.sh` does, in the order it does it,
and why each step is placed where it is. It is the reference for auditing the
script before running it on a production machine; `README.md` covers day-to-day
usage.

---

## Phase 0 — Argument parsing and validation

Runs before anything touches the system.

1. **Parse arguments.** Unknown flags are a hard error. So are unknown component
   names in `--exclude` or `--only`, and combining those two flags.
2. **Validate values.** The SSH port must be 1–65535, the username must be a
   valid Linux user name, a supplied public key must look like an OpenSSH key,
   and a supplied timezone must exist in `/usr/share/zoneinfo`.
3. **Open the log.** `/var/log/server-init-<timestamp>.log` is created with mode
   0600, falling back to a temporary file if `/var/log` is not writable.

The console and the log are separate streams from this point on. File
descriptor 3 is the terminal; command output goes to the log. This is what
allows the generated private key to be shown on screen without ever being
written to disk.

---

## Phase 1 — Preflight

Nothing here is skippable.

1. **Root check.** The script exits unless it is running as UID 0.
2. **Distribution detection.** Reads `/etc/os-release`. Debian and Ubuntu are
   supported outright; a distribution whose `ID_LIKE` contains `debian` or
   `ubuntu` continues with a warning. Anything else exits. The release codename
   is required, because the Docker and Cloudflare apt repositories are keyed on
   it.
3. **Architecture check.** Unusual architectures produce a warning, since Docker
   and Dokploy images may not exist for them.
4. **Banner.** Prints the detected system, kernel, hostname, memory, free disk,
   and the log path.
5. **Container detection.** Warns if `/.dockerenv` or an LXC marker is present.
   Dokploy's installer refuses to run inside a Docker container.
6. **Connectivity check.** A DNS lookup of the distribution mirrors; a failure
   warns early rather than surfacing later as a confusing apt error.
7. **Wait for the system to settle.** Waits for `cloud-init` to report
   completion (capped at 300 seconds), then waits for the dpkg and apt locks to
   be released (also capped at 300 seconds, after which the apt timers are
   stopped and the run continues).

Step 7 exists because the `apt-daily` and `unattended-upgrades` timers hold the
dpkg lock during the first minutes of a cloud VM's life. Any apt call in that
window fails outright, which is the most common reason a first-boot script dies.

---

## Phase 2 — Components

The step counter reflects only the components that will actually run, so
`[3/11]` means what it says. Skipped components are listed without a number.

### 1. `update` — System update

- Applies `--hostname` and `--timezone` if given. The hostname change also adds
  a `127.0.1.1` entry to `/etc/hosts` so that `sudo` does not stall on name
  resolution.
- Refreshes the apt indexes.
- Counts pending upgrades with `apt-get -s upgrade` and runs `dist-upgrade` only
  if there are any.
- Runs `autoremove`.
- Warns if `/var/run/reboot-required` exists.

### 2. `base` — Base packages

Installs the utilities every later step depends on: `ca-certificates`, `curl`,
`wget`, `gnupg`, `lsb-release`, `apt-transport-https`, `git`, `unzip`, `tar`,
`jq`, `iproute2`, `net-tools`, `dnsutils`, `openssh-server`, `openssh-client`,
`sudo`, `ufw`, `htop`, `rsync`.

Two of these are load-bearing in non-obvious ways. `iproute2` provides `ss`,
which Dokploy's installer uses for its port checks. `openssh-client` provides
`ssh -Q`, which the SSH step uses to discover which cryptographic algorithms the
installed OpenSSH supports.

If the apt indexes have not been refreshed yet in this run — which happens when
`update` was excluded or `--only=base` was used — this step refreshes them
first.

### 3. `ssh` — Account, keys, and hardening

The ordering inside this step is what makes a lockout impossible.

1. **Create the account.** With the default `--username=root` nothing is
   created. Otherwise the user is created if missing, added to the `sudo` group,
   and given a validated passwordless sudoers drop-in. No password is ever set,
   so login is key-only; passwordless sudo is therefore required for the account
   to administer anything.
2. **Install keys.** In priority order: install `--pubkey` if given; otherwise
   keep the existing authorized keys if there are any and `--new-key` was not
   passed; otherwise generate an ed25519 keypair, install the public half, and
   print the private half to the console. The private key is shredded from its
   temporary directory immediately after being read, and is written to a file
   only when `--save-key` is given.
3. **Verify.** The script counts the entries in `authorized_keys`. If there are
   none, it refuses to harden sshd and exits.
4. **Ensure the include.** Adds `Include /etc/ssh/sshd_config.d/*.conf` to the
   top of `/etc/ssh/sshd_config` if it is missing, as on Debian 11.
5. **Neutralise conflicts.** Comments out the directives the script owns
   wherever else they are set, in the main config and in every other drop-in.
   sshd keeps the first value it finds, so a cloud image's
   `50-cloud-init.conf` would otherwise silently win. Every edited file is
   backed up as `<file>.bak-<timestamp>`.
6. **Write the drop-in.** `/etc/ssh/sshd_config.d/00-server-init.conf`. The
   `00-` prefix guarantees it is read first. Key exchange, cipher and MAC lists
   are intersected with `ssh -Q` output so no unsupported algorithm is ever
   written.
7. **Prune weak moduli.** Removes Diffie-Hellman moduli below 3072 bits from
   `/etc/ssh/moduli`.
8. **Validate.** Runs `sshd -t`. On failure the baseline is tested too: if the
   baseline passes, the drop-in is the culprit and is removed, leaving SSH
   untouched, and the run stops. If the baseline also fails, the problem
   pre-dates this script, so the hardening is kept and the real error is
   reported as a warning.
9. **Apply the port.** On socket-activated systems (Ubuntu 24.04, Debian 13) the
   `Port` directive is ignored, so a `ssh.socket` drop-in is written instead.
10. **Restart sshd** and confirm it is active.

Existing SSH sessions survive the restart, which is why the summary insists on
verifying a new login before disconnecting.

### 4. `firewall` — UFW

Sets the default policy to deny incoming and allow outgoing, rate-limits the SSH
port with `ufw limit`, opens 80/tcp, 443/tcp, 443/udp and 3000/tcp when Dokploy
is part of the run, and enables UFW.

The ruleset is **not** reset unless `--reset-firewall` is given, so a re-run does
not destroy rules added by hand.

The step ends with a warning that Docker publishes container ports around UFW.
This is not a footnote — see the Dokploy step.

### 5. `fail2ban` — Intrusion prevention

Installs `fail2ban` and `python3-systemd`, and writes `/etc/fail2ban/jail.local`
with `backend = systemd`, an `sshd` jail bound to the configured port, and a
`recidive` jail that bans repeat offenders for a week.

The systemd backend is deliberate. Recent Debian and Ubuntu images ship without
rsyslog, so `/var/log/auth.log` may not exist and the default file backend fails
to start.

### 6. `swap` — Swapfile

Skipped when swap already exists or the machine has 8 GB of RAM or more, and
when there is not enough free disk. Otherwise creates a swapfile the size of
RAM, with a 2 GB floor, adds it to `/etc/fstab`, and sets `vm.swappiness=10`.

Small instances routinely run out of memory during container builds; this is the
cheapest fix and costs nothing when unused.

### 7. `docker` — Docker CE

1. Removes conflicting legacy packages (`docker.io`, `podman-docker`,
   `containerd`, and similar) if any are installed.
2. Adds Docker's official apt repository, keyed on the detected distribution and
   codename, and installs `docker-ce`, `docker-ce-cli`, `containerd.io`,
   `docker-buildx-plugin` and `docker-compose-plugin`.
3. Configures container log rotation in `/etc/docker/daemon.json`
   (`max-size 20m`, `max-file 5`). An existing file is merged with `jq` rather
   than overwritten.
4. Enables and starts Docker, and adds a non-root login account to the `docker`
   group.

Docker is installed here, before Dokploy, on purpose. Dokploy's installer would
otherwise install Docker itself from `get.docker.com`, pinned to one exact
version and `apt-mark hold`-ed. Installing first means Dokploy detects Docker and
skips that entirely, leaving the host on the distribution's normal upgrade path.

Unbounded container logs are one of the ways an unattended server fills its disk
months after anyone last looked at it.

### 8. `dokploy` — PaaS platform

1. **Skip if present.** Dokploy's installer runs `docker swarm leave --force`
   and recreates the overlay network on every invocation, which would disrupt a
   working deployment. An existing installation is left alone unless
   `--reinstall-dokploy` is passed, in which case the existing services are
   removed first so their ports are free.
2. **Check ports.** The installer aborts if anything holds 80, 443 or 3000. The
   script checks first and names the process holding the port.
3. **Download and verify.** The installer is fetched to a file and checked for a
   shebang before execution, so an error page or captive portal response is
   never piped into a shell.
4. **Run it**, then wait up to 90 seconds for the UI to answer on port 3000.
5. **Restrict the UI** if `--ui-allow` was given.

The restriction is implemented as a rule in the `DOCKER-USER` iptables chain,
re-applied at boot by a small systemd unit, because Docker's rules run ahead of
UFW's and iptables rules do not persist. Without `--ui-allow` the script warns
that port 3000 is reachable from the internet and that whoever loads it first
becomes the Dokploy administrator.

### 9. `cloudflared` — Cloudflare Tunnel

Adds Cloudflare's apt repository and installs `cloudflared`. A failure here
warns and continues rather than aborting the run, since the tunnel is optional.
The daemon still needs `cloudflared service install <token>` to be attached to
an account.

### 10. `bun` — JavaScript runtime

Installs Bun into the login account's home directory via the official installer,
run as that user rather than as root. Skipped if already present.

### 11. `unattended` — Automatic security updates

Runs last so it can never contend with the script itself for the apt lock.

Writes `/etc/apt/apt.conf.d/52-server-init` and
`/etc/apt/apt.conf.d/20auto-upgrades` with:

- security-pocket origins only, distribution-appropriate (Ubuntu ESM pockets
  included on Ubuntu)
- the Docker packages blacklisted, because an automatic upgrade restarts the
  daemon underneath running containers
- automatic reboots disabled
- `MinimalSteps` enabled, so an interruption leaves a recoverable state
- unused kernels and dependencies removed, which prevents `/boot` filling up and
  breaking apt later
- `OnlyOnACPower` disabled, since virtual machines report no AC power

The configuration is then validated with `unattended-upgrade --dry-run`.

---

## Phase 3 — Summary

Collects the public IP, then prints:

- installed versions of Docker, Dokploy, cloudflared, fail2ban and Bun
- the SSH account, port, key source, and whether password authentication is on
- the SSH and Dokploy URLs
- every warning raised during the run, collected in one place
- the numbered manual steps that remain
- a reminder to copy the private key, if one was generated

---

## Failure behaviour

The script runs under `set -Eeuo pipefail` with an `ERR` trap. On failure it
prints the step that was running, the exit code and line number, and the last
twenty lines of the log, then exits with that code.

Failures inside a command substitution are reported to the log only, since
exiting there would only leave the subshell.

Not every failure is fatal. Optional components — cloudflared and Bun — warn and
continue. Anything the rest of the run depends on, such as apt or Docker, stops
the run.
