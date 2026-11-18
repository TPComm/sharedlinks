#!/usr/bin/env bash
# Steps and checks for .github/workflows/deploy-e2e.yml, which runs deploy/setup.sh and
# deploy/deploy.sh against the CI runner itself, logged in as root over SSH: the closest stand-in
# for a fresh VPS that CI has. Linux only; needs passwordless sudo.
#
#   deploy/test/e2e.sh <command> [args...]      (the commands are at the bottom)
set -euo pipefail

HOST=root@localhost
DOMAIN=localhost
EMAIL=e2e@example.com
LINK=https://example.invalid/links-e2e   # .invalid never resolves, so the preview fetch stays offline
BIN=/opt/links/links-server
ENV_FILE=/etc/links/links.env
STATE=${RUNNER_TEMP:-/tmp}/links-e2e     # session token and checksums, kept between steps
mkdir -p "$STATE"
chmod 700 "$STATE"

fail() { echo "::error::$*" >&2; exit 1; }
ok() { echo "ok: $*"; }

# Root logs in with a fresh key, as on a new VPS. ssh is set to never prompt, so a broken login
# fails the step instead of hanging it.
ssh_root() {
  if [ ! -x /usr/sbin/sshd ]; then
    sudo apt-get -qq update
    sudo DEBIAN_FRONTEND=noninteractive apt-get -qq install -y openssh-server >/dev/null
  fi
  # sshd keeps the first value it reads, and sshd_config includes this directory before its own.
  sudo install -d -m 755 /etc/ssh/sshd_config.d
  printf 'PermitRootLogin prohibit-password\nPubkeyAuthentication yes\n' \
    | sudo tee /etc/ssh/sshd_config.d/00-links-e2e.conf >/dev/null
  sudo systemctl restart ssh

  install -d -m 700 ~/.ssh
  [ -f ~/.ssh/links_e2e ] || ssh-keygen -q -t ed25519 -N '' -C links-e2e -f ~/.ssh/links_e2e
  sudo install -d -m 700 -o root -g root /root/.ssh
  sudo tee -a /root/.ssh/authorized_keys < ~/.ssh/links_e2e.pub >/dev/null
  sudo chmod 600 /root/.ssh/authorized_keys

  local keys=""
  for _ in $(seq 20); do
    keys=$(ssh-keyscan -T 5 localhost 2>/dev/null) || true
    [ -z "$keys" ] || break
    sleep 1
  done
  [ -n "$keys" ] || fail "sshd isn't answering on localhost:22"
  printf '%s\n' "$keys" >> ~/.ssh/known_hosts
  chmod 600 ~/.ssh/known_hosts
  # setup.sh and deploy.sh run plain `ssh root@localhost`, so this is where they get the key from.
  cat >> ~/.ssh/config <<'EOF'
Host localhost
  IdentityFile ~/.ssh/links_e2e
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking yes
  ConnectTimeout 10
  ServerAliveInterval 15
  ServerAliveCountMax 4
EOF
  chmod 600 ~/.ssh/config

  if ! ssh -o BatchMode=yes "$HOST" true || [ "$(ssh -o BatchMode=yes "$HOST" id -u)" != 0 ]; then
    sudo sshd -T 2>&1 | grep -Ei '^(port|permitrootlogin|pubkeyauthentication|authorizedkeysfile|allow|deny)' || true
    fail "ssh $HOST doesn't log in as root without a prompt"
  fi
  ok "ssh $HOST logs in as root non-interactively"
}

