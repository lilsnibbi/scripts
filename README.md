# Server Initialization Suite

A Bash script that turns a fresh Debian or Ubuntu machine — Proxmox VM or
container, KVM guest, VPS, dedicated box, or a laptop serving as one — into a
Dokploy host. It is written to run unattended on first boot, hundreds of times
a day: every step is idempotent, every network operation retries, and any
failure stops the run with the exact step, the exit code, and the tail of the
log.

Supported systems: **Debian** and **Ubuntu** (and Debian-based derivatives,
with a warning). It must run as root.

---

## Quick start

```bash
curl -fsSL https://lilsnibbi.dev/scripts/setup.sh | sudo bash -s -- --pubkey="$(cat ~/.ssh/id_ed25519.pub)"
```

That configures the `root` account, installs Docker and Dokploy, and leaves SSH
authentication exactly as the image shipped it. `--pubkey` authorises a key;
`--ssh-port=N` moves the listening port.

A more typical production invocation:

```bash
curl -fsSL https://lilsnibbi.dev/scripts/setup.sh | sudo bash -s -- \
  --username=deploy \
  --ssh-port=2222 \
  --ui-allow=203.0.113.9/32 \
  --hostname=app-01 \
  --timezone=Europe/Amsterdam
```

Preview everything without touching the system:

```bash
curl -fsSL https://lilsnibbi.dev/scripts/setup.sh | sudo bash -s -- --dry-run
```

From a checkout, `sudo lib/setup.sh [options]` works the same way and uses the
component modules beside it instead of fetching them.

---

## Layout

The script is split into a framework and one file per component:

```
lib/
  setup.sh            options, console output, journal logging, helpers,
                      preflight, summary — the file you curl
  setup/
    update.sh         one component each; every file defines fn_<name>
    base.sh
    ssh.sh
    ...
    verify.sh
```

`setup.sh` fetches only the modules for the components that will run, from
`<base>/setup/<name>.sh`, and it fetches all of them **before any component
runs**. Each module carries three markers — its name, the `setup-api` number it
was written against, and an `# end-of-module` line — and is syntax-checked, so
a wrong file, a stale file from a half-finished deploy, or a truncated download
aborts the run while the machine is still untouched. The `setup-api` number in
`setup.sh` is bumped only when a helper changes incompatibly.

The base defaults to `https://lilsnibbi.dev/scripts`, which serves the `lib/`
directory of this repository. Whatever serves `setup.sh` must serve
`setup/<name>.sh` under the same base. The base is resolved in this order:

1. `--base=URL` (or an absolute directory)
2. the `SETUP_BASE` environment variable
3. a `setup/` directory beside `setup.sh`, when run from a checkout
4. the default

The modules are sourced into the running script, so they share its options,
helpers and error trap, and there is nothing to install on the host.

---

## SSH keys

**The script does not generate keys.** An earlier version minted an ed25519
keypair and printed the private half to the console, which is useless to an
unattended run — nobody is watching the terminal to copy it — and loses the
account the moment that output scrolls away.

Keys come from one of two places, both of which exist before the run starts:

1. `--pubkey="ssh-ed25519 AAAA..."` — **appended** to `~/.ssh/authorized_keys`
   for the target account. Existing entries are never removed.
2. Whatever `authorized_keys` the account already has, which is the normal case
   on a cloud image where you supplied a key at creation time. It is left
   untouched.

If neither applies, the run continues anyway. Because the script no longer
disables password authentication, an account with no keys is not a lockout —
sshd goes on accepting whatever it accepted before. The verify step reports the
situation and moves on.

Connect the usual way once the run finishes:

```bash
ssh -i ~/.ssh/id_ed25519 -p 2222 deploy@<server-ip>
```

---

## Options

### Account and SSH

| Option | Description |
| :--- | :--- |
| `--username=NAME` | Account to configure. Default `root`. A non-root name is created if missing and given passwordless sudo. Root SSH login is left as the system had it. |
| `--ssh-port=N` | Port for sshd, and the port opened in the firewall. Default `22`. The only sshd setting the script writes. |
| `--pubkey="ssh-..."` | Append this public key to the account's `authorized_keys`. Optional. |

