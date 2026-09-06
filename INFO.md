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
   and a supplied timezone must exist in `/usr/share/zoneinfo`. `--ui-public`
   cannot be combined with `--ui-allow` or `--local`, which ask for the
   opposite; `--ui-allow` and `--local` may be combined and add up.
3. **Resolve the module source.** `--base`, then the `SETUP_BASE` environment
   variable, then a `setup/` directory beside the script (a checkout), then the
   default `https://lilsnibbi.dev/scripts`.
4. **Open the log.** No log file is written. Command output is piped to the
   systemd journal under the tag `server-init` (read back with
   `journalctl -t server-init`). The journal's socket is checked first: with
   systemd installed but journald not running, `systemd-cat` exits at once and
   the first write to the dead pipe would kill the script with SIGPIPE. On a
   system without a journal the output is discarded and the script says so.
5. **Close stdin.** The script is normally piped into bash, so its stdin *is*
   the script. Every function has been parsed by the time `main` runs, and no
   step reads from the terminal, so stdin is redirected from `/dev/null` before
   any child could consume the rest of the script off the pipe.

The console and the log are separate streams from this point on. File
descriptor 3 is the terminal, file descriptor 4 feeds the journal; command
output goes to the journal, so a run reads as a list of outcomes rather than a
wall of apt and docker chatter.

`PATH` is pinned at the top of the script to include the sbin directories.
`pct exec` on Proxmox, cloud-init and a bare root shell do not all provide
them, and `sshd`, `ufw`, `sysctl` and `swapon` live there.

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
   the module source, the command that reads the log back
   (`journalctl -t server-init`), and the components that will be skipped.
5. **Container detection.** A Docker container (`/.dockerenv`) is a warning,
   because Dokploy's installer refuses to run in one. Any other container — a
   Proxmox CT, say — is a normal target and gets a note that host-owned
   settings will be skipped.
6. **Connectivity check.** A DNS lookup of the distribution mirrors; a failure
   warns early rather than surfacing later as a confusing apt error.
7. **Wait for the system to settle.** Waits for `cloud-init` to report
   completion (capped at 300 seconds), then waits for the dpkg and apt locks to
   be released (also capped at 300 seconds, after which the apt timers are
   stopped and the run continues).
8. **Clock check.** Confirms `timedatectl` reports the clock synchronised,
   enabling `systemd-timesyncd` and waiting up to 20 seconds if nothing is
   keeping time. Skipped in containers, where the host owns the clock. This
   runs before the first apt call and TLS handshake on purpose: a skewed clock
   makes apt reject Release files as "not valid yet" and TLS fail on
   `notBefore`, and neither error mentions the clock.
9. **Fetch the modules.** Only the modules for the components that will run,
   each into a temporary directory that is removed on exit. Every file is then
   checked before it is sourced: it must carry `# setup-module: <name>`, a
   `# setup-api:` number equal to the framework's, and an `# end-of-module`
   line within its last three lines (a truncated download fails here), and it
   must pass `bash -n`. After sourcing, `fn_<name>` must exist. Any failure
   aborts the run, and nothing has been changed on the machine yet.
10. **Prerequisites.** Installs whichever of `curl`, `unzip` and
    `ca-certificates` is missing, refreshing the apt indexes first if needed.
    This is the first apt call of the run and happens before any component, so
    `unzip` is present even for `--only=bun`.

Step 7 exists because the `apt-daily` and `unattended-upgrades` timers hold the
dpkg lock during the first minutes of a cloud VM's life. Any apt call in that
window fails outright, which is the most common reason a first-boot script dies.

Steps 9 and 10 are in that order deliberately. Fetching is read-only, so a
wrong URL or a stale deploy aborts with zero side effects; the prerequisites
are the first change made to the host.

---

## Phase 2 — Components

The step counter reflects only the components that will actually run, so
`[3/11]` means what it says. Skipped components are listed without a number.

### 1. `update` — System update

- Applies `--timezone` (default UTC) and `--hostname` if given. The hostname
  change falls back to `hostname` plus `/etc/hostname` when `hostnamectl` has
  no D-Bus to talk to, as in some containers, and adds a `127.0.1.1` entry to
  `/etc/hosts` so that `sudo` does not stall on name resolution. Time
  synchronisation itself is checked in preflight, before the first apt call.
- Refreshes the apt indexes, unless preflight already did so seconds earlier to
  install the prerequisites.
- Runs `apt-get dist-upgrade` with
  `-o APT::Get::Always-Include-Phased-Updates=true`. Ubuntu releases some
  updates to a fraction of machines at a time; a host being deliberately
  brought up to date should not be held back by the rollout cohort. The option
  does nothing on Debian, which does not phase updates.
- The upgrade runs unconditionally. The pending count shown alongside it comes
  from `apt-get -s dist-upgrade` — the same command that then runs for real —
  and is reporting only, never a gate. An earlier version counted with
  `apt-get -s upgrade` and ran `dist-upgrade`, which meant a host whose only
  pending work was a new kernel simulated zero packages, printed "System
  already up to date", and skipped the upgrade entirely.