# setup.sh waits for cloud-init with no time limit. Give it two minutes here, and if this runner's
# cloud-init never settles, put a stub first on root's PATH so that wait can't hang the job.
cloud_init() {
  command -v cloud-init >/dev/null || { ok "cloud-init isn't installed"; return; }
  local rc=0
  timeout 120 cloud-init status --wait >/dev/null 2>&1 || rc=$?
  timeout 10 cloud-init status --long || true
  if [ "$rc" != 124 ]; then
    ok "cloud-init status --wait returned (exit $rc)"
    return
  fi
  echo "::warning::cloud-init status --wait didn't return in 120 s on this runner; stubbing it for setup.sh"
  printf '#!/bin/sh\necho "status: done (stub from deploy/test/e2e.sh)"\n' \
    | sudo tee /usr/local/sbin/cloud-init >/dev/null
  sudo chmod 755 /usr/local/sbin/cloud-init
  [ "$(ssh "$HOST" command -v cloud-init)" = /usr/local/sbin/cloud-init ] \
    || fail "root's PATH over SSH doesn't pick up the cloud-init stub"
}

# Both services up, the API running as its own account, and healthz answering directly and
# through Caddy.
check_stack() {
  local unit pid user body
  for unit in links caddy; do
    systemctl is-active --quiet "$unit" || fail "$unit.service isn't active"
  done
  pid=$(systemctl show -p MainPID --value links)
  user=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ') || true
  [ "$user" = links ] || fail "links-server (pid $pid) runs as '$user', not links"
  [ -x "$BIN" ] || fail "$BIN is missing or not executable"
  grep -q "^$DOMAIN {" /etc/caddy/Caddyfile || fail "/etc/caddy/Caddyfile doesn't serve $DOMAIN"

  body=$(curl -fsS --max-time 5 --retry 10 --retry-delay 1 --retry-all-errors http://127.0.0.1:8000/healthz) \
    || fail "http://127.0.0.1:8000/healthz failed"
  [ "$body" = ok ] || fail "http://127.0.0.1:8000/healthz said '$body'"
  # Caddy issues the localhost certificate from its own CA in the background, so the first
  # handshakes after a start may fail. -k: the runner doesn't trust that CA.
  body=$(curl -fsSk --max-time 5 --retry 15 --retry-delay 1 --retry-all-errors "https://$DOMAIN/healthz") \
    || fail "https://$DOMAIN/healthz through Caddy failed"
  [ "$body" = ok ] || fail "https://$DOMAIN/healthz said '$body'"
  ok "links (pid $pid, user links) and caddy are active; healthz answers on 127.0.0.1:8000 and https://$DOMAIN"
}

# env-file KEY=VALUE... -KEY...: each KEY=VALUE is in the settings file exactly once; no -KEY line.
check_env_file() {
  local perms arg key count keys=()
  perms=$(sudo stat -c '%a %U:%G' "$ENV_FILE") || fail "$ENV_FILE is missing"
  [ "$perms" = "640 root:links" ] || fail "$ENV_FILE is $perms, want 640 root:links"
  sudo -u links test -r "$ENV_FILE" || fail "the links user can't read $ENV_FILE"
  if sudo -u nobody test -r "$ENV_FILE"; then fail "other users can read $ENV_FILE"; fi
  for arg in "$@"; do
    case $arg in
      -*)
        key=${arg#-}
        count=$(sudo grep -c "^$key=" "$ENV_FILE") || true
        [ "$count" = 0 ] || fail "$ENV_FILE has $key, which no run of setup.sh passed"
        ;;
      *)
        key=${arg%%=*}
        count=$(sudo grep -c "^$key=" "$ENV_FILE") || true
        [ "$count" = 1 ] || fail "$ENV_FILE has $count $key= lines, want 1"
        sudo grep -qxF "$arg" "$ENV_FILE" || fail "$ENV_FILE doesn't have the expected $key"
        keys+=("$key")
        ;;
    esac
  done
  ok "$ENV_FILE is 640 root:links and has ${keys[*]}"
}

# apns-key: /etc/links/apns.p8 is installed like the settings file, readable by links only.
check_apns_key() {
  local file=/etc/links/apns.p8 perms
  perms=$(sudo stat -c '%a %U:%G' "$file") || fail "$file is missing"
  [ "$perms" = "640 root:links" ] || fail "$file is $perms, want 640 root:links"
  sudo -u links test -r "$file" || fail "the links user can't read $file"
  if sudo -u nobody test -r "$file"; then fail "other users can read $file"; fi
  ok "the APNs key is 640 root:links"
}

