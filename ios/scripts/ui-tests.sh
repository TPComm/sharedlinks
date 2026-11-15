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
#   LINKS_UI_TEST_SHARD         K/N: run only every Nth test starting with the Kth, as CI does to
#                               split the tests across N runners (default: all of them)
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
# server/.env skipped: settings from it would leak into the tests. Minted accounts are in already.
server_env=(DATA_DIR="$tmp/data" HOST=127.0.0.1 PORT="$port" WORKOS_CLIENT_ID=client_E2E)

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
fi

# On a freshly booted CI Simulator the app's first launch can take minutes, outlasting XCUITest's
# launch timeout ("Timed out while launching application via Xcode") or stalling the test runner
# until it crashes. Later launches take a second, so the app is installed and launched once here,
# where simctl waits as long as it takes. Only on our own Simulator with an app already built
# (test-without-building); best effort.
app="${LINKS_UI_TEST_DERIVED_DATA:-build}"
if [[ "$app" != /* ]]; then app="$ios/$app"; fi
app="$app/Build/Products/Debug-iphonesimulator/Links.app"
warm_up() {
  [[ -n "${udid:-}" && "${LINKS_UI_TEST_ACTION:-test}" == test-without-building && -d "$app" ]] || return 0
  local started=$SECONDS
  xcrun simctl boot "$udid" 2>/dev/null || true
  if xcrun simctl install "$udid" "$app"; then
    # Right after boot SpringBoard may not take launches yet, so a failed launch gets a few more.
    for _ in 1 2 3 4 5 6; do
      SIMCTL_CHILD_LINKS_UI_TESTS=1 xcrun simctl launch "$udid" com.tpcomm.links >/dev/null && break
      sleep 10
    done
    xcrun simctl terminate "$udid" com.tpcomm.links 2>/dev/null || true
  fi
  echo "Simulator booted and Links launched once in $((SECONDS - started))s"
}
warm_up

# -- shard: deal the tests out in the order the test files list them, read from the source. The
# last slice runs everything the others don't (-skip-testing), so a test the scan misses still runs.
shard_args=()
if [[ -n "${LINKS_UI_TEST_SHARD:-}" ]]; then
  if [[ ! "$LINKS_UI_TEST_SHARD" =~ ^([0-9]+)/([0-9]+)$ ]] \
    || (( BASH_REMATCH[1] < 1 || BASH_REMATCH[1] > BASH_REMATCH[2] )); then
    echo "error: LINKS_UI_TEST_SHARD must be K/N with 1 <= K <= N, not \"$LINKS_UI_TEST_SHARD\"" >&2
    exit 1
  fi
  shard="${BASH_REMATCH[1]}" shards="${BASH_REMATCH[2]}" i=0 mine=0
  while IFS= read -r test; do
    if (( i % shards == shard - 1 )); then
      mine=$((mine + 1))
      if (( shard < shards )); then shard_args+=("-only-testing:$test"); fi
    elif (( shard == shards )); then
      shard_args+=("-skip-testing:$test")
    fi
    i=$((i + 1))
  done < <(find "$ios/LinksUITests" -name '*.swift' -print0 | LC_ALL=C sort -z | xargs -0 awk '
    FNR == 1 { class = "" }
    /(^|[^A-Za-z0-9_])class[[:space:]]+[A-Za-z0-9_]+[[:space:]]*:[[:space:]]*XCTestCase/ {
      sub(/.*class[[:space:]]+/, ""); sub(/[[:space:]]*:.*/, ""); class = $0; next
    }
    class != "" && /^[[:space:]]*(@[A-Za-z]+[[:space:]]+)*func[[:space:]]+test[A-Za-z0-9_]*[[:space:]]*\(/ {
      sub(/.*func[[:space:]]+/, ""); sub(/[[:space:]]*\(.*/, ""); print "LinksUITests/" class "/" $0
    }
  ')
  if (( mine == 0 )); then
    echo "error: UI test slice $LINKS_UI_TEST_SHARD has no tests ($i in all)" >&2
    exit 1
  fi
  echo "UI test slice $LINKS_UI_TEST_SHARD: $mine of the $i tests found, plus any the scan missed in the last slice"
  if (( ${#shard_args[@]} )); then printf '  %s\n' "${shard_args[@]}"; fi
fi

# xcodebuild hands TEST_RUNNER_<NAME> to the test runner as <NAME>. The tests pass the URL and
# token on to the app (DEBUG builds read LINKS_SERVER_URL and LINKS_DEV_TOKEN).
# Signed (ad hoc, for the Simulator): the app needs its App Group entitlement for the keychain.
run_tests() {
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
      ${shard_args[@]+"${shard_args[@]}"} \
      "$@"
  ) 2>&1 | tee "$logs/xcodebuild.log"
}
status=0
run_tests "$@" || status=$?

# On CI the test runner sometimes crashes before running a single test, once Xcode has lost the
# Simulator's service hub. That's the runner, not a test, so it gets one more go on a fresh boot.
if [[ $status -ne 0 ]] && grep -q "crashed while preparing to run tests" "$logs/xcodebuild.log" &&
   ! grep -q "^Test Case '.*' started" "$logs/xcodebuild.log"; then
  echo "warning: the test runner crashed before any test ran; trying once more" >&2
  mv "$logs/xcodebuild.log" "$logs/xcodebuild-crashed.log"
  if [[ -n "${udid:-}" ]]; then xcrun simctl shutdown "$udid" 2>/dev/null || true; fi
  warm_up
  status=0
  run_tests "$@" || status=$?
fi

# Only infrastructure failures get another go; an assertion failure keeps the run red.
if [[ $status -ne 0 ]]; then
  recoverable="$(bash "$ios/scripts/ui-test-recoverable-failures.sh" "$logs/xcodebuild.log" || true)"
  if [[ -n "$recoverable" ]]; then
    if [[ "$recoverable" == *crash* ]]; then
      if [[ -n "${udid:-}" ]]; then
        echo "warning: simulator crash interrupted UI tests; rebooting and warming up before rerunning only affected tests once" >&2
        xcrun simctl shutdown "$udid" 2>/dev/null || true
        xcrun simctl boot "$udid"
        xcrun simctl bootstatus "$udid" -b
        warm_up
      else
        echo "warning: cannot recover a simulator crash on an externally supplied destination" >&2
        recoverable=""
      fi
    else
      echo "warning: app launch timed out; rerunning only affected tests once" >&2
    fi
  fi
  if [[ -n "$recoverable" ]]; then
    echo "$recoverable" >&2
    mv "$logs/xcodebuild.log" "$logs/xcodebuild-infrastructure-failure.log"
    # The sign-out and account-deletion tests use up these two, so they get fresh ones.
    spare_token="$(mint me@e2e.test)"
    deletable_token="$(mint deletable@e2e.test Deletable)"
    shard_args=()
    while read -r _ test; do shard_args+=("-only-testing:LinksUITests/$test"); done <<<"$recoverable"
    status=0
    run_tests "$@" || status=$?
  fi
fi

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