- Runs `autoremove`.
- Warns if `/var/run/reboot-required` exists.

### 2. `base` — Base packages

Installs the utilities every later step depends on: `ca-certificates`, `curl`,
`wget`, `gnupg`, `lsb-release`, `apt-transport-https`, `git`, `unzip`, `tar`,
`jq`, `iproute2`, `net-tools`, `dnsutils`, `openssh-server`, `openssh-client`,
`sudo`, `ufw`, `htop`, `rsync`.

`iproute2` is load-bearing in a non-obvious way: it provides `ss`, which
Dokploy's installer uses for its port checks. `curl`, `unzip` and
`ca-certificates` were already installed by preflight; they stay in this list so
the manifest of what a host has is in one place.

If the apt indexes have not been refreshed yet in this run — which happens when
`update` was excluded or `--only=base` was used — this step refreshes them
first.

### 3. `ssh` — Account, key, and port

This step used to harden sshd. It no longer does, and that is the point: every
authentication directive worth setting is one that can also refuse a login, and
an unattended first-boot run has nobody at the console to notice. `Port` is the
only directive still written, because it cannot deny a login by itself and the
firewall step has to agree with it.

1. **Create the account.** With the default `--username=root` nothing is
   created. Otherwise the user is created if missing, added to the `sudo` group,
   and given a validated passwordless sudoers drop-in. No password is ever set,
   so login is key-only; passwordless sudo is therefore required for the account
   to administer anything.
2. **Install a key.** Append-only. `--pubkey` is added to `authorized_keys` if
   given and not already present; otherwise whatever the account already has is
   left alone. The script generates nothing, and removes nothing. An account
   with no keys is not an error — password authentication is whatever the image
   configured, and this script does not change it.
3. **Ensure the include.** Adds `Include /etc/ssh/sshd_config.d/*.conf` to the
   top of `/etc/ssh/sshd_config` if it is missing, as on Debian 11.
4. **Neutralise conflicting `Port` lines.** Comments out `Port` wherever else it
   is set, in the main config and in every other drop-in, since sshd keeps the
   first value it finds and a cloud image's `50-cloud-init.conf` would otherwise
   win. `Port` is the only directive touched; everything else in those files is
   left exactly as it is. Every edited file is backed up as
   `<file>.bak-<timestamp>`.
5. **Write the drop-in.** `/etc/ssh/sshd_config.d/00-server-init.conf`, whose
   entire managed content is one line:

   ```
   Port <n>
   ```

   The `00-` prefix guarantees it is read first.
6. **Validate.** Runs `sshd -t`. On failure the baseline is tested too: if the
   baseline passes, the drop-in is the culprit and is removed, leaving SSH
   untouched, and the run stops. If the baseline also fails, the problem
   pre-dates this script, so the drop-in is kept and the real error is
   reported as a warning.
7. **Apply the port.** On socket-activated systems (Ubuntu 24.04, Debian 13) the
   `Port` directive is ignored, so a `ssh.socket` drop-in is written instead.
8. **Restart sshd** and confirm it is active.

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

The `recidive` jail is the one exception: fail2ban records its own bans in
`/var/log/fail2ban.log`, not in the journal, so that jail overrides the default
back to a polling backend and reads the file. With the journal backend it would
silently never match anything.

### 6. `hardening` — Kernel, journal, root password

Three independent pieces:

- **sysctl.** Writes `/etc/sysctl.d/99-server-init-hardening.conf` with
  Docker-safe network settings: SYN cookies, no ICMP redirects, no source
  routing, `kptr_restrict`, and protected symlinks/hardlinks. Two deliberate
  omissions: `net.ipv4.ip_forward` is never touched (Docker manages it, and
  forcing it off would break container networking at the next boot), and
  `rp_filter` is set to loose (2) rather than strict (1), because strict mode
  drops the asymmetric traffic Docker Swarm's ingress mesh produces. In a
  container the `net.*` keys take and the `kernel.*`/`fs.*` keys are refused
  by the host; that is reported as a note, not a warning.
- **journald caps.** `SystemMaxUse=500M`, one month retention. Container logs
  are already capped in `daemon.json`; without this the journal grows into a
  share of the whole disk.
- **Root password lock.** Only when a non-root `--username` was given *and*
  that account already has at least one authorized key. Locking root's
  password affects console and rescue logins too, so it never happens before a
  replacement way in demonstrably exists.

### 7. `tuning` — Environment-aware performance tuning

Every piece probes for the environment it needs — container, KVM guest, VPS,
dedicated machine, laptop — and skips itself, with a note, where it does not
apply.

- **Network and limits sysctls** (everywhere): `somaxconn` and SYN backlog
  raised for reverse-proxy workloads, a wider ephemeral port range, inotify
  watches/instances raised (containerized apps exhaust the defaults),
  `vm.max_map_count` for Elasticsearch-class containers. BBR + `fq` are added
  only after probing that the kernel actually offers BBR.