# service-env KEY=VALUE...: the running links-server got these, so a re-run restarted it with them.
check_service_env() {
  local pid environ arg
  pid=$(systemctl show -p MainPID --value links)
  environ=$(sudo cat "/proc/$pid/environ" | tr '\0' '\n') || fail "can't read the environment of pid $pid"
  for arg in "$@"; do
    grep -qxF "$arg" <<<"$environ" || fail "links-server (pid $pid) wasn't started with the expected ${arg%%=*}"
  done
  ok "links-server runs with the new settings"
}

# firewall SETUP_LOG: ufw on with SSH and web open. The runner is a full VM where ufw works, so
# setup.sh's "can't use ufw" fallback (meant for container VPSes) is a failure here: accepting it
# would let a broken `ufw allow` line pass.
check_firewall() {
  local log=${1:?usage: e2e.sh firewall setup.log} note status port
  note=$(grep -m1 -E "ufw (isn't usable here|could not be enabled)" "$log") || true
  [ -z "$note" ] || fail "setup.sh gave up on ufw on a full VM: ${note#"${note%%[! ]*}"}"
  status=$(sudo ufw status) || fail "ufw status failed"
  echo "$status"
  grep -q '^Status: active' <<<"$status" || fail "ufw isn't active"
  for port in 22 80 443; do
    grep -Eq "^$port(/tcp)?[[:space:]]+ALLOW" <<<"$status" || fail "ufw doesn't allow port $port"
  done
  ok "ufw is active and allows 22, 80 and 443"
}

# cli COMMAND ARGS...: links-server run as the service account with the service's settings and
# database, the way an admin does it on the VPS. Prints its last line of output.
cli() {
  sudo -u links sh -c 'cd /var/lib/links && set -a && . /etc/links/links.env && set +a &&
    export DATA_DIR=/var/lib/links && exec /opt/links/links-server "$@"' sh "$@" | tail -n 1
}
# mint EMAIL NAME: a session token from the CLI.
mint() { cli mint-session "$@"; }

# api TOKEN METHOD PATH [JSON]: one request through Caddy. Prints the HTTP status; the body lands
# in $STATE/body.json.
api() {
  local args=(-sS -k --max-time 15 -o "$STATE/body.json" -w '%{http_code}' -X "$2" -H "Authorization: Bearer $1")
  [ -z "${4:-}" ] || args+=(-H 'Content-Type: application/json' --data "$4")
  curl "${args[@]}" "https://$DOMAIN$3"
}

body() { cat "$STATE/body.json"; }

