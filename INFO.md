# Maintenance and validation

User commands and defaults: [README.md](README.md).

## CLI compatibility

The primary CLI uses `--skip` for selection and `--ui=tunnel|local|public|CIDR`
for access. Old fleet commands still work:

- `--exclude` aliases `--skip`; `--only` remains available for targeted runs.
- `--local`, `--ui-public` and `--ui-allow` retain their original meanings.
- Existing hostname/timezone, auto-reboot, snapd removal, firewall reset,
  Dokploy reinstall, module base, verbose and colour options remain supported.

Conflicting UI modes and mixed skip/only selection are rejected. `--ui=local`
uses the same desktop/laptop hardware gate and scoped SSH policy as `--local`.
Repeated skip lists combine so a later argument cannot silently re-enable a step.

## Checks

Run on Linux:

```bash
bash tests/safety.sh
bash tests/ui.sh
sudo bash tests/local-ssh.sh
sudo bash tests/dokploy-firewall.sh
sudo bash tests/ingress.sh
sudo bash tests/ssh-login.sh
bash tests/dokploy-health.sh
shellcheck -S warning -e SC2034,SC1090 lib/setup.sh lib/setup/*.sh tests/*.sh
git diff --check
```

The lint exclusions cover globals shared by sourced modules and dynamically
sourced test fixtures. Other warning-level diagnostics must pass.

- `safety.sh`: CLI validation, atomic/failed writes, symlinks, Docker/workload
  preservation, rescue passwords, Bash syntax and module compatibility.
- `ui.sh`: instance classification, 32/48/80/96-column layouts, long identifiers,
  preview labels, warning summaries and subshell recovery messages.
- `local-ssh.sh`: real OpenSSH policy checks in a mount namespace; hardware
  gating, LAN scope, key appends, retained ports/socket addresses, reruns,
  dry-run and rollback. Requires root, OpenSSH and mount namespaces.
- `dokploy-firewall.sh`: real rules and packets in private network/mount
  namespaces; allowlists, public/private changes, migration, failed updates,
  loopback and unrelated translated ports. Requires root, iproute2, iptables,
  curl, Python and namespaces. IPv6 tests explicitly skip when the kernel
  disables IPv6.
- `ingress.sh`: public interface filtering, SSH allowlists, translated ports,
  internal traffic, outbound replies, failed updates and rule drift; namespaces
  and dependencies as above.
- `ssh-login.sh`: actual root command execution with an RSA-4096 key and rejection
  of a password-only client. Uses isolated account files with PAM disabled;
  production PAM/account behaviour still requires a target login test.
- `dokploy-health.sh`: command mocks reject missing services, failed replicas,
  unavailable PostgreSQL, failed application health and missing/broken Traefik.

Systemd service operations are mocked; `ssh-login.sh` starts its own isolated
sshd. Tests do not require Docker or change host configuration. Also run full
and selected-component `--dry-run` previews.

## Implementation boundaries

- `write_file` returns 0 for changed content, 1 for unchanged. Real failures
  exit even under `|| true`. It stages beside the destination and atomically
  renames; symlinked destination files are refused.
- `flock` serialises modifying runs. APT waits for dpkg locks without stopping
  another updater. Setup never waits for its own cloud-init parent.
- Explicit SSH changes snapshot configuration and restore it after validation
  or restart failure. Provider firewalls and actual remote login are outside
  these checks. Default runs retain ports and socket bind addresses.
- `--ssh-key-only` disables password/keyboard-interactive SSH but allows root
  public keys for Dokploy. It preserves PAM and the console password. Existing
  conflicting policies fail validation; representative source checks cannot
  exhaust every possible Match condition.
- `--lockdown-interface` installs a separate mangle/PREROUTING guard before
  component installations. It filters both host and forwarded traffic on the
  named interfaces. Address-family transactions are separate; existing connections
  and network control traffic remain allowed. Private interfaces are untouched.
  The guard is required before Docker/SSH at boot. Reloading guards avoids
  restarting dependent services. Renaming/removing an interface requires reviewing
  the configuration; old interface hooks are retained conservatively on reruns.
- Fresh Dokploy installs use release v0.30.6 and a SHA-256 checked release
  installer. Packages and image tags remain mutable. A successful installer exit
  must be followed by database/application/proxy readiness. The wrapper removes
  group/other write permission from `/etc/dokploy`; it does not recursively alter
  application-owned files. Partial installations require operator repair.
- Dokploy protection runs before installation and before Docker at boot via
  a required systemd unit. Its mangle/PREROUTING rule matches host-local TCP
  3000 before destination translation. Loopback is exempt. Address-family
  chains update transactionally, but IPv4 and IPv6 are separate transactions.
- Existing Docker settings are retained. The package upgrade step can still
  upgrade/restart services; this is not a zero-downtime maintenance tool.
  Fresh Docker defaults are written before package installation starts it.
  Docker operations and installers use the local socket, not an inherited remote context.
- Workloads and unfamiliar listeners prevent automatic firewall baseline
  changes. This conservative detection is not a complete inventory of every
  game panel, hypervisor or externally managed firewall.
- Root password locking is never inferred from key-file presence. A file cannot
  establish that SSH, PAM, account restrictions and sudo permit another login.

## Release validation

Publish API 6 framework/modules together. Mixed versions must fail before
component changes. Before fleet rollout, exercise fresh setup and reruns on
disposable Debian/Ubuntu VMs, Proxmox CTs and representative existing hosts.
Verify IPv4/IPv6 from another machine, reboot persistence, actual systemd
ordering and Dokploy installation. Namespace tests cannot establish those results.

The Dockerfile is an optional systemd container harness, not a full Dokploy/VM
validation environment. Do not run it against a production Docker daemon.

Firewall rationale follows Docker's documentation on
[destination translation](https://docs.docker.com/engine/network/firewall-iptables/)
and [IPv6 publishing](https://docs.docker.com/engine/network/port-publishing/).