- **Power** (skipped in containers): the systemd sleep/suspend/hibernate
  targets are masked. When a battery or lid is detected — a laptop serving as
  a server — a logind drop-in stops lid close and idle from suspending the
  host, which is otherwise exactly what takes it offline hours after a
  successful-looking run.
- **CPU governor** (bare metal and laptops only): set to `performance` via a
  small oneshot unit so it persists across boots. VMs expose no frequency
  scaling — the hypervisor owns it — so the step skips itself there. A
  container sees the host's sysfs read-only, so it is checked first; without
  that check a CT on a physical host would install a unit that fails at every
  boot.
- **Ubuntu noise** (Ubuntu only): apport crash collection disabled, MOTD news
  and Ubuntu Pro apt advertisements switched off.
- **snapd removal** (only with `--remove-snapd`): all snaps removed, the
  package purged and held. Off by default because removing a package manager
  is a decision, not a default.

### 8. `swap` — Swapfile

Skipped in a container (swap is the host's to allot, `swapon` is refused, and
the 2 GB file it would take to find that out is pure waste), when swap already
exists, when the machine has 8 GB of RAM or more, and when there is not enough
free disk. Otherwise creates a swapfile the size of RAM, with a 2 GB floor, adds
it to `/etc/fstab`, and sets `vm.swappiness=10`.

Small instances routinely run out of memory during container builds; this is the
cheapest fix and costs nothing when unused.

### 9. `docker` — Docker CE

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

### 10. `dokploy` — PaaS platform

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
5. **Restrict the UI.** Always, unless `--ui-public` was given.

The restriction is implemented as a rule in the `DOCKER-USER` iptables chain,
re-applied at boot by a small systemd unit, because Docker's rules run ahead of
UFW's and iptables rules do not persist.

The allowed sources are whatever `--ui-allow` named, plus the RFC1918 ranges
when `--local` was given; the two add up. With neither, the chain is a bare
`DROP` and the port is closed to everything except loopback — which is why an
SSH tunnel works out of the box but another machine on the LAN does not. That
is the intended default: the window between this script finishing and a human
claiming the admin account is exactly the window an internet-wide scanner
needs, and the first visitor to an unclaimed Dokploy UI becomes its
administrator.

`--local` covers `10.0.0.0/8`, `172.16.0.0/12` and `192.168.0.0/16` only.
`100.64.0.0/10` is excluded on purpose: Tailscale and other overlays use it,
but so do ISPs for CGNAT, so allowing it by default would expose the UI to
other customers on a CGNAT'd connection. Ask for it explicitly with
`--local --ui-allow=100.64.0.0/10`.

### 11. `cloudflared` — Cloudflare Tunnel

Adds Cloudflare's apt repository and installs `cloudflared`. A failure here
warns and continues rather than aborting the run, since the tunnel is optional.
The daemon still needs `cloudflared service install <token>` to be attached to
an account.

### 12. `bun` — JavaScript runtime

Installs Bun into the login account's home directory via the official installer,
run as that user rather than as root. The installer is fetched to a file and
checked for a shebang first, like Dokploy's, and is run with `HOME` and
`BUN_INSTALL` pinned to the account's home rather than whatever `runuser`
passes through. It needs `unzip`, which preflight installed. Skipped if already
present; a failure warns and continues.

### 13. `unattended` — Automatic security updates

Runs after every other installing component, so it can never contend with the
script itself for the apt lock.

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

### 14. `verify` — Access checks

Everything here is read-only; it is the last chance to notice a lockout while
a working shell still exists to fix it from.

- Confirms something is listening on the configured SSH port, and warns not to
  close the session if nothing is.
- Reports whether UFW is active.
- Checks the account's `authorized_keys`: an empty file is only reported
  (password authentication may still be enabled), but a file sshd will
  silently ignore — wrong owner, wrong mode — is warned about explicitly.

---

## Phase 3 — Summary

Collects the public IP, then prints:

- installed versions of Docker, Dokploy, cloudflared, fail2ban and Bun
- the SSH account, port, and key source
- the SSH and Dokploy URLs
- every warning raised during the run, collected in one place
- the numbered manual steps that remain

---

## Failure behaviour

The script runs under `set -Eeuo pipefail` with an `ERR` trap. On failure it
prints the step that was running, the exit code and line number, and the last
twenty log lines pulled back out of the journal, then exits with that code.

Failures inside a command substitution are reported to the log only, since
exiting there would only leave the subshell.

A module that cannot be fetched, carries the wrong markers, targets a different
`setup-api`, or fails its syntax check stops the run in preflight, before any
component has run and before the prerequisites are installed. The temporary
directory holding the modules is removed on exit either way.

Not every failure is fatal. Optional components — cloudflared and Bun — warn and
continue. Anything the rest of the run depends on, such as apt or Docker, stops
the run.
