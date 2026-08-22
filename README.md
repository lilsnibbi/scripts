# Server Initialization Suite

A single self-contained Bash script that turns a freshly provisioned Debian or
Ubuntu VM into a hardened Dokploy host. It is written to run unattended on
first boot: every step is idempotent, every network operation retries, and any
failure stops the run with the exact step, the exit code, and the tail of the
log.

Supported systems: **Debian** and **Ubuntu** (and Debian-based derivatives,
with a warning). It must run as root.

---

## Quick start

```bash
chmod +x setup.sh
sudo ./setup.sh
```

With no arguments the script configures the `root` account, generates an
ed25519 SSH keypair, prints the private key to the console, disables password
login, and installs Docker and Dokploy.

A more typical production invocation:

```bash
sudo ./setup.sh \
  --username=deploy \
  --ssh-port=2222 \
  --ui-allow=203.0.113.9/32 \
  --hostname=app-01 \
  --timezone=Europe/Amsterdam
```

Preview everything without touching the system:

```bash
sudo ./setup.sh --dry-run
```

---

## The private key

When the target account has no authorized keys yet, the script generates an
ed25519 keypair, installs the public half into `~/.ssh/authorized_keys`, and
prints the private half to the console.

**The private key is never written to disk and never written to the log.** The
script keeps two output streams apart for exactly this reason: command output
goes to `/var/log/server-init-<timestamp>.log`, and the key goes only to your
terminal. If you close the session without copying it, it is gone.

Copy it, save it locally, and connect:

```bash
chmod 600 ~/.ssh/deploy_key
ssh -i ~/.ssh/deploy_key -p 2222 deploy@<server-ip>
```

Use `--save-key=/root/deploy_key` if you would rather have it written to a file
as well (mode 0600). Delete that file once you have copied it.

If the account **already** has authorized keys — which is the normal case on a
cloud image where you supplied a key at creation time — the script keeps them
and generates nothing. Pass `--new-key` to generate an additional keypair
anyway, or `--pubkey="ssh-ed25519 AAAA..."` to install a key you already have.

---

## Options

### Account and SSH

| Option | Description |
| :--- | :--- |
| `--username=NAME` | Account to configure. Default `root`. A non-root name is created if missing, given passwordless sudo, and root SSH login is then disabled. |
| `--ssh-port=N` | Port for sshd. Default `22`. |
| `--pubkey="ssh-..."` | Install this public key instead of generating a keypair. |
| `--new-key` | Generate a fresh keypair even if the account already has authorized keys. |
| `--save-key=PATH` | Also write the generated private key to `PATH` (mode 0600). |
| `--keep-password-auth` | Leave SSH password login enabled. Not recommended. |

### System

