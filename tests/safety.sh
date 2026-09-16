#!/usr/bin/env bash
# No host configuration changes. Run: bash tests/safety.sh
set -Eeuo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source <(sed '/^main "\$@"$/d' "$repo/lib/setup.sh")
exec 3>&1 4>/dev/null
trap - ERR
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT
detail() { :; }
ok() { :; }
warn() { :; }
die() { printf 'expected rejection: %s\n' "$*" >&2; exit 1; }
assert() { "$@" || { printf 'Assertion failed: %s\n' "$*" >&2; exit 1; }; }
reject() { if ("$@") >"$test_dir/rejection" 2>&1; then echo "Unexpected success: $*" >&2; exit 1; fi; }

for value in 0 65536 9999999999999999999999999999999 abc; do
  reject bash "$repo/lib/setup.sh" --dry-run --ssh-port="$value"
done
for value in "bad';touch /tmp/injected;#" '-host' 'host..name' 'host/name'; do
  reject bash "$repo/lib/setup.sh" --dry-run --hostname="$value"
done
for value in 999.1.1.1 256.1.1.1 01.2.3.4 1.2.3.4/33 '1.2.3.4,' ',1.2.3.4'; do
  reject bash "$repo/lib/setup.sh" --dry-run --ui-allow="$value"
done
for value in ',' 'ssh,,base' '*'; do reject bash "$repo/lib/setup.sh" --dry-run --only="$value"; done
for option in --skip= --ui= --only= --exclude= --base= --pubkey=; do reject bash "$repo/lib/setup.sh" --dry-run "$option"; done
for value in ',' 'ssh,,base' '*' 'dockre'; do reject bash "$repo/lib/setup.sh" --dry-run --skip="$value"; done
reject bash "$repo/lib/setup.sh" --dry-run --skip=docker --only=ssh
for args in 'public tunnel' 'public local' 'public 192.168.1.0/24' 'tunnel 192.168.1.0/24'; do
  read -r first second <<<"$args"
  reject bash "$repo/lib/setup.sh" --dry-run "--ui=$first" "--ui=$second"
  reject bash "$repo/lib/setup.sh" --dry-run "--ui=$second" "--ui=$first"
done
reject bash "$repo/lib/setup.sh" --dry-run --ui=public --local
reject bash "$repo/lib/setup.sh" --dry-run --ui=tunnel --ui-allow=192.168.1.0/24
reject bash "$repo/lib/setup.sh" --dry-run --ui=invalid
(
  parse_args --skip=docker,ssh --skip=fail2ban --exclude=bun --ui=tunnel
  validate_args
  plan_components
  assert test "${#SKIPPED[@]}" = 4
  assert test "${#TO_RUN[@]}" = 10
  for name in docker ssh fail2ban bun; do reject is_enabled "$name"; done
  assert is_enabled verify
)
for mode in tunnel local public 192.168.1.0/24; do
  (
    parse_args "--ui=$mode"
    validate_args
    case "$mode" in
      tunnel) assert test "$OPT_UI_TUNNEL" = 1 ;;
      local) assert test "$OPT_UI_LOCAL" = 1 ;;
      public) assert test "$OPT_UI_PUBLIC" = 1 ;;
      *) assert test "$OPT_UI_ALLOW" = "$mode" ;;
    esac
  )
done
bash "$repo/lib/setup.sh" --list >"$test_dir/list"
for entry in "${COMPONENTS[@]}"; do
  assert grep -qE "^[[:space:]]+${entry%%:*}[[:space:]]" "$test_dir/list"
done
assert grep -q -- '--skip=docker,ssh,fail2ban' "$test_dir/list"
bash "$repo/lib/setup.sh" --help >"$test_dir/help"
assert test "$(grep -c '^   --' "$test_dir/help")" = 9
echo 'PASS: compact help, complete component list, combined skips, UI modes and conflict rejection'

(
  source "$repo/lib/setup/base.sh"
  step() { :; }
  apt_ensure_lists() { :; }
  apt_install() { shift; printf '%s\n' "$@" >"$test_dir/base-packages"; }
  parse_args --skip=ssh,firewall
  fn_base
  if grep -qE '^(openssh-server|openssh-client|ufw)$' "$test_dir/base-packages"; then exit 1; fi
  assert grep -qx curl "$test_dir/base-packages"
  OPT_EXCLUDE=''
  fn_base
  for package in openssh-server openssh-client ufw; do assert grep -qx "$package" "$test_dir/base-packages"; done
)
echo 'PASS: skipped SSH/UFW packages stay out of base installation; defaults retain them'
OPT_HOSTNAME=valid-host.example OPT_UI_ALLOW=192.168.1.0/24 OPT_SSH_PORT=00022
validate_args
assert test "$OPT_SSH_PORT" = 22
OPT_ONLY=fail2ban
validate_args
OPT_ONLY=''
assert is_ipv4 255.255.255.255
reject is_ipv4 999.1.1.1
OPT_PUBKEY=$'ssh-ed25519 AAAA\nssh-rsa BBBB'
reject validate_args
OPT_PUBKEY=''
echo 'PASS: input rejection and port normalisation'

