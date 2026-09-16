#!/usr/bin/env bash
# Real authentication in private mount/network namespaces; no host account changes.
set -Eeuo pipefail
if [ "${1:-}" != isolated ]; then exec unshare --mount --net --propagation private bash "$0" isolated; fi
repo="$(cd "$(dirname "$0")/.." && pwd)"
for tool in sshd ssh ssh-keygen openssl unshare mount ip ss; do
  command -v "$tool" >/dev/null || { printf "Missing test dependency: %s\n" "$tool" >&2; exit 1; }
done
source <(sed '/^main "\$@"$/d' "$repo/lib/setup.sh")
source "$repo/lib/setup/ssh.sh"
exec 3>&1 4>/dev/null
scratch=$(mktemp -d /var/tmp/ssh-login-audit.XXXXXX)
daemon=''
trap 'if [ -n "$daemon" ]; then kill "$daemon" 2>/dev/null || true; wait "$daemon" 2>/dev/null || true; fi; rm -rf -- "$scratch"' EXIT
mkdir "$scratch/config" "$scratch/home"
chmod 700 "$scratch/home"
awk -F: -v OFS=: -v home="$scratch/home" '$1 == "root" {$6=home} {print}' /etc/passwd >"$scratch/passwd"
if ! grep -q '^sshd:' "$scratch/passwd"; then printf 'sshd:x:999:65534::/run/sshd:/usr/sbin/nologin\n' >>"$scratch/passwd"; fi
hash=$(openssl passwd -6 'fixture-only-no-production-account')
awk -F: -v OFS=: -v hash="$hash" '$1 == "root" {$2=hash} {print}' /etc/shadow >"$scratch/shadow"
chmod 600 "$scratch/shadow"
mount --bind "$scratch/passwd" /etc/passwd
mount --bind "$scratch/shadow" /etc/shadow
mount --bind "$scratch/config" /etc/ssh
mkdir /etc/ssh/sshd_config.d
ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key
ssh-keygen -q -t rsa -b 4096 -N '' -f "$scratch/client"
cat >/etc/ssh/sshd_config <<CONF
Port 8022
ListenAddress 127.0.0.1
HostKey /etc/ssh/ssh_host_ed25519_key
PidFile $scratch/sshd.pid
UsePAM no
PasswordAuthentication yes
PermitRootLogin yes
AuthorizedKeysFile .ssh/authorized_keys
Subsystem sftp internal-sftp
CONF
systemctl() { case "$1" in is-enabled) return 1 ;; *) return 0 ;; esac; }
OPT_USERNAME=root OPT_SSH_KEY_ONLY=1 OPT_PUBKEY="$(cat "$scratch/client.pub")" OPT_SSH_PORT=8022
SSH_USER_HOME="$scratch/home"
ssh_install_pubkey "$OPT_PUBKEY"
ssh_configure
ip link set lo up
"$(command -v sshd)" -D -e -f /etc/ssh/sshd_config >"$scratch/sshd.log" 2>&1 &
daemon=$!
for attempt in {1..30}; do
  if ss -ltnH 'sport = :8022' | grep -q .; then break; fi
  sleep 0.1
done
opts=(-F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o IdentitiesOnly=yes -p 8022)
result=$(ssh "${opts[@]}" -i "$scratch/client" root@127.0.0.1 'id -u')
[ "$result" = 0 ]
if ssh "${opts[@]}" -o PubkeyAuthentication=no -o PreferredAuthentications=password root@127.0.0.1 true 2>/dev/null; then
  echo 'Password-only SSH unexpectedly accepted' >&2; exit 1
fi
printf 'PASS: actual root SSH command with Dokploy-style RSA-4096 key; password-only client rejected (isolated fixture, PAM disabled)\n'