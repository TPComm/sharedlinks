#!/usr/bin/env bash
# Test, build for the VPS's CPU, upload, swap in, restart, and health-check. ~30 s.
#
#   deploy/deploy.sh root@203.0.113.7
#
# Ships a clean checkout of main that matches origin/main, and compiles its commit in: /version on
# the server and /opt/links/deploys.log there say what's live. DEPLOY_ANY_CHECKOUT=1 skips those
# checks (CI deploys a PR's merge commit) and marks a build with uncommitted changes "-dirty".
#
# Re-run after `bun upgrade` to ship Bun's own security fixes (the runtime is inside the binary).
# A build that fails its health check is rolled back automatically. To go back one release by hand:
#   ssh root@203.0.113.7 'cd /opt/links && cp links-server.prev links-server.new && mv links-server.new links-server && systemctl restart links'
# (cp straight onto the running binary fails with "Text file busy"; the rename doesn't.)
set -euo pipefail

HOST=${1:?usage: deploy/deploy.sh user@host}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUN=${BUN:-$(command -v bun || echo "$HOME/.bun/bin/bun")}
cd "$ROOT"

COMMIT=$(git rev-parse HEAD)
CHANGES=$(git status --porcelain)
if [[ -n "${DEPLOY_ANY_CHECKOUT:-}" ]]; then
  [[ -z "$CHANGES" ]] || COMMIT="$COMMIT-dirty"
else
  BRANCH=$(git symbolic-ref --quiet --short HEAD || echo "a detached HEAD")
  if [[ "$BRANCH" != main ]]; then
    echo "Deploy from main, not $BRANCH: git switch main" >&2
    exit 1
  fi
  if [[ -n "$CHANGES" ]]; then
    printf 'Commit or stash these first; deploys ship committed code only:\n%s\n' "$CHANGES" >&2
    exit 1
  fi
  if git fetch --quiet origin main 2>/dev/null; then
    if [[ "$COMMIT" != "$(git rev-parse FETCH_HEAD)" ]]; then
      echo "main isn't origin/main: git pull (or push) first." >&2
      exit 1
    fi
  else
    echo "warning: couldn't fetch origin/main, so it's not checked that main is up to date." >&2
  fi
fi
cd server

remote() { ssh "$HOST" 'if [ "$(id -u)" = 0 ]; then bash -s; else sudo bash -s; fi'; }

ARCH=$(ssh "$HOST" uname -m)  # also the connection check: stops here with ssh's own error
case "$ARCH" in
  x86_64) TARGET=bun-linux-x64-baseline ;;  # baseline: also runs on older/virtual CPUs without AVX2
  aarch64 | arm64) TARGET=bun-linux-arm64 ;;
  *) echo "Unsupported CPU: $ARCH" >&2; exit 1 ;;
esac

echo "==> Testing"
"$BUN" test >/dev/null

echo "==> Building $COMMIT for $TARGET"
"$BUN" build src/main.ts --compile --minify --sourcemap=inline --compile-exec-argv=--smol \
  --no-compile-autoload-dotenv --no-compile-autoload-bunfig --define "LINKS_COMMIT=\"$COMMIT\"" \
  --target="$TARGET" --outfile dist/links-server >/dev/null
gzip -9 -c dist/links-server > dist/links-server.gz

echo "==> Uploading ($(du -h dist/links-server.gz | cut -f1))"
ssh "$HOST" 'cat > /tmp/links-server.gz' < dist/links-server.gz

echo "==> Restarting"
{ printf 'COMMIT=%q\n' "$COMMIT"; cat <<'REMOTE'; } | remote
set -euo pipefail
cd /opt/links
gunzip -c /tmp/links-server.gz > links-server.new && rm -f /tmp/links-server.gz
chmod 755 links-server.new
healthy() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -fsS http://127.0.0.1:8000/healthz >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}
# Keep the running binary as the fallback (unless there is none yet), swap in the new one.
[ -f links-server ] && cp -p links-server links-server.fallback
mv links-server.new links-server
systemctl restart links
if healthy; then
  # Only a binary that came up healthy becomes the rollback target for next time.
  [ -f links-server.fallback ] && mv links-server.fallback links-server.prev
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $COMMIT" >> deploys.log
  exit 0
fi
echo "The new build didn't come up. Recent logs:" >&2
journalctl -u links -n 30 --no-pager >&2 || true
if [ -f links-server.fallback ]; then
  echo "Rolling back to the previous binary." >&2
  mv links-server.fallback links-server
  systemctl restart links
  healthy && echo "Rolled back; the old version is running." >&2
fi
exit 1
REMOTE
echo "==> Deployed $COMMIT"

URL=$(echo 'sed -n "s/^PUBLIC_URL=//p" /etc/links/links.env' | remote 2>/dev/null || true)
if [[ -n "$URL" ]] && curl -fsS --max-time 10 "$URL/healthz" >/dev/null 2>&1; then
  echo "==> Live at $URL"
else
  echo "==> Running on the VPS. (Couldn't reach ${URL:-its public URL} yet; check DNS and 'journalctl -u caddy'.)"
fi