### System

| Option | Description |
| :--- | :--- |
| `--hostname=NAME` | Set the system hostname (and keep `/etc/hosts` consistent). |
| `--timezone=ZONE` | Set the timezone, e.g. `Europe/Amsterdam`. |
| `--ui-allow=CIDR[,CIDR]` | Restrict the Dokploy UI on port 3000 to these sources. See [Dokploy UI exposure](#dokploy-ui-exposure). |
| `--local` | Allow the private ranges (`10/8`, `172.16/12`, `192.168/16`) to reach the Dokploy UI. The shorthand for "reachable from my LAN" without naming a subnet. Adds to `--ui-allow` rather than replacing it. |
| `--ui-public` | Expose the Dokploy UI to the whole internet. The first visitor to reach it becomes the admin. |
| `--auto-reboot=HH:MM` | Let unattended-upgrades reboot in this window when a patch needs it. Default: never reboot automatically, which means kernel patches stay inactive until a manual reboot. |
| `--remove-snapd` | Purge snapd and hold the package (Ubuntu). Off by default: a Docker host does not need it, but removing a package manager should be asked for, not assumed. |
| `--reset-firewall` | Wipe existing UFW rules before applying the baseline. Off by default so a re-run does not destroy custom rules. |
| `--reinstall-dokploy` | Reinstall Dokploy even if it is present. **Destructive** — Dokploy's installer leaves and re-initialises Docker Swarm. |

### Selection

| Option | Description |
| :--- | :--- |
| `--exclude=a,b` | Skip these components. |
| `--only=a,b` | Run only these components. |
| `--list` | List the components and exit. |

Unknown component names are rejected rather than silently ignored, so a typo in
`--exclude` fails loudly instead of quietly doing the wrong thing.

### Behaviour

| Option | Description |
| :--- | :--- |
| `--base=URL` | Fetch component modules from `URL/setup/<name>.sh`. Also accepts an absolute directory. Default: `https://lilsnibbi.dev/scripts`, or the `setup/` directory beside the script when run from a checkout. See [Layout](#layout). |
| `--dry-run` | Show what would happen; change nothing. The modules are still fetched, since a dry run has to describe them. |
| `--verbose` | Disable the spinner and print each action as a plain line. Useful when piping to a file. |
| `--no-color` | Disable coloured output. Colour is disabled automatically when stdout is not a terminal or when `NO_COLOR` is set. |
| `--version` | Print the script version and exit. |
| `--help` | Show the built-in help. |

---

## Components

Components run in this order. Any of them can be skipped.

Before the first component, preflight installs the prerequisites the run cannot
start without — `curl`, `unzip` and `ca-certificates` — so they are present
whatever `--only` or `--exclude` says. `unzip` in particular is missing from
most minimal images and required before anything else runs.

| Component | What it does |
| :--- | :--- |
| `update` | Sets hostname and timezone, refreshes apt indexes, then runs a full `dist-upgrade` including phased updates, and autoremoves. Always the first step. |
| `base` | Installs `curl`, `wget`, `git`, `jq`, `unzip`, `iproute2`, `dnsutils`, `openssh-server`, `sudo`, `ufw`, and related utilities. |
| `ssh` | Creates the login account, optionally appends a public key, and sets the sshd port. |
| `firewall` | Applies the UFW baseline: deny incoming, allow outgoing, rate-limited SSH, and the Dokploy ports. |
| `fail2ban` | Installs fail2ban with an SSH jail (reading the systemd journal) and a `recidive` jail (reading fail2ban's own log). |
| `hardening` | Kernel network sysctls (Docker-safe), journald size caps, and locks root's password once the login account demonstrably has keys. |
| `tuning` | Environment-aware performance tuning: BBR and backlog sysctls, inotify and map-count limits, sleep/lid inhibited, performance CPU governor on bare metal, Ubuntu crash/ad noise off, optional snapd removal. Each piece probes for its environment (container, KVM, VPS, dedicated, laptop) and skips what does not apply. |
| `swap` | Creates a swapfile when the machine has under 8 GB of RAM and no swap. Skipped in containers, where swap belongs to the host. |
| `docker` | Installs Docker CE from Docker's apt repository and configures container log rotation. |
| `dokploy` | Installs Dokploy, then optionally restricts its UI port. |
| `cloudflared` | Installs the Cloudflare Zero Trust tunnel daemon. |
| `bun` | Installs the Bun JavaScript runtime into the login account's home directory, running the official installer as that account. |
| `unattended` | Enables automatic security updates. Runs after everything else so it cannot contend for the apt lock. |
| `verify` | Read-only checks: sshd listening on the configured port, UFW active, and the account's `authorized_keys` usable. |

---

## Security model

### SSH

**The script does not harden sshd, and does not generate keys.** Both were
removed deliberately. Every authentication directive worth setting is also a
directive that can refuse a login, and this script is built to run unattended
on first boot — there is nobody at the console to notice that the host stopped
accepting connections. A hardened server you cannot reach is worse than an
unhardened one you can.

What it still does to SSH:

| Action | Why it is safe |
| :--- | :--- |
| Creates the login account with passwordless sudo | Adds a way in, never removes one |
| Appends `--pubkey` to `authorized_keys`, if given | Append-only; existing keys are never touched |
| Writes `Port N` to `/etc/ssh/sshd_config.d/00-server-init.conf` | Cannot deny a login on its own, and the firewall step has to agree with it |
| Comments out `Port` elsewhere in `sshd_config.d` | sshd keeps the *first* value it finds, so a cloud image's `50-cloud-init.conf` would otherwise win |
| Opens that port in UFW, rate-limited | |

That drop-in is the entire managed configuration:

```
Port 2222
```

Nothing else. `PasswordAuthentication`, `PermitRootLogin`, `AllowUsers`,
`AuthenticationMethods`, `MaxAuthTries`, `LoginGraceTime`, the
`KexAlgorithms`/`Ciphers`/`MACs` lists, and the Diffie-Hellman moduli pruning
were all removed. Whatever the image shipped, it keeps.

The drop-in is still validated with `sshd -t` before sshd is restarted. If
validation fails, the drop-in is removed and SSH is left exactly as it was. If
the *baseline* configuration also fails validation, the problem pre-dates this
script; the drop-in is kept and the real error is reported as a warning.

> **Hardening is left to you.** Change the port here, then apply your own
> authentication policy by hand, from a session you have already confirmed
> works. That is the one thing an automated first-boot script cannot do safely.

On Ubuntu 24.04 and Debian 13, sshd is socket-activated and the `Port`
directive in `sshd_config` is ignored. The script detects this and writes a
`ssh.socket` drop-in instead.

> **Always open a second terminal and confirm the new SSH login works before
> closing the session you ran the script from.** Existing sessions survive an
> sshd restart, so a mistake is recoverable — but only while you are still
> connected.

### Dokploy UI exposure

This is the one thing worth reading twice.

Docker inserts its own iptables rules ahead of UFW's. **A published container
port is reachable even when UFW says it is denied.** The UFW rules the script
adds for ports 80, 443 and 3000 do not restrict Dokploy's containers.

Dokploy's admin account is created by whoever loads the UI first. On a public
IP with port 3000 open, that can be someone else.

By default port 3000 is closed to the network entirely. Loopback is unaffected —
a published port reached over `127.0.0.1` never traverses the `FORWARD` chain —
so an SSH tunnel works with no rules at all, but **another machine on your LAN
cannot reach it**. That is deliberate, and it is what `--local` opts out of:

```bash
# reachable from any private address (10/8, 172.16/12, 192.168/16)
sudo ./setup.sh --only=dokploy --local
```

Or name the sources exactly, which is tighter:

```bash
sudo ./setup.sh --only=dokploy --ui-allow=203.0.113.9/32,198.51.100.0/24
```

The two add up, so `--local --ui-allow=100.64.0.0/10` gets you the LAN plus a
Tailscale range. `100.64.0.0/10` is deliberately **not** part of `--local`: it is
CGNAT space, handed out by ISPs as well as by overlay networks, so including it
by default would expose the UI to strangers on a CGNAT'd connection.

That installs a rule in the `DOCKER-USER` chain — the only place Docker
respects — and a small systemd unit that re-applies it at boot, since iptables
rules do not persist. Alternatively, leave port 3000 closed to the world and
reach the UI through the Cloudflare tunnel the script installs.

To see the rule currently in force:

```bash
sudo iptables -L DOKPLOY-UI -n -v
```

A chain containing only a `DROP` is the default, closed state.

### fail2ban

The jail is configured with `backend = systemd`, and `python3-systemd` is
installed to support it. Recent Debian and Ubuntu images ship without rsyslog,
so `/var/log/auth.log` may not exist and the default file backend fails to
start. Reading the journal works on every supported release.

### Automatic updates

`unattended-upgrades` is restricted to the security pocket, never reboots on
its own, and excludes the Docker packages — an automatic Docker or containerd
upgrade restarts the daemon underneath running containers. Unused kernels and
dependencies are removed, which prevents `/boot` filling up and breaking apt
months later.

Docker and Dokploy updates are therefore deliberately manual:

```bash
sudo apt-get update && sudo apt-get install --only-upgrade docker-ce docker-ce-cli containerd.io
curl -sSL https://dokploy.com/install.sh | sudo bash -s update
```

---

## Re-running the script

Every component is safe to re-run. Packages already installed are detected,
files are only rewritten when their content changes, existing SSH keys are kept,
and UFW rules are added without resetting the ruleset.

The one exception is Dokploy. Its official installer runs `docker swarm leave
--force` and recreates the overlay network on every invocation, which would
disrupt a working deployment. The script therefore detects an existing Dokploy
installation and skips it unless you pass `--reinstall-dokploy`.

---

## Output and logging

The console shows a numbered step list, a spinner for long operations, and a
final summary with installed versions, the SSH details, every warning raised
during the run, and the remaining manual steps.

**No log file is written.** Full command output goes to the systemd journal
under the tag `server-init`:

```bash
journalctl -t server-init
```

On failure the script prints the failing step, the exit code, and the last
twenty log lines from the journal. The journal is size-capped by the
`hardening` component, so logging can never fill the disk.

Colour and the spinner switch off automatically when the output is not a
terminal, so piping to a file produces clean text.

---

## Reliability notes

Several things that commonly break unattended first-boot scripts are handled
explicitly:

- **Modules before changes.** Every component module is fetched, checked for
  its markers and syntax-checked before the first component runs, so a bad
  deploy or a network fault aborts with the machine untouched.
- **Prerequisites first.** `curl`, `unzip` and `ca-certificates` are installed
  in preflight, ahead of every component, so even `--only=bun` has what it
  needs.
- **Wrong clock.** Time synchronisation is confirmed in preflight, before the
  first apt call and TLS handshake. A skewed clock makes apt reject Release
  files and TLS fail on `notBefore`, and neither error mentions the clock.
- **apt lock contention.** On a freshly booted cloud VM the `apt-daily` and
  `unattended-upgrades` timers hold the dpkg lock for the first minute or two.
  The script waits for the lock (up to five minutes) and waits for `cloud-init`
  to finish before touching apt.
- **needrestart prompts.** Ubuntu 22.04 and later show an interactive "which
  services should be restarted?" dialog during upgrades, which hangs an
  unattended run forever. `NEEDRESTART_MODE=a` suppresses it.
- **Network flakiness.** Every download and apt operation is retried three times
  with backoff.
- **Piped installers.** The Dokploy and Bun installers are downloaded to a file
  and checked for a shebang before being executed, so a captive portal or error
  page is never piped into a shell.
- **`curl | bash` itself.** Once the script has been parsed it closes its own
  stdin, so no child can swallow the rest of the script off the pipe. It also
  pins `PATH` to include the sbin directories, which `pct exec`, cloud-init and
  a bare root shell do not always provide.
- **No journal.** The journal socket is checked before logging starts. A host
  where systemd is installed but journald is not running (a chroot, a plain
  Docker image) would otherwise kill the script with SIGPIPE on its first log
  line.
- **Containers.** Proxmox CTs are a first-class target. Things the host owns —
  the clock, swap, the CPU governor, power management — are skipped there with
  a note rather than attempted and warned about.
- **Port conflicts.** Dokploy's installer aborts if anything holds ports 80, 443
  or 3000. The script checks first and reports which process holds the port.

---

## After the run

1. **Verify SSH** from a second terminal before closing the current session.
2. **Open the Dokploy UI and create the admin account immediately** — the first
   visitor to reach it becomes the administrator.
3. **Attach the Cloudflare tunnel**, if you use one:
   ```bash
   sudo cloudflared service install <your-tunnel-token>
   ```
4. **Reboot** if the summary reported that a reboot is required.

---

## Testing locally

`Dockerfile` builds an Ubuntu 24.04 image running systemd as PID 1, so sshd,
ufw, fail2ban and dockerd behave the way they do on a real VM rather than being
stubbed out. It is meant for running the script by hand and throwing the machine
away afterwards.

```bash
docker build -t init-scripts-test .

docker run -d --name init-test --privileged --cgroupns=host \
  --tmpfs /run --tmpfs /run/lock \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v "$PWD:/opt/init-scripts" \
  init-scripts-test

docker exec -it init-test bash
```

Inside the container:

```bash
cd /opt/init-scripts
lib/setup.sh --dry-run
lib/setup.sh --username=deploy --ssh-port=2222 --ui-allow=10.0.0.0/8
```

Run from the checkout like this, the script loads the modules from
`lib/setup/` beside it. To exercise the network path instead, point it at a
served copy — a branch on GitHub, say:

```bash
lib/setup.sh --dry-run --base=https://raw.githubusercontent.com/lilsnibbi/scripts/refs/heads/<branch>/lib
```

The piped form can be tested the same way:

```bash
cat lib/setup.sh | bash -s -- --dry-run --base=/opt/init-scripts/lib
```

Verify the result from inside the same container:

```bash
systemctl is-active ssh fail2ban docker
ss -tlnp | grep 2222
ufw status
ssh -i /path/to/key -p 2222 deploy@127.0.0.1
```

Start from a clean machine with `docker rm -f init-test` and run the container
again. Two caveats: Dokploy's installer refuses to run while `/.dockerenv`
exists, and Docker Swarm inside a container is not representative — test Dokploy
itself on a real VM.

---

## Troubleshooting

**The run failed partway through.** Read the printed step, then the journal
(`journalctl -t server-init`). Fix the cause and re-run just that part, for
example `sudo ./setup.sh --only=docker`.

**"Could not load module" or "out of sync".** The framework and the modules
are served separately, and each is cached for a few minutes. A run that lands
in the window right after a deploy can see a new `setup.sh` with an old module,
or the reverse. Nothing has been changed on the machine at that point; retry a
few minutes later. A persistent failure means the base URL is not serving
`setup/<name>.sh`.

**SSH stopped working.** Existing sessions survive an sshd restart, so use the
session you still have open. The previous configuration is backed up next to
each file it edited as `<file>.bak-<timestamp>`. Restore it and run
`systemctl restart ssh`.

**Dokploy did not come up.** Check `docker service ls` and
`docker service logs dokploy`. The script waits 90 seconds for the UI to answer
and warns if it does not.

**fail2ban will not start.** Check `journalctl -u fail2ban`. The usual cause is
a missing `python3-systemd`, which the script installs.
