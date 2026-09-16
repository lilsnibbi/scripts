#!/usr/bin/env bash
# Real packet tests, isolated from host networking and service configuration.
set -Eeuo pipefail
for cmd in iptables ip6tables iptables-restore ip6tables-restore ip curl python3; do
  command -v "$cmd" >/dev/null || { echo "Missing test dependency: $cmd" >&2; exit 1; }
done
if [ "${1:-}" != --isolated ]; then
  exec unshare --mount --net --propagation private bash "$0" --isolated
fi
repo="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source <(sed '/^main "\$@"$/d' "$repo/lib/setup.sh")
source "$repo/lib/setup/firewall.sh"
exec 3>&1 4>/dev/null
test_dir="$(mktemp -d)"
declare -a children=()
pid=''
trap 'for pid in "${children[@]}"; do kill "$pid" 2>/dev/null || true; done; wait || true; rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/sbin" "$test_dir/units"
mount --bind "$test_dir/sbin" /usr/local/sbin
mount --bind "$test_dir/units" /etc/systemd/system
ip link set lo up
systemctl() {
  case "$1" in
    reload-or-restart) /usr/local/sbin/server-init-ingress ;;
    *) return 0 ;;
  esac
}
detail() { :; }
ok() { :; }
assert() { "$@" || { printf 'Assertion failed: %s\n' "$*" >&2; exit 1; }; }
unshare --net bash -c 'touch "$1"; exec sleep 180' _ "$test_dir/peer-ready" &
peer=$!
children+=("$peer")
while [ ! -e "$test_dir/peer-ready" ]; do sleep 0.05; done
ip link add public-test type veth peer name peer-test
ip link set peer-test netns "$peer"
ip addr add 198.51.100.1/24 dev public-test
ip link set public-test up
nsenter -t "$peer" -n ip addr add 198.51.100.2/24 dev peer-test
nsenter -t "$peer" -n ip addr add 198.51.100.3/24 dev peer-test
nsenter -t "$peer" -n ip link set peer-test up
nsenter -t "$peer" -n ip link set lo up
for port in 3000 8022; do
  python3 -m http.server "$port" --bind 0.0.0.0 --directory "$test_dir" >"$test_dir/http-$port.log" 2>&1 &
  children+=("$!")
done
request() { curl --noproxy '*' --connect-timeout 1 --max-time 2 -fsS -o /dev/null "$@" 2>/dev/null; }
export -f request
for attempt in {1..30}; do
  if request http://127.0.0.1:3000 && request http://127.0.0.1:8022; then break; fi
  sleep 0.1
done
OPT_LOCKDOWN_INTERFACES=public-test OPT_SSH_ALLOW=198.51.100.2/32 SSH_GUARD_PORTS=8022
SSH_CONNECTION='198.51.100.2 40000 198.51.100.1 8022'
lockdown_preflight
SSH_CONNECTION='198.51.100.3 40000 198.51.100.1 8022'
if (lockdown_preflight) >/dev/null 2>&1; then exit 1; fi
unset SSH_CONNECTION
configure_ingress_guard
configure_ingress_guard
assert /usr/local/sbin/server-init-ingress --check
assert test "$(iptables -t mangle -S PREROUTING | grep -c -- '-j SERVER-INIT-IN')" = 1
assert request http://127.0.0.1:3000
assert nsenter -t "$peer" -n bash -c 'request --interface 198.51.100.2 http://198.51.100.1:8022'
if nsenter -t "$peer" -n bash -c 'request --interface 198.51.100.3 http://198.51.100.1:8022'; then exit 1; fi
if nsenter -t "$peer" -n bash -c 'request http://198.51.100.1:3000'; then exit 1; fi
# An ACCEPT in the normal input firewall cannot override pre-DNAT protection.
iptables -A INPUT -p tcp --dport 3000 -j ACCEPT
iptables -t nat -A PREROUTING -p tcp --dport 8080 -j REDIRECT --to-ports 3000
if nsenter -t "$peer" -n bash -c 'request http://198.51.100.1:8080'; then exit 1; fi
# Internal container-like traffic uses a different interface and stays usable.
ip link add inside-test type veth peer name peer-inside
ip link set peer-inside netns "$peer"
ip addr add 192.0.2.1/24 dev inside-test
ip link set inside-test up
nsenter -t "$peer" -n ip addr add 192.0.2.2/24 dev peer-inside
nsenter -t "$peer" -n ip link set peer-inside up
assert nsenter -t "$peer" -n bash -c 'request http://192.0.2.1:3000'
SSH_CONNECTION='192.0.2.2 40000 192.0.2.1 8022'
OPT_SSH_ALLOW=none
lockdown_preflight
unset SSH_CONNECTION
OPT_SSH_ALLOW=198.51.100.2/32
# Return traffic for outbound requests remains usable over the public link.
nsenter -t "$peer" -n python3 -m http.server 8081 --bind 198.51.100.2 --directory "$test_dir" >"$test_dir/outbound.log" 2>&1 &
children+=("$!")
for attempt in {1..30}; do
  if request http://198.51.100.2:8081; then break; fi
  sleep 0.1
done
assert request http://198.51.100.2:8081
sed -i 's/^ALLOW=.*/ALLOW=999.1.1.1/' /usr/local/sbin/server-init-ingress
if /usr/local/sbin/server-init-ingress 2>/dev/null; then exit 1; fi
assert iptables -t mangle -C SERVER-INIT-IN -j DROP
OPT_SSH_ALLOW=none
configure_ingress_guard
if nsenter -t "$peer" -n bash -c 'request --interface 198.51.100.2 http://198.51.100.1:8022'; then exit 1; fi
# Detect removed or additional rules instead of trusting systemd's active flag.
iptables -t mangle -I SERVER-INIT-IN 1 -j RETURN
if /usr/local/sbin/server-init-ingress --check >/dev/null 2>&1; then exit 1; fi
iptables -t mangle -D SERVER-INIT-IN 1
assert /usr/local/sbin/server-init-ingress --check
if [ -d /proc/sys/net/ipv6 ]; then
  ip -6 addr add 2001:db8::1/64 dev public-test nodad
  nsenter -t "$peer" -n ip -6 addr add 2001:db8::2/64 dev peer-test nodad
  python3 -m http.server 8023 --bind :: >"$test_dir/ipv6.log" 2>&1 &
  children+=("$!")
  for attempt in {1..30}; do
    if request 'http://[::1]:8023'; then break; fi
    sleep 0.1
  done
  assert request 'http://[::1]:8023'
  if nsenter -t "$peer" -n bash -c 'request "http://[2001:db8::1]:8023"'; then exit 1; fi
  echo 'PASS: IPv6 public service ingress blocked, loopback retained'
else
  echo 'SKIP: IPv6 unavailable in this kernel'
fi
echo 'PASS: ingress allowlist, public/DNAT blocking, private traffic, outbound replies, failed-update preservation and drift detection'
