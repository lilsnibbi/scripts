# Production audit: Ubuntu 26.04 and Dokploy

Reviewed 16 September 2026 for a fresh dedicated server, with a separately configured Cloudflare Tunnel.

**Identified defects are fixed locally. This is not end-to-end Ubuntu 26.04 production validation.** The actual server, IPv6 packets and a reboot were unavailable for testing. Use this reviewed checkout: version 3.6.0/API 6. The live download was version 3.5.0/API 5 when checked and does not contain these changes.

## Corrections made

| Original issue | Correction |
| --- | --- |
| Tunnel mode still opened SSH/web ports; UFW misses Docker-published ports. | New public-interface guard filters before Docker NAT, before component installations. SSH can be source-restricted or closed with `none`. |
| DHCP/NTP could skip the whole fresh-host firewall step. | UDP 68/546/123 no longer cause that skip. Unrelated workloads still retain their policy. |
| A supplied key did not disable password authentication. | Explicit `--ssh-key-only` disables passwords/keyboard-interactive authentication, retains root key login, and validates/rolls back SSH changes. |
| Upstream Dokploy could exit zero after failed creation commands. | Expected replicas, PostgreSQL readiness, database-backed application health and Traefik response must pass. |
| Mutable Dokploy installer. | v0.30.6 release installer and matching application version, with a fixed installer SHA-256. Existing deployments are not upgraded automatically. |
| Upstream creates `/etc/dokploy` with mode 777. | Wrapper removes group/other write permission and checks root ownership/symlinks. |
| Restarting a required firewall unit can restart Docker. | Guards now implement reload; reruns use `reload-or-restart`. |
| Failed fail2ban/security-update setup could still complete. | Selected setup failures are fatal, fail2ban's SSH jail is checked, and update timers are explicitly enabled. |

## Every step and its effects

| Order | Step | Commands and effects |
| --- | --- | --- |
| Before components | Preflight | Parses flags; serialises runs with `flock`; checks root/OS/systemd; loads and validates modules; detects SSH ports; checks DNS/clock and waits for package locks. Installs missing curl/unzip/CA certificates. Lockdown validates interfaces/current SSH access and installs a persistent iptables/ip6tables guard before component packages start daemons. |
| 1 | `update` | Sets UTC unless configured otherwise; changes hostname only if requested. Refreshes APT and upgrades with new dependencies allowed, removals forbidden and existing configurations retained where applicable. Packages can restart services; kernel updates can require reboot. |
| 2 | `base` | Installs certificate/download/GPG tools, git/archive/jq tools, networking/DNS/process tools, sudo, htop and rsync. Includes OpenSSH/UFW when selected. Installing packages can start services. |
| 3 | `ssh` | Validates/appends the supplied key and fixes conventional key-file ownership/modes. Defaults to root; a chosen non-root account receives unrestricted passwordless sudo. Preserves ports unless explicitly changed. Key-only mode disables SSH passwords while retaining root keys and PAM. Configuration/policy/restart failures trigger rollback. |
| 4 | `firewall` | Configures/enables UFW on a fresh host. Lockdown uses source-specific SSH rules, no public web allows, and Docker gateway SSH rules for Dokploy's terminal. The independent guard covers Docker-published ports. Existing workloads/unfamiliar listeners still skip UFW baseline changes. |
| 5 | `fail2ban` | Installs fail2ban and Python journal support. SSH: three failures within ten minutes, one-hour ban. Repeat offenders: five events within a day, one-week ban. Covers preserved SSH ports. Restarts/checks the service; operator-owned `jail.local` remains unchanged. |
| 6 | `hardening` | Applies SYN cookies, loose reverse-path checks, redirect/source-route rejection, kernel pointer restrictions and filesystem link protections. Preserves IP forwarding and root's console password. Caps journald at 500 MB/one month, keeps a 1 GB free-space target, and restarts journald. Unsupported optional sysctls warn. |
| 7 | `tuning` | Attempts BBR/fair queueing and changes connection/watch/map limits. Masks sleep, applies a persistent performance CPU governor, handles laptop lids, and disables Ubuntu crash/news features. Can affect power/heat/workload behaviour. Snap purge requires its explicit flag. Recommended command skips tuning. |
| 8 | `swap` | Preserves existing swap. Below 8192 MiB RAM, creates at least 2048 MiB or roughly RAM-sized swap if disk space permits. Activates it, adds fstab entry, sets swappiness 10/cache pressure 50. Unsupported allocation/filesystem cases warn and skip. |
| 9 | `docker` | Adds Docker's signing key/APT repository on fresh installs; writes 20 MB × 5 per-container log defaults before installing Engine/CLI/containerd/Buildx/Compose. Enables/starts Docker, which changes interfaces/forwarding/firewall rules. Preserves working existing runtime/config. Selected non-root account joins the root-equivalent Docker group. |
| 10 | `dokploy` | Checks ports/workloads, protects host TCP 3000 before launch, checksums and executes the pinned installer, corrects top-level directory permissions, and requires database/application/proxy readiness. Detailed upstream operations below. |
| 11 | `cloudflared` | Installs a host binary through Cloudflare's APT repository. Does not create a tunnel/token. Optional failures warn. Unneeded for Dokploy's container connector guide; recommended command skips it. |
| 12 | `bun` | Downloads/syntax-checks the current installer and runs it as the selected account. Writes `~/.bun`, completions and shell startup files where applicable. Optional failures warn. Unneeded for container-only workloads; recommended command skips it. |
| 13 | `unattended` | Installs unattended-upgrades/apt-listchanges; limits origins to security pockets, preserves/adds Docker package exclusions, validates configuration and enables update timers. No automatic reboot or package/kernel removal by default. Docker updates remain deliberate maintenance. |
| 14 | `verify` | Requires selected SSH listeners/configuration, applied UFW, persistent ingress rules, required Docker, configured fail2ban jail and installed Dokploy readiness. Checks key ownership/modes. Local checks cannot prove remote login, external isolation or reboot behaviour. |

