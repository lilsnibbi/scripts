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
sudo bash tests/local-ssh.sh
sudo bash tests/dokploy-firewall.sh
shellcheck -S warning -e SC2034,SC1090 lib/setup.sh lib/setup/*.sh tests/*.sh
git diff --check
```

The lint exclusions cover globals shared by sourced modules and dynamically
sourced test fixtures. Other warning-level diagnostics must pass.

- `safety.sh`: CLI validation, atomic/failed writes, symlinks, Docker/workload
  preservation, rescue passwords, Bash syntax and module compatibility.
- `local-ssh.sh`: real OpenSSH policy checks in a mount namespace; hardware
  gating, LAN scope, key appends, retained ports/socket addresses, reruns,
  dry-run and rollback. Requires root, OpenSSH and mount namespaces.
- `dokploy-firewall.sh`: real rules and packets in private network/mount
  namespaces; allowlists, public/private changes, migration, failed updates,
  loopback and unrelated translated ports. Requires root, iproute2, iptables,
  curl, Python and namespaces. IPv6 tests explicitly skip when the kernel
  disables IPv6.

Service operations are mocked. Tests do not require Docker or change host
configuration. Also run full and selected-component `--dry-run` previews.

## Implementation boundaries

- `write_file` returns 0 for changed content, 1 for unchanged. Real failures
  exit even under `|| true`. It stages beside the destination and atomically
  renames; symlinked destination files are refused.
- `flock` serialises modifying runs. APT waits for dpkg locks without stopping
  another updater. Setup never waits for its own cloud-init parent.
- Explicit SSH changes snapshot configuration and restore it after validation
  or restart failure. Provider firewalls and actual remote login are outside
  these checks. Default runs retain ports and socket bind addresses.
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

Publish API 4 framework/modules together. Mixed versions must fail before
component changes. Before fleet rollout, exercise fresh setup and reruns on
disposable Debian/Ubuntu VMs, Proxmox CTs and representative existing hosts.
Verify IPv4/IPv6 from another machine, reboot persistence, actual systemd
ordering and Dokploy installation. Namespace tests cannot establish those results.

The Dockerfile is an optional systemd container harness, not a full Dokploy/VM
validation environment. Do not run it against a production Docker daemon.

Firewall rationale follows Docker's documentation on
[destination translation](https://docs.docker.com/engine/network/firewall-iptables/)
and [IPv6 publishing](https://docs.docker.com/engine/network/port-publishing/).
