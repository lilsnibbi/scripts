# Server Initialization Suite

Unattended Debian/Ubuntu setup for VPSs, VMs, systemd CTs and dedicated machines.
Run as root. No flags are required:

```bash
curl -fsSL https://lilsnibbi.dev/scripts/setup.sh | sudo bash
```

From a checkout: `sudo bash lib/setup.sh`. Preview with `--dry-run`.
Logs: `journalctl -t server-init`, or standard error without journald.

The console groups machine identity (Linux release, kernel, architecture,
platform and CT/VM/container classification), the run plan and component results.
`DONE`, `PLAN`, `SKIP` and `NOTE` distinguish completed work, previews, automatic
skips and notices. The final summary collects skip reasons, access commands and
warnings. Detailed command output stays in the journal; the legacy `--verbose`
option also shows routine explanations on the console.

List everything you can skip:

```bash
curl -fsSL https://lilsnibbi.dev/scripts/setup.sh | bash -s -- --list
```

Skip selected components:

```bash
curl -fsSL https://lilsnibbi.dev/scripts/setup.sh | sudo bash -s -- --skip=docker,ssh,fail2ban
```

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

`--ui=203.0.113.9/32` permits a selected IPv4 source; comma-separated CIDRs
are accepted. Restricted mode blocks external IPv6. `--ui=public` opens the UI
publicly; the first visitor creates the administrator. Rerunning the Dokploy
component updates these rules in either direction.

`--ui=local` is for **confirmed physical desktops/laptops**. It permits RFC1918
sources (`10/8`, `172.16/12`, `192.168/16`) to reach Dokploy and use the selected
account's existing SSH password. Servers, VMs, CTs and unknown hardware ignore it.
No password is created or unlocked. Use `--ui=CIDR` on servers.

## Options

The main CLI has twelve options. Defaults handle everything else.

| Option | Purpose |
| :--- | :--- |
| `--skip=a,b` | Skip any components listed by `--list`. Repeated lists combine. |
| `--list` | List every skippable component and exit without changing the host. |
| `--dry-run` | Preview without applying provisioning commands. |
| `--username=NAME` | Login account; default `root`. New accounts receive passwordless sudo. |
| `--pubkey="ssh-..."` | Validate and append a public key. |
| `--ssh-port=N` | Change the SSH port; otherwise preserve existing ports. |
| `--ssh-key-only` | Require a supplied key; disable SSH passwords, retain root key login for Dokploy. |
| `--lockdown-interface=IFACE[,IFACE]` | Block public service ingress on named interfaces, including Docker-published ports. |
| `--ssh-allow=CIDR[,CIDR]\|none` | IPv4 SSH source allowlist for lockdown; `none` blocks public SSH too. |
| `--ui=ACCESS` | `tunnel` (default), IPv4 CIDRs, `public`, or `local`. |
| `--help` | Show compact usage. |
| `--version` | Show version. |

Older flags remain accepted for existing automation; see [compatibility](INFO.md#cli-compatibility).

A new non-root account needs a supplied key or a separately set password before
login. After an explicit port change, verify a new SSH session before disconnecting;
provider firewalls must also permit it. Local checks cannot prove remote access.

## Dedicated server behind Cloudflare Tunnel

Use the reviewed **local checkout** with its matching modules. Since SSH is
already configured, skip its component. For initial setup over your existing
public SSH connection, replace the interface and address placeholders:

```bash
sudo bash lib/setup.sh --base="$PWD/lib" \
  --lockdown-interface=PUBLIC_INTERFACE \
  --ssh-allow=YOUR_ADMIN_PUBLIC_IPV4/32 \
  --ui=tunnel --skip=ssh,bun,cloudflared,tuning
```

Add `--dry-run` to preview first. `ip -br address` helps identify interfaces;
include every interface carrying public traffic, including IPv6. This command
leaves only allowlisted public IPv4 SSH, established replies and network control
traffic. Application ports are blocked before Docker destination translation.
Use a provider firewall with the same restrictions from the start.

For **no public SSH**, use `--ssh-allow=none` from the provider console or after
establishing private management. A run from a detected public SSH session rejects
`none`; existing sessions surviving a firewall change do not prove reconnects work.
The website tunnel does not itself create a private SSH management path.

`--ui=tunnel` protects Dokploy's host port 3000; it does not create a Cloudflare
Tunnel. Follow [Dokploy's container connector guide](https://docs.dokploy.com/docs/core/guides/cloudflare-tunnels)
using internal service names. Host Bun/cloudflared and performance tuning are
unnecessary for this deployment, hence the skips above.

The script leaves existing SSH authentication, keys, ports and forwarding alone.
The firewall discovers configured SSH/socket ports and preserves Docker gateway
SSH for Dokploy's local terminal. Dokploy's generated public key still needs
authorising using its normal setup instructions.
Lockdown assumes a single server; public Swarm peers and public VPN listeners
would need a separately designed policy. See [the production audit](PRODUCTION-AUDIT.md)
for exact effects, testing evidence and remaining deployment checks.

## Components

Execution order: `update`, `base`, `ssh`, `firewall`, `fail2ban`, `hardening`,
`tuning`, `swap`, `docker`, `dokploy`, `cloudflared`, `bun`, `unattended`, `verify`.
Use `--list` for their descriptions.

Skipping `ssh` or `firewall` also omits OpenSSH or UFW from the base package
installation. Skipping `docker` leaves an existing Docker alone; Dokploy needs
Docker already installed or its step is skipped too.

Prerequisites (`curl`, `unzip`, CA certificates) precede components, including
partial runs. CTs need systemd; nested Docker requires host-side permissions such
as Proxmox nesting. Docker/Podman containers cannot host this Dokploy installation
flow. Optional kernel settings are applied only where supported.

## Modules

`lib/setup.sh` loads the selected `lib/setup/*.sh` modules. Resolution order:
`--base`, `SETUP_BASE`, adjacent checkout modules, then
`https://lilsnibbi.dev/scripts`. The publisher must serve both `setup.sh` and
`setup/<component>.sh` from the same revision.

Version 3.6 uses **module API 6**. Publish framework/modules together; older
modules are rejected. Name/API/end markers and Bash syntax detect stale or
truncated files, not malicious code. Module sources execute as root and must be trusted.

See [INFO.md](INFO.md) for testing and implementation boundaries.
