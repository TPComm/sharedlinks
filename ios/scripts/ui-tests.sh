#!/usr/bin/env bash
# End-to-end UI tests: the real Links app in a Simulator, against a real server started from
# server/ with an empty database. Signs in with minted session tokens, so no WorkOS.
#
#   ios/scripts/ui-tests.sh [more xcodebuild args, e.g. -only-testing:LinksUITests/LinksUITests/testSearch]
#
# Env (all optional):
#   LINKS_UI_TEST_DESTINATION   xcodebuild -destination; default: a dedicated "Links UI Tests"
#                               Simulator, created on first use (never the one you're using)
#   LINKS_UI_TEST_DEVICE_TYPE   device type for that Simulator (default: iPhone 17)
#   LINKS_UI_TEST_DERIVED_DATA  derived data folder (default: ios/build)
#   LINKS_UI_TEST_ACTION        xcodebuild action (default: test; CI builds first, then runs
#                               test-without-building)
#   LINKS_UI_TEST_LOGS          keep the server and xcodebuild logs here (default: a temp folder,
#                               deleted at exit)
set -euo pipefail

ios="$(cd "$(dirname "$0")/.." && pwd)"
server_dir="$(dirname "$ios")/server"
export PATH="$HOME/.bun/bin:$PATH"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/links-ui-tests.XXXXXX")"
logs="${LINKS_UI_TEST_LOGS:-$tmp}"
mkdir -p "$logs"
server_pid=""
shutdown_udid=""

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  # Leave the dedicated Simulator as we found it.
  if [[ -n "$shutdown_udid" ]]; then xcrun simctl shutdown "$shutdown_udid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

command -v bun >/dev/null || { echo "error: bun isn't installed (https://bun.sh)" >&2; exit 1; }

# -- server: a free port (8000 is usually the dev server), a throwaway database.
port="$(bun -e 'const s = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: () => new Response() }); console.log(s.port); s.stop(true)')"
url="http://127.0.0.1:$port"
# ALLOWED_EMAILS pinned empty and server/.env skipped: a list from your shell or .env would refuse
# the test accounts, and every test would fail at sign-in.
server_env=(DATA_DIR="$tmp/data" HOST=127.0.0.1 PORT="$port" WORKOS_CLIENT_ID=client_E2E ALLOWED_EMAILS=)

(cd "$server_dir" && exec env "${server_env[@]}" bun --no-env-file src/main.ts) >"$logs/server.log" 2>&1 &
server_pid=$!

for _ in $(seq 1 100); do
  curl -fsS "$url/healthz" >/dev/null 2>&1 && break
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "error: the server exited:" >&2
    cat "$logs/server.log" >&2
    exit 1
  fi
  sleep 0.1
done
curl -fsS "$url/healthz" >/dev/null || { echo "error: the server didn't answer on $url" >&2; exit 1; }
echo "Links server for UI tests: $url"

mint() { (cd "$server_dir" && env "${server_env[@]}" bun --no-env-file src/main.ts mint-session "$@"); }
me_token="$(mint me@e2e.test Me)"
friend_token="$(mint friend@e2e.test Friend)"
# A second session of "me" for the sign-out test, which ends the session it signs out of.
spare_token="$(mint me@e2e.test)"
# Someone else, for the test that deletes their account.
deletable_token="$(mint deletable@e2e.test Deletable)"

# -- destination: a Simulator of our own, so tests never take over the one you're using.
destination="${LINKS_UI_TEST_DESTINATION:-}"
if [[ -z "$destination" ]]; then
  name="Links UI Tests"
  udid="$(xcrun simctl list devices available | sed -n "s/^ *$name (\([0-9A-F-]*\)).*/\1/p" | head -1)"
  if [[ -z "$udid" ]]; then
    # Without a runtime argument simctl picks the newest one that supports the device type.
    udid="$(xcrun simctl create "$name" "${LINKS_UI_TEST_DEVICE_TYPE:-iPhone 17}")"
    echo "Created Simulator \"$name\" ($udid)"
  fi
  xcrun simctl list devices | grep -q "$udid) (Booted)" || shutdown_udid="$udid"
  destination="platform=iOS Simulator,id=$udid"
  # Boot it and open Safari once now: a fresh Simulator's first Safari launch is its slowest, and
  # the tests that open a link wait for Safari to come up.
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" >/dev/null
  xcrun simctl launch "$udid" com.apple.mobilesafari >/dev/null || true
  sleep 3
  xcrun simctl terminate "$udid" com.apple.mobilesafari 2>/dev/null || true
fi

# xcodebuild hands TEST_RUNNER_<NAME> to the test runner as <NAME>. The tests pass the URL and
# token on to the app (DEBUG builds read LINKS_SERVER_URL and LINKS_DEV_TOKEN).
# Signed (ad hoc, for the Simulator): the app needs its App Group entitlement for the keychain.
status=0
(
  cd "$ios"
  TEST_RUNNER_LINKS_SERVER_URL="$url" \
  TEST_RUNNER_LINKS_DEV_TOKEN="$me_token" \
  TEST_RUNNER_LINKS_FRIEND_TOKEN="$friend_token" \
  TEST_RUNNER_LINKS_SPARE_TOKEN="$spare_token" \
  TEST_RUNNER_LINKS_DELETABLE_TOKEN="$deletable_token" \
  xcodebuild "${LINKS_UI_TEST_ACTION:-test}" \
    -project Links.xcodeproj \
    -scheme Links \
    -configuration Debug \
    -destination "$destination" \
    -derivedDataPath "${LINKS_UI_TEST_DERIVED_DATA:-build}" \
    -parallel-testing-enabled NO \
    "$@"
) 2>&1 | tee "$logs/xcodebuild.log" || status=$?

# Without the TEST_RUNNER_ values the tests skip themselves; here that would be a false pass.
if [[ $status -eq 0 ]] && grep -q "^Test Case '.*' skipped" "$logs/xcodebuild.log"; then
  echo "error: UI tests were skipped, so the server URL or tokens didn't reach them" >&2
  status=1
fi
if [[ $status -ne 0 ]]; then
  echo "--- server log (last 40 lines) ---" >&2
  tail -n 40 "$logs/server.log" >&2
fi
exit "$status"
