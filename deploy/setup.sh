#!/usr/bin/env bash
# One-time setup of a fresh Debian 12/13 or Ubuntu 22.04/24.04 VPS for Links, then a first deploy.
#
#   read -rs 'WORKOS_API_KEY?WorkOS API key (Enter to skip): ' && export WORKOS_API_KEY   # zsh
#   WORKOS_CLIENT_ID=client_... ALLOWED_EMAILS=you@x.com,friend@y.com \
#     deploy/setup.sh root@203.0.113.7 links.example.com
#
# Push notifications (see the README): add APNS_TEAM_ID, APNS_TOPIC, APNS_KEY_ID and the .p8 key, as
# APNS_KEY_FILE (a local path) or APNS_KEY_P8 (its contents, e.g. from a secret). The key goes over
# SSH stdin to /etc/links/apns.p8.
#
# The hostname's DNS A (and AAAA, if any) record must already point at the VPS, because Caddy
# fetches a Let's Encrypt certificate for it. Safe to re-run: it only changes what's missing, and
# only the settings you pass. Read the API key as above rather than typing it on the command line,
# which shells save to their history; from there it goes over SSH stdin, never on a command line.
set -euo pipefail

HOST=${1:?usage: deploy/setup.sh user@host hostname}
DOMAIN=${2:?usage: deploy/setup.sh user@host hostname}
HERE=$(cd "$(dirname "$0")" && pwd)
[[ $DOMAIN =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || { echo "Not a hostname: $DOMAIN" >&2; exit 1; }

# Run the script on stdin on the VPS as root (directly, or through sudo for a non-root login).
# ssh joins its arguments into one remote shell command, so quote them into it ourselves. The
# script also gets, last, the VPS port this SSH session came in on (sudo drops SSH_CONNECTION).
remote() {
  local args
  args=$(printf ' %q' "$@")
  ssh "$HOST" "p=\${SSH_CONNECTION##* }; if [ \"\$(id -u)\" = 0 ]; then bash -s --$args \"\$p\"; else sudo bash -s --$args \"\$p\"; fi"
}
upload() { ssh "$HOST" "cat > '$2'" < "$1"; }

echo "==> Uploading service files"
ssh "$HOST" 'umask 077 && mkdir -p /tmp/links-setup'
for f in links.service links-backup.service links-backup.timer; do upload "$HERE/$f" "/tmp/links-setup/$f"; done
sed "s/links.example.com/$DOMAIN/" "$HERE/Caddyfile" | ssh "$HOST" 'cat > /tmp/links-setup/Caddyfile'

# The APNs key: the service can't read /home or /root (ProtectHome), so it's installed in /etc/links.
if [[ -n "${APNS_KEY_P8:-}" ]]; then
  printf '%s\n' "$APNS_KEY_P8" | ssh "$HOST" "umask 077; cat > /tmp/links-setup/apns.p8"
elif [[ -n "${APNS_KEY_FILE:-}" ]]; then
  [[ -r "$APNS_KEY_FILE" ]] || { echo "APNS_KEY_FILE: can't read $APNS_KEY_FILE" >&2; exit 1; }
  ssh "$HOST" "umask 077; cat > /tmp/links-setup/apns.p8" < "$APNS_KEY_FILE"
fi

# Only the settings you pass are sent; the VPS merges them into /etc/links/links.env, so re-running
# with just WORKOS_API_KEY=... keeps your ALLOWED_EMAILS.
{
  echo "PUBLIC_URL=https://$DOMAIN"
  for key in WORKOS_CLIENT_ID WORKOS_API_KEY ALLOWED_EMAILS SUPPORT_EMAIL \
             APNS_TEAM_ID APNS_TOPIC APNS_KEY_ID; do
    # An if, not &&: a trailing failed test would fail the pipeline and stop the script.
    if [[ -n "${!key:-}" ]]; then echo "$key=${!key}"; fi
  done
  if [[ -n "${APNS_KEY_P8:-}${APNS_KEY_FILE:-}" ]]; then echo "APNS_KEY_FILE=/etc/links/apns.p8"; fi
} | ssh "$HOST" 'umask 077; cat > /tmp/links-setup/links.env.new'

echo "==> Configuring the VPS"
remote "$DOMAIN" <<'REMOTE'
set -euo pipefail
DOMAIN=$1
CONN_PORT=${2:-} # the port this SSH session uses (see remote())
# The uploads include the env file with secrets: never leave them behind, even on failure.
trap 'rm -rf /tmp/links-setup' EXIT
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l

# Small boxes: give apt and Bun's GC some room.
# (Best effort: container-based VPSes don't allow swapon, and that's fine.)
if [ "$(free -m | awk '/^Mem:/{print $2}')" -lt 1500 ] && [ -z "$(swapon --show --noheadings 2>/dev/null)" ] \
   && [ ! -e /swapfile ]; then
  echo "    adding a 1 GB swapfile"
  if { fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none; } \
     && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile 2>/dev/null; then
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  else
    echo "    this host doesn't allow swap; skipping"
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
  fi
fi

# A freshly booted cloud image is often still running cloud-init / apt in the background.
command -v cloud-init >/dev/null && cloud-init status --wait >/dev/null 2>&1 || true

# stdin is this script, so apt and dpkg must never read it (e.g. a config-file prompt).
apt_get() {
  apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    -qq "$@" </dev/null
}
# DPkg::Lock::Timeout doesn't cover `apt-get update`'s lock, and a fresh VPS is often refreshing
# its package lists in the background, so retry for a couple of minutes.
apt_update() {
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    apt_get update && return 0
    echo "    apt-get update failed (often another apt run in progress); retrying in 10 s"
    sleep 10
  done
  apt_get update
}

apt_update
apt_get install -y ca-certificates curl gnupg unattended-upgrades ufw >/dev/null

# Caddy from its official repo (distro packages lag far behind). The signing key is refreshed on
# every run: Caddy has rotated it before, which breaks `apt-get update` until it's re-downloaded.
curl -1sSLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
  | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sSLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
  > /etc/apt/sources.list.d/caddy-stable.list
chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
if ! command -v caddy >/dev/null; then
  echo "    installing Caddy"
  apt_update && apt_get install -y caddy >/dev/null
fi

# Automatic security updates for the OS and for Caddy. (The Links binary embeds its runtime:
# update it by re-running deploy/deploy.sh after `bun upgrade`.)
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
cat > /etc/apt/apt.conf.d/52links-caddy <<'EOF'
Unattended-Upgrade::Origins-Pattern { "site=dl.cloudsmith.io"; };
EOF

# Service account and directories.
id links >/dev/null 2>&1 || useradd --system --home-dir /var/lib/links --shell /usr/sbin/nologin links
install -d -o links -g links -m 750 /var/lib/links
install -d -m 755 /opt/links
install -d -m 750 -g links /etc/links
touch /etc/links/links.env
while IFS= read -r line; do
  # Split at the first '=' only; the value keeps any '=' (read's IFS splitting would drop a trailing one).
  key=${line%%=*} value=${line#*=}
  [ -n "$key" ] && [ "$key" != "$line" ] || continue
  grep -v "^$key=" /etc/links/links.env > /etc/links/links.env.tmp || true
  printf '%s=%s\n' "$key" "$value" >> /etc/links/links.env.tmp
  mv /etc/links/links.env.tmp /etc/links/links.env
done < /tmp/links-setup/links.env.new
chown root:links /etc/links/links.env && chmod 640 /etc/links/links.env
if [ -f /tmp/links-setup/apns.p8 ]; then
  install -o root -g links -m 640 /tmp/links-setup/apns.p8 /etc/links/apns.p8
  echo "    installed the APNs key"
fi
grep -q '^WORKOS_CLIENT_ID=.' /etc/links/links.env \
  || echo "    NOTE: set WORKOS_CLIENT_ID in /etc/links/links.env (or re-run setup.sh with it), then: systemctl restart links"

install -m 644 /tmp/links-setup/links.service /tmp/links-setup/links-backup.service \
  /tmp/links-setup/links-backup.timer /etc/systemd/system/
install -m 644 /tmp/links-setup/Caddyfile /etc/caddy/Caddyfile

# Firewall: SSH and web only. (Skipped quietly on hosts whose kernel lacks the needed modules.)
# Allow every port SSH listens on (not just 22) before turning the firewall on: sshd_config's,
# ssh.socket's (socket activation, Ubuntu 22.10+: a drop-in there can add ports sshd -T doesn't
# show), and the one this very session came in on, however it was configured.
SSH_PORTS=$( {
  sshd -T 2>/dev/null | awk '$1 == "port" {print $2}'
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    systemctl show -p Listen --value ssh.socket 2>/dev/null | sed -nE 's/.*:([0-9]+) \(Stream\).*/\1/p'
  fi
  if [[ $CONN_PORT =~ ^[0-9]+$ ]]; then echo "$CONN_PORT"; fi
} | sort -u || true)
[ -n "$SSH_PORTS" ] || SSH_PORTS=22
ok=1
for port in $SSH_PORTS; do ufw allow "$port/tcp" >/dev/null || ok=0; done
ufw allow 80/tcp >/dev/null && ufw allow 443 >/dev/null || ok=0
if [ "$ok" = 1 ]; then
  ufw --force enable >/dev/null || echo "    ufw could not be enabled; configure your provider's firewall instead"
else
  echo "    ufw isn't usable here; configure your provider's firewall instead"
fi

systemctl daemon-reload
systemctl enable links.service links-backup.timer >/dev/null 2>&1
systemctl start links-backup.timer
systemctl reload caddy || systemctl restart caddy
echo "    VPS ready for $DOMAIN"
REMOTE

echo "==> First deploy"
"$HERE/deploy.sh" "$HOST"