check_api() {
  local token link code
  token=$(mint "$EMAIL" E2E) || fail "mint-session as the links user failed"
  [[ $token =~ ^[A-Za-z0-9_-]{40,}$ ]] || fail "mint-session printed '$token', not a token"
  echo "::add-mask::$token"
  (umask 077 && printf '%s\n' "$token" > "$STATE/token")

  code=$(api "$token" GET /api/state) || fail "GET /api/state failed"
  [ "$code" = 200 ] || fail "GET /api/state: HTTP $code $(body)"
  jq -e '.me as $me | ($me | type) == "string" and any(.users[]; .id == $me and .name == "E2E")' \
    "$STATE/body.json" >/dev/null || fail "GET /api/state doesn't know the minted user: $(body)"

  code=$(api "$token" POST /api/links "{\"url\":\"$LINK\",\"note\":\"from the deploy e2e test\"}") \
    || fail "POST /api/links failed"
  [ "$code" = 201 ] || fail "POST /api/links: HTTP $code (want 201) $(body)"
  jq -e --arg url "$LINK" '.duplicate == false and .link.url == $url' "$STATE/body.json" >/dev/null \
    || fail "POST /api/links answered $(body)"
  check_data

  # Invites are the only way in: the CLI makes one with the service's PUBLIC_URL, and its page is served.
  link=$(cli invite friend@example.com) || fail "links-server invite failed"
  [[ "$link" =~ ^https://$DOMAIN/invite/[A-Za-z0-9_-]{43}$ ]] || fail "links-server invite printed '$link'"
  code=$(curl -sS -k --max-time 15 -o "$STATE/body.json" -w '%{http_code}' "$link") || fail "GET $link failed"
  [ "$code" = 200 ] && grep -q "invited to Links" "$STATE/body.json" || fail "the invite page: HTTP $code $(body)"
  ok "a minted session reads /api/state and adds a link through https://$DOMAIN; links-server invite makes a working link"
}

# The apple-app-site-association file through Caddy: Apple's CDN fetches it over HTTPS and
# follows no redirects, so it must be a straight 200 with JSON naming the app.
check_aasa() {
  local code type
  read -r code type < <(curl -sS -k --max-time 15 -o "$STATE/body.json" -w '%{http_code} %{content_type}\n' \
    "https://$DOMAIN/.well-known/apple-app-site-association") || fail "GET apple-app-site-association failed"
  [ "$code" = 200 ] || fail "apple-app-site-association: HTTP $code (want 200, no redirect) $(body)"
  [[ $type == application/json* ]] || fail "apple-app-site-association is $type, want application/json"
  jq -e --arg id "$1" '(.applinks.details[0].appIDs | index($id)) and (.webcredentials.apps | index($id))' \
    "$STATE/body.json" >/dev/null || fail "apple-app-site-association doesn't name $1: $(body)"
  ok "https://$DOMAIN/.well-known/apple-app-site-association is served for $1"
}

# The link check_api added is still in the inbox for the same session: deploys keep the database.
check_data() {
  local code
  [ -s "$STATE/token" ] || fail "no session token saved; run 'e2e.sh api' first"
  code=$(api "$(cat "$STATE/token")" GET /api/state) || fail "GET /api/state failed"
  [ "$code" = 200 ] || fail "GET /api/state with the saved session: HTTP $code $(body)"
  jq -e --arg url "$LINK" '.me as $me | any(.links[]; .url == $url and .added_by == $me)' \
    "$STATE/body.json" >/dev/null || fail "the test link isn't in /api/state: $(body)"
  ok "the saved session still sees the test link"
}

check_backup() {
  local file count
  systemctl is-enabled --quiet links-backup.timer || fail "links-backup.timer isn't enabled"
  systemctl is-active --quiet links-backup.timer || fail "links-backup.timer isn't active"
  touch "$STATE/before-backup"
  sudo systemctl start links-backup.service || fail "links-backup.service failed"
  file=$(sudo find /var/lib/links/backups -maxdepth 1 -name 'links-*.db' -user links \
           -newer "$STATE/before-backup" -print -quit 2>/dev/null) || true
  [ -n "$file" ] || fail "links-backup.service wrote no new /var/lib/links/backups/links-*.db owned by links"
  # Inspect a copy: opening the original as root could leave root-owned -wal/-shm files beside it.
  sudo install -m 600 -o "$(id -u)" "$file" "$STATE/backup.db"
  [ "$(sqlite3 "$STATE/backup.db" 'PRAGMA integrity_check')" = ok ] || fail "$file fails integrity_check"
  count=$(sqlite3 "$STATE/backup.db" 'SELECT count(*) FROM links')
  rm -f "$STATE"/backup.db*
  [ "$count" -ge 1 ] || fail "$file has no links"
  ok "links-backup.timer is enabled and active; links-backup.service wrote $file as links ($count link(s))"
}

# checksum NAME [FILE]: remember FILE's (default: the live binary's) checksum and inode as NAME.
# Builds of the same source can be byte-identical, so only the inode shows whether deploy.sh
# replaced a file or left it alone.
record_checksum() {
  local name=${1:?usage: e2e.sh checksum NAME [FILE]} file=${2:-$BIN}
  [ -f "$file" ] || fail "$file is missing"
  sha256sum "$file" | cut -d' ' -f1 > "$STATE/$name.sha256"
  stat -c %i "$file" > "$STATE/$name.inode"
  ok "$file recorded as $name"
}

# same-file NAME FILE: FILE is still the very file recorded as NAME (not replaced).
# new-file NAME FILE: FILE has been replaced since it was recorded as NAME.
check_inode() {
  local want_same=$1 name=${2:?usage: e2e.sh same-file|new-file NAME FILE} file=${3:?usage: e2e.sh same-file|new-file NAME FILE} was now
  was=$(cat "$STATE/$name.inode") || fail "nothing recorded as $name"
  [ -f "$file" ] || fail "$file is missing"
  now=$(stat -c %i "$file")
  if [ "$want_same" = yes ]; then
    [ "$now" = "$was" ] || fail "$file was replaced, but it should have been left alone"
    ok "$file was left alone"
  else
    [ "$now" != "$was" ] || fail "$file wasn't replaced"
    ok "$file was replaced"
  fi
}

# same-binary NAME [FILE]: FILE (default: the live binary) has the checksum recorded as NAME.
check_same() {
  local name=${1:?usage: e2e.sh same-binary NAME [FILE]} file=${2:-$BIN} want got
  want=$(cat "$STATE/$name.sha256") || fail "no checksum recorded as $name"
  [ -f "$file" ] || fail "$file is missing"
  got=$(sha256sum "$file" | cut -d' ' -f1)
  [ "$got" = "$want" ] || fail "$file isn't the binary recorded as $name"
  ok "$file is the binary recorded as $name"
}

# The first deploy has nothing to fall back to, so it leaves no rollback target.
check_first_deploy() {
  [ ! -e "$BIN.prev" ] || fail "$BIN.prev exists after the first deploy"
  ok "no $BIN.prev after the first deploy"
}

check_tidy() {
  local f
  for f in "$BIN.new" "$BIN.fallback" /tmp/links-server.gz /tmp/links-setup /tmp/links-monitoring; do
    [ ! -e "$f" ] || fail "$f was left behind"
  done
  ok "no temporary files left behind"
}

# Trust Caddy's local CA (it signs the localhost certificate), so deploy.sh's own last check of
# https://localhost can pass and later runs must say "Live at" (see `finished LOG live`).
trust_caddy() {
  local root
  root=$(sudo find /var/lib/caddy -path '*/pki/authorities/local/root.crt' -print -quit 2>/dev/null) || true
  [ -n "$root" ] || fail "Caddy's local root certificate isn't under /var/lib/caddy"
  sudo install -m 644 "$root" /usr/local/share/ca-certificates/links-e2e-caddy-local.crt
  sudo update-ca-certificates >/dev/null
  curl -fsS --max-time 5 --retry 5 --retry-delay 1 --retry-all-errors "https://$DOMAIN/healthz" >/dev/null \
    || fail "https://$DOMAIN/healthz fails without -k even after trusting $root"
  ok "the runner trusts Caddy's local CA, so deploy.sh can reach https://$DOMAIN itself"
}

# finished LOG [live]: setup.sh (if it's a setup log) and then deploy.sh ran to their last line.
# With "live", deploy.sh must also have reached https://localhost itself (after trust-caddy).
check_finished() {
  local log=${1:?usage: e2e.sh finished LOG [live]} want=${2:-} last
  if grep -q '^==> Configuring the VPS' "$log"; then
    grep -qx "    VPS ready for $DOMAIN" "$log" || fail "setup.sh didn't finish configuring the VPS"
  fi
  last=$(grep -E '^==> (Live at|Running on the VPS)' "$log" | tail -n 1) || true
  [ -n "$last" ] || fail "deploy.sh didn't reach its last step; see the log above"
  # Before trust-caddy the runner can't verify the localhost certificate, so the "Couldn't reach"
  # note is expected then.
  if [ "$want" = live ] && [ "$last" != "==> Live at https://$DOMAIN" ]; then
    fail "deploy.sh couldn't reach https://$DOMAIN itself: ${last#==> }"
  fi
  ok "deploy.sh finished: ${last#==> }"
}

# rolled-back EXIT_CODE LOG: deploy.sh started the broken build, saw it fail, and put the old one
# back. (deploy.sh prints the unit's recent journal, which has the broken build's own message.)
check_rolled_back() {
  local rc=${1:?usage: e2e.sh rolled-back EXIT_CODE LOG} log=${2:?usage: e2e.sh rolled-back EXIT_CODE LOG} msg
  [ "$rc" != 0 ] || fail "deploy.sh exited 0 with a build that can't start"
  for msg in "The new build didn't come up." "deliberately broken build from deploy/test/fake-bun.sh" \
             "Rolling back to the previous binary." "Rolled back; the old version is running."; do
    grep -qF "$msg" "$log" || fail "deploy.sh's output lacks \"$msg\""
  done
  ok "deploy.sh exited $rc after systemd ran the broken build, and reported the rollback"
}

# deploy/monitoring.sh against grafana-stub.py on loopback: Fluent Bit installs, runs unprivileged,
# keeps the token root-only and ships the Links journal, host metrics and unit states with the
# right labels and credentials. Run twice, as a token rotation would.
check_monitoring() {
  local port=3999 log="$STATE/grafana.log" run token auth
  : > "$log"
  python3 "$(dirname "$0")/grafana-stub.py" "$port" "$log" &
  local stub=$!
  trap 'kill "$stub" 2>/dev/null || true' RETURN
  for run in 1 2; do
    token=glc_e2e_$run
    GRAFANA_CLOUD_TOKEN=$token LOKI_URL=http://127.0.0.1:$port LOKI_USER=111 \
      PROM_URL=http://127.0.0.1:$port/api/prom/push PROM_USER=222 \
      deploy/monitoring.sh root@localhost 2>&1 | tee "$STATE/monitoring-$run.log" \
      || fail "monitoring.sh exited $? on run $run after: $(tail -n 1 "$STATE/monitoring-$run.log")"
    grep -q '^    monitoring ready for ' "$STATE/monitoring-$run.log" || fail "monitoring.sh run $run didn't finish"
  done
  ok "monitoring.sh installs Fluent Bit and runs again cleanly"

  [ "$(sudo stat -c '%a %U' /etc/fluent-bit/links.env)" = "600 root" ] || fail "/etc/fluent-bit/links.env isn't 600 root"
  sudo grep -qx "GRAFANA_CLOUD_TOKEN=$token" /etc/fluent-bit/links.env || fail "the second run didn't replace the token"
  [ ! -e /tmp/links-monitoring ] || fail "/tmp/links-monitoring (with the token in it) was left behind"
  local uid
  uid=$(ps -o uid= -C fluent-bit | head -n 1 | tr -d ' ')
  [ -n "$uid" ] && [ "$uid" != 0 ] || fail "fluent-bit runs as uid '${uid:-nothing}', not a throwaway user"
  [ "$(systemctl show -p MemoryMax --value fluent-bit)" = $((80 * 1024 * 1024)) ] || fail "fluent-bit has no 80M memory cap"
  if sudo ss -ltnH 'sport = :2020' | grep -v '127.0.0.1:2020' | grep -q .; then fail "Fluent Bit's HTTP port listens beyond loopback"; fi
  ok "Fluent Bit runs as uid $uid under an 80M cap, with the token root-only"

  # Journal logs only ship once a unit logs, so make Links log something.
  sudo systemctl restart links
  auth="Basic $(printf '111:%s' "$token" | base64 -w0)"
  local i
  for i in $(seq 30); do
    python3 - "$log" "$auth" <<'PY' && break
import json, sys
pushes = [json.loads(l) for l in open(sys.argv[1])]
loki = [p for p in pushes if p["auth"] == sys.argv[2] and p["path"] == "/loki/api/v1/push"]
units = {s.get("systemd_unit") for p in loki for s in p["streams"] if s.get("job") == "links" and s.get("host")}
sys.exit(not ({"links.service", "links-loki-heartbeat"} <= units
              and any("Links Loki heartbeat" in p["lines"] for p in loki)))
PY
    [ "$i" -lt 30 ] || fail "journal lines or heartbeat did not reach Loki with Links labels and the new token"
    sleep 2
  done
  ok "the Links journal and heartbeat both reach Loki with Links labels"

  # The unit states come from systemd over D-Bus, which a sandbox can cut off without an error.
  auth="Basic $(printf '222:%s' "$token" | base64 -w0)"
  python3 - "$log" "$auth" <<'PY' || fail "remote write is missing node memory or links.service's state, labelled job=links and instance, with the new token"
import json, sys
series = [s for l in open(sys.argv[1]) for p in [json.loads(l)]
          if p["auth"] == sys.argv[2] and p["path"] == "/api/prom/push" for s in p["series"]]
def has(**want):
    return any(s.get("job") == "links" and s.get("instance") and all(s.get(k) == v for k, v in want.items())
               for s in series)
sys.exit(not (has(__name__="node_memory_MemAvailable_bytes")
              and has(__name__="node_systemd_unit_state", name="links.service", state="active")))
PY
  ok "host metrics and the Links units' systemd state reach Prometheus remote write, labelled job and instance"
}

diagnostics() {
  set +e
  echo "== failed units"
  sudo systemctl --failed --no-pager
  echo "== systemctl status"
  sudo systemctl status --no-pager --full links.service caddy.service links-backup.timer \
    links-backup.service ssh.service
  echo "== journalctl -u links -u caddy"
  sudo journalctl -u links -u caddy --no-pager -n 100
  echo "== journalctl -u links-backup -u ssh"
  sudo journalctl -u links-backup -u ssh --no-pager -n 30
  echo "== journalctl -u fluent-bit"
  sudo journalctl -u fluent-bit --no-pager -n 30
  echo "== listening sockets"
  sudo ss -ltnp
  echo "== ufw"
  sudo ufw status verbose
  echo "== files"
  sudo ls -la /opt/links /etc/links /var/lib/links /var/lib/links/backups
  echo "== $ENV_FILE (API key hidden)"
  sudo sed -E 's/^(WORKOS_API_KEY=).+/\1<hidden>/' "$ENV_FILE"
  echo "== /etc/caddy/Caddyfile"
  cat /etc/caddy/Caddyfile
  echo "== cloud-init"
  timeout 10 cloud-init status --long
  # setup.sh runs apt quietly; dpkg's own output for the packages it installed is here.
  echo "== /var/log/apt/term.log (tail)"
  sudo tail -n 40 /var/log/apt/term.log
  return 0
}

command=${1:-}
[ $# -eq 0 ] || shift
case $command in
  ssh-root) ssh_root ;;
  cloud-init) cloud_init ;;
  stack) check_stack ;;
  env-file) check_env_file "$@" ;;
  apns-key) check_apns_key ;;
  service-env) check_service_env "$@" ;;
  firewall) check_firewall "$@" ;;
  api) check_api ;;
  aasa) check_aasa "$@" ;;
  data) check_data ;;
  backup) check_backup ;;
  checksum) record_checksum "$@" ;;
  same-binary) check_same "$@" ;;
  same-file) check_inode yes "$@" ;;
  new-file) check_inode no "$@" ;;
  first-deploy) check_first_deploy ;;
  tidy) check_tidy ;;
  trust-caddy) trust_caddy ;;
  finished) check_finished "$@" ;;
  rolled-back) check_rolled_back "$@" ;;
  monitoring) check_monitoring ;;
  diagnostics) diagnostics ;;
  *)
    echo "usage: deploy/test/e2e.sh ssh-root | cloud-init | stack | env-file KEY=VALUE... -KEY... | apns-key |" \
         "service-env KEY=VALUE... | firewall LOG | api | data | backup | checksum NAME [FILE] |" \
         "same-binary NAME [FILE] | same-file NAME FILE | new-file NAME FILE | first-deploy | tidy |" \
         "trust-caddy | finished LOG [live] | rolled-back CODE LOG | monitoring | diagnostics" >&2
    exit 2
    ;;
esac
