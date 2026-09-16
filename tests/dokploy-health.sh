#!/usr/bin/env bash
# All Docker, HTTP, time and service operations below are mocked.
set -Eeuo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source <(sed '/^main "\$@"$/d' "$repo/lib/setup.sh")
source "$repo/lib/setup/dokploy.sh"
exec 3>&1 4>/dev/null
trap - ERR
fixture=healthy
timeout() { shift; "$@"; }
docker() {
  case "$1 $2" in
    'service ls')
      if [ "$fixture" = failed-create ]; then return 0; fi
      if [ "$fixture" = no-replicas ]; then printf 'dokploy 0/1\ndokploy-postgres 1/1\n';
      else printf 'dokploy 1/1\ndokploy-postgres 1/1\n'; fi ;;
    'inspect --format') if [ "$fixture" = no-proxy ]; then echo false; else echo true; fi ;;
    'ps --filter') echo abc123 ;;
    'exec abc123') [ "$fixture" != no-database ] ;;
    *) return 1 ;;
  esac
}
curl() {
  case "${*: -1}" in
    http://127.0.0.1:3000/api/trpc/settings.health) [ "$fixture" != no-ui ] ;;
    http://127.0.0.1:80)
      if [ "$fixture" = proxy-unreachable ]; then return 7;
      elif [ "$fixture" = proxy-error ]; then echo 503;
      else echo 404; fi ;;
    *) return 1 ;;
  esac
}
dokploy_services_ready || { echo 'Healthy fixture was rejected'; exit 1; }
for fixture in failed-create no-replicas no-proxy no-database no-ui proxy-unreachable proxy-error; do
  if dokploy_services_ready; then echo "Incorrectly accepted: $fixture"; exit 1; fi
done
fixture=failed-create
sleep() { SECONDS=$((SECONDS + 180)); }
if (wait_for_dokploy) >/dev/null 2>&1; then echo 'Missing services were not fatal'; exit 1; fi
echo 'PASS: missing/failed Dokploy, database and proxy outcomes reject upstream false success'
