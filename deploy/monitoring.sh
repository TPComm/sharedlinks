#!/usr/bin/env bash
# Ship the VPS's logs and basic metrics to Grafana Cloud (the free tier covers it) with Fluent Bit.
#
#   read -rs 'GRAFANA_CLOUD_TOKEN?Grafana Cloud token: ' && export GRAFANA_CLOUD_TOKEN   # zsh
#   LOKI_URL=https://logs-prod-000.grafana.net LOKI_USER=123456 \
#   PROM_URL=https://prometheus-prod-00-prod-us-east-0.grafana.net/api/prom/push PROM_USER=654321 \
#     deploy/monitoring.sh root@203.0.113.7
#
# The URLs and users are on the stack's Loki and Prometheus "Details" pages at grafana.com; the
# token needs logs:write and metrics:write. Logs: the journal of links, links-backup and caddy,
# labelled job="links", host=<the PUBLIC_URL hostname> and systemd_unit. Metrics: host
# CPU, memory, disk, network and the state of those units every 60 s, labelled job="links" and
# instance=<the same hostname>. Safe to re-run, e.g. with a new token. The token goes over SSH
# stdin into a root-only file, never onto a command line.
set -euo pipefail

HOST=${1:?usage: deploy/monitoring.sh user@host (with GRAFANA_CLOUD_TOKEN, LOKI_URL, LOKI_USER, PROM_URL, PROM_USER set)}
HERE=$(cd "$(dirname "$0")" && pwd)
for key in GRAFANA_CLOUD_TOKEN LOKI_URL LOKI_USER PROM_URL PROM_USER; do
  [[ -n "${!key:-}" ]] || { echo "Set $key (see the top of $0)" >&2; exit 1; }
done

# split_url NAME URL DEFAULT_PATH: NAME_HOST, _PORT, _TLS and _URI lines, as Fluent Bit takes them.
split_url() {
  local name=$1 url=$2 host port path tls=off
  [[ $url =~ ^(https?)://([^/:]+)(:([0-9]+))?(/.*)?$ ]] || { echo "$name: not an http(s) URL: $url" >&2; return 1; }
  host=${BASH_REMATCH[2]} port=${BASH_REMATCH[4]} path=${BASH_REMATCH[5]}
  if [[ ${BASH_REMATCH[1]} = https ]]; then
    tls=on
  elif [[ $host != 127.0.0.1 && $host != localhost ]]; then
    # Plain http would send the token in the clear; only a loopback stand-in (the e2e test) gets it.
    echo "$name: use https:// (http only for 127.0.0.1): $url" >&2
    return 1
  fi
  if [[ -z $port && $tls = on ]]; then port=443; elif [[ -z $port ]]; then port=80; fi
  if [[ -z $path || $path = / ]]; then path=$3; fi
  printf '%s_HOST=%s\n%s_PORT=%s\n%s_TLS=%s\n%s_URI=%s\n' "$name" "$host" "$name" "$port" "$name" "$tls" "$name" "$path"
}
LOKI=$(split_url LOKI "$LOKI_URL" /loki/api/v1/push)
PROM=$(split_url PROM "$PROM_URL" /api/prom/push)
for user in "$LOKI_USER" "$PROM_USER"; do
  [[ $user =~ ^[0-9]+$ ]] || { echo "LOKI_USER and PROM_USER are the stack's numeric user IDs, not '$user'" >&2; exit 1; }
done

echo "==> Uploading the Fluent Bit config"
ssh "$HOST" 'umask 077 && rm -rf /tmp/links-monitoring && mkdir /tmp/links-monitoring'
for f in fluent-bit.conf fluent-bit-links.conf; do ssh "$HOST" "cat > /tmp/links-monitoring/$f" < "$HERE/$f"; done
printf '%s\nLOKI_USER=%s\n%s\nPROM_USER=%s\nGRAFANA_CLOUD_TOKEN=%s\n' \
  "$LOKI" "$LOKI_USER" "$PROM" "$PROM_USER" "$GRAFANA_CLOUD_TOKEN" \
  | ssh "$HOST" 'umask 077; cat > /tmp/links-monitoring/links.env'

echo "==> Installing Fluent Bit"
ssh "$HOST" 'if [ "$(id -u)" = 0 ]; then bash -s; else sudo bash -s; fi' <<'REMOTE'
set -euo pipefail
# The upload has the token in it: never leave it behind, even on failure.
trap 'rm -rf /tmp/links-monitoring' EXIT
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
apt_get() {
  apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    -qq "$@" </dev/null
}

# Fluent Bit's own repo (distro packages lag far behind), patched by unattended-upgrades like Caddy.
. /etc/os-release
case "$ID" in
  ubuntu | debian) ;;
  *) echo "Unsupported OS: $ID (Debian or Ubuntu only)" >&2; exit 1 ;;