## What Dokploy's installer runs

Reviewed [v0.30.6 release installer](https://github.com/Dokploy/dokploy/releases/download/v0.30.6/install.sh), SHA-256 `ea698c22abcfa1e3e7164380e46f918149e2663088a594904b1ae4b7352878eb`:

1. Checks root/Linux/container constraints and ports. Its Docker-install fallback is avoided because this suite installs Docker first.
2. Leaves any existing Swarm, discovers an advertise address using configured values/public-IP services/interface fallback, then initialises Swarm. The wrapper skips unrelated workloads first. Do not use `--reinstall-dokploy` as routine maintenance.
3. Recreates the attachable overlay `dokploy-network` and creates `/etc/dokploy` with broad permissions; the wrapper subsequently removes unnecessary write access.
4. Generates PostgreSQL/auth secrets, then creates PostgreSQL 16 and its persistent data volume.
5. Creates versioned Dokploy with Docker-socket/config mounts, a Docker-credentials volume, and published host TCP 3000. The dashboard has host-administration capability through Docker.
6. Starts Traefik v3.6.7 with configuration/socket mounts and published TCP 80/443 plus UDP 443. Swarm also adds cluster listeners. Public-interface lockdown blocks these unsolicited public connections.
7. Prints completion even after some failed creation commands, which is why the wrapper now requires independent readiness checks.

Partial installations are preserved for repair. A rerun can still skip a partial/unrelated Swarm host: read reported skips, not only the completion heading. APT versions and image tags remain mutable despite the checksum-pinned installer. No general CPU/RAM/disk quotas or backups are configured.

## SSH and tunnel compatibility

The reviewed release's local terminal defaults to root/port 22, with configurable username/port, and connects using its generated key to the Docker gateway. Sources: [terminal](https://github.com/Dokploy/dokploy/blob/v0.30.6/apps/dokploy/server/wss/terminal.ts), [gateway lookup](https://github.com/Dokploy/dokploy/blob/v0.30.6/apps/dokploy/server/utils/docker.ts), [local settings](https://github.com/Dokploy/dokploy/blob/v0.30.6/apps/dokploy/components/dashboard/settings/web-server/local-server-config.tsx).

`--ssh-key-only` uses `PermitRootLogin prohibit-password`, preserves public-key authentication, PAM and forwarding, and does not lock the console password. UFW permits SSH on `docker_gwbridge`/`docker0`; the public guard filters only named public interfaces. Dokploy's key still needs authorising using its normal terminal setup instructions. Existing custom account/Match rules can prevent access; representative policy checks cannot cover every condition. [Ubuntu OpenSSH reference](https://manpages.ubuntu.com/manpages/resolute/man5/sshd_config.5.html).

Follow [Dokploy's tunnel guide](https://docs.dokploy.com/docs/core/guides/cloudflare-tunnels) with its container connector and internal `dokploy-traefik:80` or `dokploy:3000`, not the host public address. No inbound web ports are needed. `--ui=tunnel` only restricts host port 3000; it does not configure Cloudflare or private SSH administration. [Docker documents why ordinary UFW is insufficient](https://docs.docker.com/engine/network/packet-filtering-firewalls/).

## Installation flags

Run the reviewed checkout with matching local modules. SSH is already configured, so its component is skipped. Inspect `ip -br address`; replace placeholders and include every interface carrying public traffic, including IPv6:

```bash
sudo bash lib/setup.sh --base="$PWD/lib" \
  --lockdown-interface=PUBLIC_INTERFACE \
  --ssh-allow=YOUR_ADMIN_PUBLIC_IPV4/32 \
  --ui=tunnel --skip=ssh,bun,cloudflared,tuning --dry-run
```

Remove `--dry-run` to install. This bootstrap leaves only allowlisted public IPv4 SSH. Use the same restrictions in the provider firewall from the start. Keep the existing session/provider console until a new key-authenticated session works.

For no public SSH, use `--ssh-allow=none` from the provider console or tested private management. Detected SSH addressed to a locked interface must have an allowed source. Missing `SSH_CONNECTION` causes a warning, not proof of console access. After testing private management, update just the firewall with:

```bash
sudo bash lib/setup.sh --base="$PWD/lib" \
  --only=firewall,verify \
  --lockdown-interface=PUBLIC_INTERFACE --ssh-allow=none --ui=tunnel
```

Existing SSH authentication remains unchanged. Established connections and required ICMP/DHCP control traffic remain allowed; the IP is not invisible. This is a single-host policy: public Swarm peers, VPN listeners or game ports require separate network design. Previous interface hooks are conservatively retained on reruns; review the guard after interface renames. Independent firewall software can alter the live rules.

## Validation evidence and remaining limits

- Original live framework/all 14 modules matched commit `fe65230ddd7d8173b57295934413b326698a963a`. Edits are local and unpublished.
- Bash syntax, module compatibility, CLI/preservation/console tests and ShellCheck passed in Ubuntu 24.04 WSL. Deliberately failing fixtures exercise rejection paths.
- OpenSSH effective-policy/rollback tests passed. A real isolated root login using an RSA-4096 key executed a command; a password-only client was rejected. The login fixture disables PAM and uses temporary account files, so it does not validate the production account/PAM stack.
- Real IPv4 packets verified public/UI/translated-port blocking, allowed SSH, internal/loopback access, outbound replies and failed-update preservation. IPv6 tests explicitly skipped because the kernel disables IPv6.
- `systemd-analyze verify` accepted generated ingress unit ordering with Docker/SSH dependency fixtures; actual boot/recovery is untested.
- Mocked service/database/HTTP failures reject broken Dokploy readiness. Full/selected previews passed. No Docker containers or production installation were run.
- [Docker currently lists Ubuntu 26.04 support](https://docs.docker.com/engine/install/ubuntu/) and its `resolute` repository was reachable. Selected Ubuntu packages exist; minimal images still need the relevant repositories enabled. This does not establish complete-stack compatibility.

Before calling this production-validated: perform a real Ubuntu 26.04 install/rerun/reboot on a disposable system; verify a new administrator login, Dokploy terminal, application deployment and tunnel; probe IPv4/IPv6 from an unauthorised external host; repeat service/firewall checks after reboot. The script cannot guarantee mirror availability, provider networking, workload capacity or every future upstream behaviour.
