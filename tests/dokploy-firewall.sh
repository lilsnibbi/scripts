#!/usr/bin/env bash
# Run as root with iptables/ip6tables and Python installed. Network and mount
# namespaces isolate every rule and unit write; Docker is not required.
set -Eeuo pipefail
if [ "${1:-}" != --isolated ]; then
  exec unshare --mount --net --propagation private bash "$0" --isolated
fi
repo="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source <(sed '/^main "\$@"$/d' "$repo/lib/setup.sh")
source "$repo/lib/setup/dokploy.sh"
exec 3>&1 4>/dev/null
test_dir="$(mktemp -d)"
declare -a children=()
pid=''
trap 'for pid in "${children[@]}"; do kill "$pid" 2>/dev/null || true; done; wait || true; rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/sbin" "$test_dir/systemd"
mount --bind "$test_dir/sbin" /usr/local/sbin
mount --bind "$test_dir/systemd" /etc/systemd/system
ip link set lo up
detail() { :; }
ok() { :; }
warn() { :; }
systemctl() {
  case "$1" in
    restart) /usr/local/sbin/dokploy-ui-firewall ;;
    *) return 0 ;;
  esac
}
assert() { "$@" || { printf 'Assertion failed: %s\n' "$*" >&2; exit 1; }; }
OPT_UI_ALLOW=192.168.1.0/24
restrict_dokploy_ui
assert iptables -t mangle -C DOKPLOY-UI -s 192.168.1.0/24 -j RETURN
assert iptables -t mangle -C DOKPLOY-UI -j DROP
ipv6=0
if [ -s /proc/net/if_inet6 ] || [ -d /proc/sys/net/ipv6 ]; then
  ipv6=1
  assert ip6tables -t mangle -C DOKPLOY-UI -j DROP
else
  echo 'SKIP: IPv6 packet filtering (kernel has IPv6 disabled)'
fi
restrict_dokploy_ui
assert test "$(iptables -t mangle -S PREROUTING | grep -c -- '-j DOKPLOY-UI')" = 1
# Previously managed rules are retired, and public mode reverses restrictions.
iptables -N DOCKER-USER
iptables -N DOKPLOY-UI
iptables -A DOCKER-USER -p tcp --dport 3000 -j DOKPLOY-UI
OPT_UI_PUBLIC=1 OPT_UI_ALLOW=''
restrict_dokploy_ui
assert iptables -t mangle -C DOKPLOY-UI -j RETURN
if [ "$ipv6" -eq 1 ]; then assert ip6tables -t mangle -C DOKPLOY-UI -j RETURN; fi
if iptables -C DOCKER-USER -p tcp --dport 3000 -j DOKPLOY-UI 2>/dev/null; then exit 1; fi
OPT_UI_PUBLIC=0
restrict_dokploy_ui
assert iptables -t mangle -C DOKPLOY-UI -j DROP
if [ "$ipv6" -eq 1 ]; then assert ip6tables -t mangle -C DOKPLOY-UI -j DROP; fi
# Invalid updates must not erase the previous DROP.
sed -i 's/^ALLOW=.*/ALLOW=999.1.1.1/' /usr/local/sbin/dokploy-ui-firewall
if /usr/local/sbin/dokploy-ui-firewall 2>/dev/null; then exit 1; fi
assert iptables -t mangle -C DOKPLOY-UI -j DROP
printf 'PASS: available firewall families, reruns, public/private transitions, legacy migration and failed-update preservation\n'

# Exercise actual packet paths, including an original port translated to 3000.
# Only this namespace and a child namespace are used; no host routes change.
unshare --net bash -c 'touch "$1"; exec sleep 60' _ "$test_dir/peer-ready" &
peer=$!
children+=("$peer")
while [ ! -e "$test_dir/peer-ready" ]; do sleep 0.05; done
ip link add test-host type veth peer name test-peer
ip link set test-peer netns "$peer"
ip addr add 198.51.100.1/24 dev test-host
ip link set test-host up
nsenter -t "$peer" -n ip addr add 198.51.100.2/24 dev test-peer
nsenter -t "$peer" -n ip link set test-peer up
nsenter -t "$peer" -n ip link set lo up
python3 -m http.server 3000 --bind 0.0.0.0 --directory "$test_dir" >"$test_dir/http.log" 2>&1 &
children+=("$!")
python3 -m http.server 3001 --bind 0.0.0.0 --directory "$test_dir" >"$test_dir/http.log" 2>&1 &
children+=("$!")
request() { curl --noproxy '*' --connect-timeout 1 --max-time 2 -fsS -o /dev/null "$1" 2>/dev/null; }
export -f request
for attempt in {1..30}; do
  if request http://127.0.0.1:3000 && request http://127.0.0.1:3001; then break; fi
  sleep 0.1
done
request http://127.0.0.1:3000 || { cat "$test_dir/http.log"; exit 1; }
if nsenter -t "$peer" -n bash -c 'request http://198.51.100.1:3000'; then exit 1; fi
assert nsenter -t "$peer" -n bash -c 'request http://198.51.100.1:3001'
iptables -t nat -A PREROUTING -d 198.51.100.1 -p tcp --dport 3002 -j REDIRECT --to-ports 3000
assert nsenter -t "$peer" -n bash -c 'request http://198.51.100.1:3002'
OPT_UI_ALLOW=198.51.100.2/32
restrict_dokploy_ui
assert nsenter -t "$peer" -n bash -c 'request http://198.51.100.1:3000'
OPT_UI_ALLOW='' OPT_UI_PUBLIC=1
restrict_dokploy_ui
assert nsenter -t "$peer" -n bash -c 'request http://198.51.100.1:3000'
printf 'PASS: real packets block untrusted UI access, allow selected/public access, preserve loopback and unrelated/DNAT ports\n'
