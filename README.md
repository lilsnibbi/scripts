# Server Initialization Suite

Unattended Debian/Ubuntu setup for VPSs, VMs, systemd CTs and dedicated machines.
Run as root. No flags are required:

```bash
curl -fsSL https://lilsnibbi.dev/scripts/setup.sh | sudo bash
```

From a checkout: `sudo bash lib/setup.sh`. Preview with `--dry-run`.
Logs: `journalctl -t server-init`, or standard error without journald.

## Defaults

- Preserve existing SSH authentication, listening ports, keys and root password.
  The account defaults to `root`; no keys or passwords are generated.
- Upgrade packages without removals or forced early phased updates. Upgrades
  can restart services; run during an appropriate maintenance window.
- Preserve existing Docker runtimes and daemon configuration. Fresh Docker
  installations receive bounded container logs before startup.
- Skip Dokploy on unrelated container/Swarm hosts, Pterodactyl hosts or occupied
  ports. Retain existing Dokploy installations.
- Preserve firewall policy on container hosts and hosts with additional listening
  services. Otherwise configure UFW, retaining existing rules and active defaults.
  Docker-published application ports bypass UFW.
- Protect Dokploy TCP port 3000 **before installation**, for IPv4 and IPv6,
  before Docker translates destinations. Loopback access remains available.
- Preserve existing swapfiles, package blacklists and operator-owned fail2ban
  `jail.local` policies. Never lock the root rescue password.
- Set UTC, apply supported kernel/power settings and enable security updates.
  Automatic rebooting is off.

One modifying run executes at a time. Module validation precedes system changes;
package contention times out without killing another updater. Failed configuration
writes stop the run instead of silently reporting success.

## Dokploy access

By default, connect through an SSH tunnel:

```bash
ssh -L 3000:localhost:3000 root@server
```

Then visit `http://localhost:3000`. Use your existing SSH port/account if different.

`--ui-allow=203.0.113.9/32` permits a selected IPv4 source; comma-separated CIDRs
are accepted. Restricted mode blocks external IPv6. `--ui-public` opens the UI
publicly; the first visitor creates the administrator. Rerunning the Dokploy
component updates these rules in either direction.

`--local` is for **confirmed physical desktops/laptops**. It permits RFC1918
sources (`10/8`, `172.16/12`, `192.168/16`) to reach Dokploy and use the selected
account's existing SSH password. Servers, VMs, CTs and unknown hardware ignore it.
No password is created or unlocked. Use `--ui-allow` on servers.

## Options

Use only the settings you need. No new flags are required for safe reruns.

| Option | Purpose |
| :--- | :--- |
| `--username=NAME` | Configure an account; create it with passwordless sudo if missing. Default `root`. |
| `--pubkey="ssh-..."` | Validate and append one public key. |
| `--ssh-port=N` | Explicitly change the SSH port; allow it in active UFW before restarting SSH. |
| `--hostname=NAME` | Set a validated hostname. |
| `--timezone=ZONE` | Default `UTC`; `keep` preserves the current setting. |
| `--ui-allow=CIDR[,CIDR]` | Permit selected IPv4 sources to reach Dokploy. |
| `--local` | Desktop/laptop LAN convenience described above. |
| `--ui-public` | Public Dokploy UI. Conflicts with `--ui-allow` and `--local`. |
| `--only=a,b` / `--exclude=a,b` | Select or skip components. Mutually exclusive. |
| `--auto-reboot=HH:MM` | Permit unattended-upgrades to reboot at this time when required. |
| `--remove-snapd` | Explicitly remove snapd and installed snaps. |
| `--reset-firewall` | Explicitly discard UFW rules and apply the baseline. |
| `--reinstall-dokploy` | Destructive reinstall, including Swarm reinitialisation. |
| `--base=URL` | Module source; also accepts an absolute local directory. |
| `--dry-run` | Preview without applying provisioning commands. |
| `--verbose` | Plain progress instead of the spinner. |
| `--no-color` | Disable colours; automatic when redirected or `NO_COLOR` is set. |
| `--list`, `--version`, `--help` | Inspect components, version or usage. |

A new non-root account needs a supplied key or a separately set password before
login. After an explicit port change, verify a new SSH session before disconnecting;
provider firewalls must also permit it. Local checks cannot prove remote access.

## Components

Execution order: `update`, `base`, `ssh`, `firewall`, `fail2ban`, `hardening`,
`tuning`, `swap`, `docker`, `dokploy`, `cloudflared`, `bun`, `unattended`, `verify`.
Use `--list` for their descriptions.

Prerequisites (`curl`, `unzip`, CA certificates) precede components, including
partial runs. CTs need systemd; nested Docker requires host-side permissions such
as Proxmox nesting. Docker/Podman containers cannot host this Dokploy installation
flow. Optional kernel settings are applied only where supported.

## Modules

`lib/setup.sh` loads the selected `lib/setup/*.sh` modules. Resolution order:
`--base`, `SETUP_BASE`, adjacent checkout modules, then
`https://lilsnibbi.dev/scripts`. The publisher must serve both `setup.sh` and
`setup/<component>.sh` from the same revision.

Version 3.3 uses **module API 4**. Publish framework/modules together; older
modules are rejected. Name/API/end markers and Bash syntax detect stale or
truncated files, not malicious code. Module sources execute as root and must be trusted.

See [INFO.md](INFO.md) for testing and implementation boundaries.