| Option | Description |
| :--- | :--- |
| `--hostname=NAME` | Set the system hostname (and keep `/etc/hosts` consistent). |
| `--timezone=ZONE` | Set the timezone, e.g. `Europe/Amsterdam`. |
| `--ui-allow=CIDR[,CIDR]` | Restrict the Dokploy UI on port 3000 to these sources. See [Dokploy UI exposure](#dokploy-ui-exposure). |
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
| `--dry-run` | Show what would happen; change nothing. |
| `--verbose` | Disable the spinner and print each action as a plain line. Useful when piping to a file. |
| `--no-color` | Disable coloured output. Colour is disabled automatically when stdout is not a terminal or when `NO_COLOR` is set. |
| `--version` | Print the script version and exit. |
| `--help` | Show the built-in help. |

---

## Components

Components run in this order. Any of them can be skipped.

| Component | What it does |
| :--- | :--- |
| `update` | Sets hostname and timezone, refreshes apt indexes, applies pending upgrades, autoremoves. |
| `base` | Installs `curl`, `wget`, `git`, `jq`, `unzip`, `iproute2`, `dnsutils`, `openssh-server`, `sudo`, `ufw`, and related utilities. |
| `ssh` | Creates the login account, installs SSH keys, and hardens sshd. |
| `firewall` | Applies the UFW baseline: deny incoming, allow outgoing, rate-limited SSH, and the Dokploy ports. |
| `fail2ban` | Installs fail2ban with an SSH jail and a `recidive` jail, reading the systemd journal. |
| `swap` | Creates a swapfile when the machine has under 8 GB of RAM and no swap. |
| `docker` | Installs Docker CE from Docker's apt repository and configures container log rotation. |
| `dokploy` | Installs Dokploy, then optionally restricts its UI port. |
| `cloudflared` | Installs the Cloudflare Zero Trust tunnel daemon. |
| `bun` | Installs the Bun JavaScript runtime into the login account's home directory. |
| `unattended` | Enables automatic security updates. Runs last so it cannot contend for the apt lock. |

---

## Security model

### SSH

The account and its `authorized_keys` are set up and verified **before** sshd is
touched. If no usable key ends up installed, the script refuses to harden sshd
at all rather than risk a lockout.

The hardened settings live in `/etc/ssh/sshd_config.d/00-server-init.conf`. The
`00-` prefix matters: sshd keeps the **first** value it finds for a directive,
and cloud images ship `50-cloud-init.conf` with `PasswordAuthentication yes`.
Sorting first means nothing later can weaken the settings. For good measure the
script also comments out the directives it owns wherever else they appear, and
backs up every file it edits.

Applied settings:

- Password and keyboard-interactive authentication disabled; `AuthenticationMethods publickey`
- `PermitRootLogin prohibit-password`, or `no` when `--username` is not root
- `AllowUsers` limited to the configured account
- `MaxAuthTries 3`, `LoginGraceTime 30`, `MaxStartups 10:30:60`
- Idle sessions dropped after 10 minutes
- X11 and agent forwarding disabled
- Modern key exchange, cipher, and MAC lists, filtered against what the
  installed OpenSSH actually supports so the configuration cannot be rejected
  on older releases
- Diffie-Hellman moduli below 3072 bits removed

The generated configuration is validated with `sshd -t` before sshd is
restarted. If validation fails, the drop-in is removed and SSH is left exactly
as it was. If the *baseline* configuration also fails validation, the problem
pre-dates this script; the hardening is kept and the real error is reported as
a warning.

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

Pass `--ui-allow` with the addresses that should reach the UI:

```bash
sudo ./setup.sh --only=dokploy --ui-allow=203.0.113.9/32,198.51.100.0/24
```

That installs a rule in the `DOCKER-USER` chain — the only place Docker
respects — and a small systemd unit that re-applies it at boot, since iptables
rules do not persist. Alternatively, leave port 3000 closed to the world and
reach the UI through the Cloudflare tunnel the script installs.

Without `--ui-allow` the script warns loudly and continues.

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

Full command output goes to `/var/log/server-init-<timestamp>.log`. On failure
the script prints the failing step, the exit code, and the last twenty lines of
that log.

Colour and the spinner switch off automatically when the output is not a
terminal, so piping to a file produces clean text.

---

## Reliability notes

Several things that commonly break unattended first-boot scripts are handled
explicitly:

- **apt lock contention.** On a freshly booted cloud VM the `apt-daily` and
  `unattended-upgrades` timers hold the dpkg lock for the first minute or two.
  The script waits for the lock (up to five minutes) and waits for `cloud-init`
  to finish before touching apt.
- **needrestart prompts.** Ubuntu 22.04 and later show an interactive "which
  services should be restarted?" dialog during upgrades, which hangs an
  unattended run forever. `NEEDRESTART_MODE=a` suppresses it.
- **Network flakiness.** Every download and apt operation is retried three times
  with backoff.
- **Piped installers.** The Dokploy installer is downloaded to a file and
  checked for a shebang before being executed, so a captive portal or error page
  is never piped into a shell.
- **Port conflicts.** Dokploy's installer aborts if anything holds ports 80, 443
  or 3000. The script checks first and reports which process holds the port.

---

## After the run

1. **Copy the private key** from the console if one was generated.
2. **Verify SSH** from a second terminal before closing the current session.
3. **Open the Dokploy UI and create the admin account immediately** — the first
   visitor to reach it becomes the administrator.
4. **Attach the Cloudflare tunnel**, if you use one:
   ```bash
   sudo cloudflared service install <your-tunnel-token>
   ```
5. **Reboot** if the summary reported that a reboot is required.

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
./setup.sh --dry-run
./setup.sh --username=deploy --ssh-port=2222 --ui-allow=10.0.0.0/8
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

**The run failed partway through.** Read the printed step and the log path. Fix
the cause, then re-run just that part, for example `sudo ./setup.sh --only=docker`.

**SSH stopped working.** Existing sessions survive an sshd restart, so use the
session you still have open. The previous configuration is backed up next to
each file it edited as `<file>.bak-<timestamp>`. Restore it and run
`systemctl restart ssh`.

**Dokploy did not come up.** Check `docker service ls` and
`docker service logs dokploy`. The script waits 90 seconds for the UI to answer
and warns if it does not.

**fail2ban will not start.** Check `journalctl -u fail2ban`. The usual cause is
a missing `python3-systemd`, which the script installs.