esac
curl -fsSL https://packages.fluentbit.io/fluentbit.key \
  | gpg --dearmor --yes -o /usr/share/keyrings/fluentbit-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/fluentbit-keyring.gpg] https://packages.fluentbit.io/$ID/$VERSION_CODENAME $VERSION_CODENAME main" \
  > /etc/apt/sources.list.d/fluent-bit.list
chmod o+r /usr/share/keyrings/fluentbit-keyring.gpg /etc/apt/sources.list.d/fluent-bit.list
cat > /etc/apt/apt.conf.d/52links-fluent-bit <<'EOF'
Unattended-Upgrade::Origins-Pattern { "site=packages.fluentbit.io"; };
EOF
if ! dpkg -s fluent-bit >/dev/null 2>&1; then
  echo "    installing the fluent-bit package"
  apt_get update && apt_get install -y fluent-bit >/dev/null
fi

# The host label: the name Links is served on, else the box's own.
LABEL=$(sed -n 's|^PUBLIC_URL=https\{0,1\}://\([^/:]*\).*|\1|p' /etc/links/links.env 2>/dev/null || true)
LABEL=${LABEL:-$(hostname -f 2>/dev/null || hostname)}
install -m 644 /tmp/links-monitoring/fluent-bit.conf /etc/fluent-bit/links.conf
rm -f /etc/fluent-bit/links.env.tmp   # a leftover would keep its old mode
(umask 077 && { cat /tmp/links-monitoring/links.env; echo "LINKS_HOST=$LABEL"; } > /etc/fluent-bit/links.env.tmp)
mv /etc/fluent-bit/links.env.tmp /etc/fluent-bit/links.env
# Its own system user (fluent-bit-links.conf says why not DynamicUser). An earlier install ran it
# as a dynamic user of the same name, which only frees the name once it stops.
if ! grep -q '^fluent-bit:' /etc/passwd; then
  systemctl stop fluent-bit 2>/dev/null || true
  useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin fluent-bit
fi
install -d -m 755 /etc/systemd/system/fluent-bit.service.d
install -m 644 /tmp/links-monitoring/fluent-bit-links.conf /etc/systemd/system/fluent-bit.service.d/links.conf
systemctl daemon-reload
systemctl enable fluent-bit >/dev/null 2>&1
systemctl restart fluent-bit

# Metrics are scraped on start, so within seconds the Prometheus push shows whether the URL and
# token work. Logs only flow once a unit logs something, so a test line goes to Loki directly.
counter() {
  curl -fsS --max-time 5 http://127.0.0.1:2020/api/v2/metrics/prometheus 2>/dev/null \
    | awk -v m="$1" -v o="$2" 'index($0, m "{") == 1 && index($0, "name=\"" o) {s += $NF} END {print s + 0}'
}
pushed=0
for _ in $(seq 30); do
  sleep 2
  systemctl is-active --quiet fluent-bit || continue
  if [ "$(counter fluentbit_output_proc_records_total prometheus_remote_write.)" -gt 0 ]; then pushed=1; break; fi
  if [ "$(counter fluentbit_output_errors_total prometheus_remote_write.)" -gt 0 ]; then break; fi
done
if [ "$pushed" != 1 ]; then
  echo "Fluent Bit couldn't push metrics; check PROM_URL, PROM_USER and the token's metrics:write. Its log:" >&2
  journalctl -u fluent-bit -n 30 --no-pager >&2 || true
  exit 1
fi
echo "    metrics are reaching Prometheus"

set -a; . /etc/fluent-bit/links.env; set +a
scheme=http
if [ "$LOKI_TLS" = on ]; then scheme=https; fi
body="{\"streams\":[{\"stream\":{\"job\":\"links\",\"host\":\"$LINKS_HOST\",\"systemd_unit\":\"monitoring.sh\"},\"values\":[[\"$(date +%s%N)\",\"Fluent Bit installed by deploy/monitoring.sh\"]]}]}"
# The credentials go to curl on stdin, not on its command line, which other users can see.
printf 'user = "%s:%s"\n' "$LOKI_USER" "$GRAFANA_CLOUD_TOKEN" \
  | curl -fsS --max-time 15 -K - -H 'Content-Type: application/json' --data "$body" \
      "$scheme://$LOKI_HOST:$LOKI_PORT$LOKI_URI" >/dev/null \
  || { echo "Loki rejected a test line; check LOKI_URL, LOKI_USER and the token's logs:write." >&2; exit 1; }
echo "    logs are reaching Loki"
echo "    monitoring ready for $LINKS_HOST"
REMOTE
echo '==> Done. Grafana Explore: {job="links"} in Loki, node_memory_MemAvailable_bytes{job="links"} in Prometheus'