OPT_DRY_RUN=0
write_file "$test_dir/config" 0600 original
assert test "$(stat -c %a "$test_dir/config")" = 600
if write_file "$test_dir/config" 0600 original; then die 'Unchanged write reported changed'; fi
chmod 666 "$test_dir/config"
write_file "$test_dir/config" 0600 original
assert test "$(stat -c %a "$test_dir/config")" = 600
ln -s "$test_dir/config" "$test_dir/link"
reject write_file "$test_dir/link" 0600 replacement
assert test "$(cat "$test_dir/config")" = original
# A failed staged write must be fatal even at callers using || true.
(
  mv() { return 1; }
  if (write_file "$test_dir/config" 0600 replacement || true); then exit 1; fi
)
assert test "$(cat "$test_dir/config")" = original
OPT_DRY_RUN=1
write_file "$test_dir/missing" 0644 preview
assert test ! -e "$test_dir/missing"
echo 'PASS: atomic writes, symlink refusal, failed-write preservation and dry-run'

source "$repo/lib/setup/docker.sh"
step() { :; }
run() { printf '%s\n' "$*" >>"$test_dir/commands"; }
have() { [ "$1" = docker ]; }
docker() { return 0; }
OPT_DRY_RUN=0
fn_docker
assert test ! -e "$test_dir/commands"
docker() { return 1; }
reject fn_docker
assert test ! -e "$test_dir/commands"
echo 'PASS: existing and unavailable Docker runtimes are never replaced/restarted'

source "$repo/lib/setup/dokploy.sh"
docker() {
  case "$*" in
    'service inspect --format {{.Spec.Name}} dokploy') return 1 ;;
    'ps -aq') echo existing-container ;;
    *) return 0 ;;
  esac
}
fn_dokploy
assert test "$DOKPLOY_INSTALLED" = 0
assert test ! -e "$test_dir/commands"
docker() { if [ "${1:-}" = service ]; then echo dokploy-other; fi; }
reject dokploy_is_installed
echo 'PASS: unrelated workloads and similarly named Swarm services preserved'

source "$repo/lib/setup/hardening.sh"
OPT_USERNAME=deploy
passwd() { die 'Password mutation attempted'; }
lock_root_password
unset -f passwd
echo 'PASS: rescue password preserved'

# Lock contention never terminates the other package manager, and preview does
# not wait. No real sleeps, package commands or systemd calls are made here.
(
  apt_lock_held() { return 0; }
  sleep() { :; }
  systemctl() { echo unexpected-stop >>"$test_dir/stop"; }
  OPT_DRY_RUN=1
  wait_for_system_ready
  OPT_DRY_RUN=0
  reject wait_for_system_ready
  assert test ! -e "$test_dir/stop"
)
echo 'PASS: package contention times out without killing an updater; preview never waits'

# Generated security-update policy uses the base codename and retains blacklist
# entries. Capture the module output rather than touching /etc/apt.
(
  source "$repo/lib/setup/unattended.sh"
  OPT_DRY_RUN=1 OS_BASE_ID=ubuntu OS_CODENAME=noble
  apt_ensure_lists() { :; }
  apt_install() { :; }
  write_file() { if [ "$1" = /etc/apt/apt.conf.d/52-server-init ]; then printf '%s\n' "$3" >"$test_dir/unattended"; fi; }
  fn_unattended
  assert grep -q 'archive=noble-security' "$test_dir/unattended"
  if grep -q '^#clear Unattended-Upgrade::Package-Blacklist' "$test_dir/unattended"; then exit 1; fi
  assert grep -q 'Automatic-Reboot "false"' "$test_dir/unattended"
  assert grep -q 'Remove-Unused-Dependencies "false"' "$test_dir/unattended"
)
echo 'PASS: generated unattended policy preserves blacklist and disables reboot/removal'

(
  source "$repo/lib/setup/tuning.sh"
  in_container() { return 0; }
  write_file() { printf '%s\n' "$3" >>"$test_dir/sysctls"; }
  run() { [ "$1" != modprobe ] || die 'CT attempted to load a host module'; }
  harden_sysctl
  tune_sysctl
  if grep -qE '^(fs|kernel|vm)\.' "$test_dir/sysctls"; then exit 1; fi
  assert grep -q '^net\.' "$test_dir/sysctls"
)
echo 'PASS: CT configuration excludes host-owned sysctls and module loading'

unset -f have
have() { command -v "$1" >/dev/null 2>&1; }
for file in "$repo/lib/setup.sh" "$repo"/lib/setup/*.sh "$repo"/tests/*.sh; do bash -n "$file"; done
for file in "$repo"/lib/setup/*.sh; do verify_module "$(basename "$file" .sh)" "$file"; done
sed 's/# setup-api: 5/# setup-api: 4/' "$repo/lib/setup/docker.sh" >"$test_dir/stale"
reject verify_module docker "$test_dir/stale"
head -n -2 "$repo/lib/setup/docker.sh" >"$test_dir/truncated"
reject verify_module docker "$test_dir/truncated"
echo 'PASS: syntax, module compatibility and truncated-module rejection'
