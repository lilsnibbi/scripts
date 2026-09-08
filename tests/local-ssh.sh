#!/usr/bin/env bash
# Run on Linux with OpenSSH installed: sudo bash tests/local-ssh.sh
# All /etc/ssh, systemd unit and /run writes are isolated by mount namespace.
set -Eeuo pipefail
if [ "${1:-}" != --isolated ]; then
  [ "$(id -u)" -eq 0 ] || { echo 'Run as root (mount namespace required).' >&2; exit 1; }
  exec unshare --mount --propagation private bash "$0" --isolated
fi
repo="$(cd "$(dirname "$0")/.." && pwd)"
source <(sed '$d' "$repo/lib/setup.sh")
source "$repo/lib/setup/ssh.sh"
source "$repo/lib/setup/hardening.sh"
exec 3>&1 4>/dev/null
trap - ERR
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/ssh/sshd_config.d" "$test_dir/units" "$test_dir/run"
mount --bind "$test_dir/ssh" /etc/ssh
mount --bind "$test_dir/units" /etc/systemd/system
mount --bind "$test_dir/run" /run
mkdir -p /run/sshd
ssh-keygen -q -t ed25519 -N '' -f "$test_dir/ssh/ssh_host_ed25519_key"
detail() { :; }
ok() { :; }
warn() { printf 'warning: %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
assert() { "$@" || { printf 'Assertion failed: %s\n' "$*" >&2; exit 1; }; }

# Fake only hardware probes; the actual gate and state resolution are exercised.
probe_virt=none probe_rc=1 probe_chassis=9 probe_hostname=laptop
systemd-detect-virt() { printf '%s\n' "$probe_virt"; return "$probe_rc"; }
hostnamectl() { printf '%s\n' "$probe_hostname"; }
cat() {
  if [ "${1:-}" = /sys/class/dmi/id/chassis_type ]; then printf '%s\n' "$probe_chassis";
  else command cat "$@"; fi
}
for probe_chassis in 3 4 5 6 7 8 9 10 13 14; do assert is_local_computer; done
for probe_chassis in 1 2 11 17 23 28 30 31 32; do assert test "$(is_local_computer && echo yes || echo no)" = no; done
probe_chassis=9
for probe_virt in kvm qemu vmware microsoft lxc docker podman systemd-nspawn wsl; do
  probe_rc=0
  assert test "$(is_local_computer && echo yes || echo no)" = no
done
probe_virt=none probe_rc=2
assert test "$(is_local_computer && echo yes || echo no)" = no
probe_rc=1 probe_virt=''
assert test "$(is_local_computer && echo yes || echo no)" = no
probe_virt=none probe_hostname=server
assert test "$(is_local_computer && echo yes || echo no)" = no
probe_hostname=laptop
probe_chassis=''
assert is_local_computer
probe_hostname=''
assert test "$(is_local_computer && echo yes || echo no)" = no
probe_chassis=9 probe_hostname=laptop
have() { return 1; }
assert test "$(is_local_computer && echo yes || echo no)" = no
have() { command -v "$1" >/dev/null 2>&1; }
touch /run/.containerenv
assert test "$(is_local_computer && echo yes || echo no)" = no
rm /run/.containerenv
OPT_UI_LOCAL=0
resolve_local_access
assert test "$LOCAL_ACCESS_ENABLED" = 0
OPT_UI_LOCAL=1
resolve_local_access
assert test "$LOCAL_ACCESS_ENABLED" = 1
OPT_UI_ALLOW=100.64.0.0/10
assert test "$(ui_allow_list)" = "100.64.0.0/10,$UI_LOCAL_CIDRS"
probe_virt=kvm probe_rc=0
resolve_local_access
assert test "$LOCAL_ACCESS_ENABLED" = 0
assert test "$(ui_allow_list)" = 100.64.0.0/10
unset -f cat hostnamectl systemd-detect-virt
printf 'PASS: hardware gate and UI scope\n'

systemctl() {
  printf '%s\n' "$*" >>"$test_dir/systemctl.log"
  case "$*" in
    'is-enabled ssh.socket') return "${test_socket_disabled:-1}" ;;
    'restart ssh'|'restart ssh.socket') return "${test_restart_failure:-0}" ;;
    *) return 0 ;;
  esac
}
reset_config() {
  rm -f /etc/ssh/sshd_config.d/*.conf
  cat > /etc/ssh/sshd_config <<'CONF'
HostKey /etc/ssh/ssh_host_ed25519_key
Port 22
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
AuthenticationMethods publickey
UsePAM no
Subsystem sftp internal-sftp
Match User nobody
    X11Forwarding no
CONF
  LOCAL_ACCESS_ENABLED=1 OPT_DRY_RUN=0 OPT_USERNAME=root OPT_SSH_PORT=2222
  test_restart_failure=0 test_socket_disabled=1
  : >"$test_dir/systemctl.log"
}
policy() { /usr/sbin/sshd -T -C "user=$1,addr=$2,host=$2"; }
expect_policy() { assert grep -qx "$3" < <(policy "$1" "$2"); }
reset_config
ssh_configure
for addr in 10.1.2.3 172.16.0.1 172.31.255.254 192.168.1.2; do
  expect_policy root "$addr" 'passwordauthentication yes'
  expect_policy root "$addr" 'authenticationmethods publickey password'
  expect_policy root "$addr" 'permitrootlogin yes'
  expect_policy root "$addr" 'pubkeyauthentication yes'
  expect_policy nobody "$addr" 'passwordauthentication no'
done
for addr in 8.8.8.8 172.15.255.255 172.32.0.1 100.64.1.1 127.0.0.1 ::1 fd00::1 2001:db8::1; do
  expect_policy root "$addr" 'passwordauthentication no'
  expect_policy root "$addr" 'authenticationmethods publickey'
done
before="$(sha256sum /etc/ssh/sshd_config)"
ssh_configure
assert test "$(sha256sum /etc/ssh/sshd_config)" = "$before"
OPT_USERNAME=nobody
ssh_configure
expect_policy nobody 192.168.1.2 'passwordauthentication yes'
expect_policy root 192.168.1.2 'passwordauthentication no'
LOCAL_ACCESS_ENABLED=0
ssh_configure
expect_policy nobody 192.168.1.2 'passwordauthentication no'
assert test "$(grep -c 'BEGIN setup.sh local SSH' /etc/ssh/sshd_config || true)" = 0
printf 'PASS: real OpenSSH address/user scope, key access, idempotency and removal\n'

reset_config
cp -p /etc/ssh/sshd_config "$test_dir/baseline"
test_restart_failure=1
if (ssh_configure); then die 'Restart failure was ignored'; fi
assert cmp /etc/ssh/sshd_config "$test_dir/baseline"
assert test ! -e /etc/ssh/sshd_config.d/00-server-init.conf
reset_config
test_socket_disabled=0 test_restart_failure=1
cp -p /etc/ssh/sshd_config "$test_dir/baseline"
if (ssh_configure); then die 'Socket restart failure was ignored'; fi
assert cmp /etc/ssh/sshd_config "$test_dir/baseline"
assert test ! -e /etc/systemd/system/ssh.socket.d/10-port.conf
reset_config
printf '\nInvalidDirective yes\n' >>/etc/ssh/sshd_config
cp -p /etc/ssh/sshd_config "$test_dir/baseline"
if (ssh_configure); then die 'Broken baseline was accepted'; fi
assert cmp /etc/ssh/sshd_config "$test_dir/baseline"
assert test ! -s "$test_dir/systemctl.log"
reset_config
printf '\n# BEGIN setup.sh local SSH\n' >>/etc/ssh/sshd_config
cp -p /etc/ssh/sshd_config "$test_dir/baseline"
if (ssh_configure); then die 'Unterminated managed block was accepted'; fi
assert cmp /etc/ssh/sshd_config "$test_dir/baseline"
reset_config
sed -i '/^Match User nobody/i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
printf 'Match User root\n PasswordAuthentication no\n' >/etc/ssh/sshd_config.d/50-conflict.conf
cp -p /etc/ssh/sshd_config "$test_dir/baseline"
if (ssh_configure); then die 'Conflicting included Match rule was accepted'; fi
assert cmp /etc/ssh/sshd_config "$test_dir/baseline"
printf 'PASS: rollback on service/socket failure, invalid config and Match conflicts\n'

reset_config
ssh_configure
cp -p /etc/ssh/sshd_config "$test_dir/baseline"
cp -p /etc/ssh/sshd_config.d/00-server-init.conf "$test_dir/dropin-baseline"
OPT_SSH_PORT=2200 test_restart_failure=1
if (ssh_configure); then die 'Failed rerun was accepted'; fi
assert cmp /etc/ssh/sshd_config "$test_dir/baseline"
assert cmp /etc/ssh/sshd_config.d/00-server-init.conf "$test_dir/dropin-baseline"
reset_config
mv /etc/ssh/sshd_config "$test_dir/linked-config"
ln -s "$test_dir/linked-config" /etc/ssh/sshd_config
if (ssh_configure); then die 'Symlinked SSH config was accepted'; fi
assert test -L /etc/ssh/sshd_config
rm /etc/ssh/sshd_config
printf 'PASS: failed rerun preserves managed files; symlink refused\n'

reset_config
cp -p /etc/ssh/sshd_config "$test_dir/baseline"
OPT_DRY_RUN=1
ssh_configure
assert cmp /etc/ssh/sshd_config "$test_dir/baseline"
assert test ! -e /etc/ssh/sshd_config.d/00-server-init.conf
OPT_USERNAME=nobody LOCAL_ACCESS_ENABLED=1
passwd() { die 'Local mode attempted to change a password'; }
lock_root_password
unset -f passwd
printf 'PASS: dry-run and password preservation\n'

for f in "$repo/lib/setup.sh" "$repo"/lib/setup/*.sh; do bash -n "$f"; done
for f in "$repo"/lib/setup/*.sh; do verify_module "$(basename "$f" .sh)" "$f"; done
sed 's/# setup-api: 3/# setup-api: 2/' "$repo/lib/setup/ssh.sh" >"$test_dir/stale.sh"
if (verify_module ssh "$test_dir/stale.sh"); then die 'Stale module API was accepted'; fi
printf 'PASS: Bash syntax and module API compatibility\n'
