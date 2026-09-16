#!/usr/bin/env bash
# Deterministic console fixtures. No provisioning or host configuration changes.
set -Eeuo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source <(sed '/^main "\$@"$/d' "$repo/lib/setup.sh")
exec 3>&1 4>/dev/null
trap - ERR
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT
assert() { "$@" || { printf 'Assertion failed: %s\n' "$*" >&2; exit 1; }; }
probe=lxc probe_rc=0
systemd-detect-virt() {
  if [ "${1:-}" = --container ]; then
    case "$probe" in lxc|docker|podman|systemd-nspawn|wsl) return 0 ;; *) return 1 ;; esac
  fi
  printf '%s\n' "$probe"
  return "$probe_rc"
}
cat() {
  case "${1:-}" in
    /sys/class/dmi/id/sys_vendor) echo ExampleCloud ;;
    /sys/class/dmi/id/product_name) echo 'Virtual Server' ;;
    *) command cat "$@" ;;
  esac
}
for probe in lxc docker kvm wsl none unknown; do
  case "$probe" in none) probe_rc=1 ;; unknown) probe_rc=2 ;; *) probe_rc=0 ;; esac
  detect_instance
  case "$probe" in
    lxc) assert test "$INSTANCE_TYPE" = 'CT / system container'; assert test "$INSTANCE_PLATFORM" = lxc ;;
    docker) assert test "$INSTANCE_TYPE" = Container ;;
    kvm) assert test "$INSTANCE_TYPE" = 'VM / virtual machine'; assert test "$INSTANCE_PLATFORM" = 'ExampleCloud Virtual Server / kvm' ;;
    wsl) assert test "$INSTANCE_TYPE" = 'WSL / Linux subsystem' ;;
    none) assert test "$INSTANCE_TYPE" = 'Bare metal'; assert test "$INSTANCE_PLATFORM" = 'ExampleCloud Virtual Server' ;;
    unknown) assert test "$INSTANCE_TYPE" = Unknown ;;
  esac
done
echo 'PASS: CT, VM, container, WSL, bare-metal and unknown classification'

hostname() { echo ct-gateway-with-a-deliberately-long-hostname-for-narrow-consoles; }
uname() { echo 6.8.12-4-pve; }
OS_PRETTY='Debian GNU/Linux 12 (bookworm)' ARCH=amd64
TO_RUN=(base swap verify) SKIPPED=(docker ssh fail2ban)
STEP_TOTAL=3 OPT_DRY_RUN=1 TTY=0 OPT_VERBOSE=0
probe=lxc probe_rc=0
for width in 32 48 80 96; do
  TERM_COLS="$width" STEP_INDEX=0 STEP_TITLE='' WARNINGS=() AUTO_SKIPPED=() STEP_TIMES=()
  exec 3>"$test_dir/$width.txt"
  banner
  section COMPONENTS
  step 'Base packages'
  detail 'INTERNAL DETAIL MUST STAY IN JOURNAL'
  ok 'UNPROVEN INSTALL SUCCESS MUST STAY IN JOURNAL'
  step Swap
  step_skip 'Container: swap is managed by the host'
  step Verify
  warn 'Check provider firewall access before disconnecting.'
  step_finish
  summary
  exec 3>&1
  while IFS= read -r line; do
    assert test "${#line}" -le "$width"
  done <"$test_dir/$width.txt"
  if grep -qE 'INTERNAL DETAIL|UNPROVEN INSTALL|\x1b' "$test_dir/$width.txt"; then exit 1; fi
  assert test "$(grep -c 'disconnecting' "$test_dir/$width.txt")" = 1
  assert grep -q SKIP "$test_dir/$width.txt"
  assert grep -q PLAN "$test_dir/$width.txt"
  assert grep -q NOTE "$test_dir/$width.txt"
  assert grep -q 'Debian GNU/Linux' "$test_dir/$width.txt"
done
echo 'PASS: 32/48/80/96-column layouts, wrapped identifiers, preview labels and single warning summary'

# Transaction warnings must still be visible when emitted by a subshell.
exec 3>"$test_dir/subshell.txt"
(warn 'Rollback information survives')
exec 3>&1
assert grep -q 'Rollback information survives' "$test_dir/subshell.txt"
echo 'PASS: subshell recovery messages remain visible'
