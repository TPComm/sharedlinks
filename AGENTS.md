# Agent instructions

Links is a shared inbox for the reels and TikToks people send each other. Read `README.md` first:
it covers the product, sign-in, deployment and the API. The Server and iOS app sections below
have the details for each half.

- `server/`: the API, TypeScript on Bun 1.4.4 with SQLite, compiled to one self-contained binary
- `ios/`: the SwiftUI app (iOS 18+) with a Share Extension, widgets and App Intents; `ios/LinksKit`
  is the Swift package all three share
- `deploy/`: `setup.sh` and `deploy.sh`, which provision a VPS and ship the binary behind Caddy

## Checks before you push

| Changed | Run |
| --- | --- |
| `server/` | `cd server && bun install && bun run typecheck && bun test`, then `bun run build:x64 && LINKS_BINARY=dist/links-server-linux-x64 bun run test:e2e` |
| `deploy/` | `shellcheck --severity=warning deploy/*.sh` (CI uses ShellCheck 0.9.0) |
| `ios/` | on a Mac with Xcode 27: `(cd ios/LinksKit && swift test)`, the `xcodebuild build-for-testing` under iOS app below, then `ios/scripts/ui-tests.sh` |

All of these run offline: WorkOS and preview pages are stubbed, and the UI tests sign in with
minted session tokens.

## CI is tuned for speed

The repo is public, so GitHub-hosted runners cost nothing, macOS included. On a PR that touches
`ios/`, `assets/icon/` or `.github/workflows/ios.yml`, the iOS workflow splits the UI tests across
two macOS runners (`LINKS_UI_TEST_SHARD` in `ios/scripts/ui-tests.sh`). Slice 1 runs LinksKit tests
and builds before booting; slice 2 waits for its compiled test products before booting. Duration
weights give slice 1 fewer test-seconds to allow for its build, without a separate build job that
could queue behind artifact-waiting slices under the org's five-job macOS cap.
Both jobs first remove unused runtime images best-effort, preserving iOS 27.2 and all device sets,
and log host resources at startup and after boot.

- Still build and test iOS changes on a Mac before pushing: a red CI run costs you that wait.
- The org runs at most 5 macOS jobs at once, so a second iOS run queues behind the first.
- Keep server-only and iOS changes in separate PRs where that's natural, so server PRs skip the
  macOS jobs.

## main is protected

Changes reach `main` only through pull requests, and a PR merges only once these checks pass:
"Typecheck, test and build", "LinksKit tests, app build and UI tests", "ShellCheck" and "setup.sh
and deploy.sh as root on Ubuntu 24.04" (the ruleset in Settings → Rules → Rulesets).

- Every workflow runs on every PR. Its `changes` job decides whether the real job runs; when the
  PR doesn't touch that area, the job reports "skipped", which counts as passing.
- When a workflow should watch other paths, update both the pattern in its `changes` job (PRs)
  and its `push: paths` (main).
- Renaming one of those jobs (its `name:`) leaves the ruleset waiting for a check that never
  comes. Update the ruleset in the same change.

## Conventions

- Commit subjects are one plain sentence saying what changes, in the imperative, with no
  `feat:`-style prefix ("Let people delete their account from the app").
- Comments explain why, briefly; the existing code is the style guide.
- Keep `README.md` current: its API table, admin commands and settings are the reference people
  use. Add a row when you add or change an endpoint.
- Never commit secrets or session tokens. `LINKS_DEV_TOKEN` belongs in a private (unshared) copy
  of the Links scheme, never the shared one CI uses.

## Server

TypeScript run directly by Bun 1.4.4 (the version CI, `@types/bun` and the shipped binary pin), no
framework, SQLite through `bun:sqlite`. Use Bun's built-ins (`Bun.serve`, `bun:sqlite`, `bun:test`)
over npm packages; the binary must stay self-contained.

```bash
cd server
bun install
bun run dev                                   # http://localhost:8000; data in ./data
bun run mint-session you@example.com "Name"   # a session token for /api/*, no WorkOS needed
bun run typecheck && bun test                 # offline
bun run build:x64 && LINKS_BINARY=dist/links-server-linux-x64 bun run test:e2e
```

Paths below are under `server/`:

- `src/main.ts`: entry point and the admin CLI (`mint-session`, `delete-user`, `reports`, `backup`,
  `version`)
- `src/app.ts`: routes; auth is checked per route, and anything unmatched is the public 404
- `src/config.ts`: every environment variable, with its default
- `src/db.ts`: schema and migrations
- `src/accounts.ts` (WorkOS, sessions, legacy users, account deletion), `src/links.ts` (URL
  canonicalization), `src/previews.ts` (thumbnails and rich previews), `src/net.ts` (`safeFetch`,
  which blocks private addresses), `src/moderation.ts` (reports, blocks, the word list)

Rules:

- Schema changes are a new `migrateToVn` in `src/db.ts` that bumps `PRAGMA user_version` inside a
  transaction. Never edit a migration that has shipped; the server upgrades production databases
  in place on start.
- Fetch other hosts only through `safeFetch` in `src/net.ts` (SSRF protection).
- A new setting goes in `Config` and `configFromEnv` in `src/config.ts`, in `README.md`, and in
  `deploy/setup.sh` if the VPS needs it.
- Tests stay offline. `test/api.test.ts` drives the real server against a fake WorkOS;
  `test/unit/helpers.ts` has `tempDir`, `fakeFetch` and `stubServer`. `test/e2e/` runs the compiled
  binary as a process.

## iOS app

SwiftUI for iOS 18+, built with Xcode 27.2 (CI pins `/Applications/Xcode_27.2.app`; point
`DEVELOPER_DIR` at your Xcode 27 if `xcodebuild -version` shows an older one). Paths below are
under `ios/`:

- `Links/`: the app (`AppModel.swift`, `Views/`, `Intents/`)
- `LinksShare/`: the Share Extension; `LinksWidgets/`: Home and Lock Screen widgets
- `LinksKit/`: the Swift package all three use: API client, models, the session in the App Group
  keychain, the on-disk inbox cache. Put shared logic here, with tests in `LinksKit/Tests`.
- `LinksUITests/`: XCUITests against a real server (`LinksServer.swift` sets up state through the API)

```bash
cd ios
(cd LinksKit && swift test)
xcodebuild build-for-testing -project Links.xcodeproj -scheme Links -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build ARCHS=arm64
LINKS_UI_TEST_ACTION=test-without-building scripts/ui-tests.sh   # add -only-testing:LinksUITests/LinksUITests/<test> for one
```

`scripts/ui-tests.sh` needs Bun on `PATH` (it adds `~/.bun/bin`): it starts `server/` with an empty
database, mints the tokens the tests use, and runs them on a dedicated "Links UI Tests" Simulator
it creates. The tests skip themselves when run any other way.

Rules:

- Settings go in `Config.xcconfig`, not the project file. Simulator builds sign ad hoc;
  `DEVELOPMENT_TEAM` is only for devices.
- The targets use file-system synchronized groups, so a new file in a target's folder is picked up
  without editing `project.pbxproj`.
- Every shipped bundle (app, Share Extension, widgets) has its own `PrivacyInfo.xcprivacy`; declare
  any new required-reason API in each bundle that uses it, or App Store Connect rejects the build.
- The UI tests set `LINKS_UI_TESTS=1`, which skips the welcome tour, tips and the badge prompt.
- Build and test on a Mac before pushing: an iOS CI run takes ~10 minutes (see above).

## Sign-in (WorkOS AuthKit)

You rarely need real sign-in: `cd server && bun run mint-session you@example.com "Your Name"`
prints a session token for `Authorization: Bearer <token>` on `/api/*`, and the server starts
without `WORKOS_CLIENT_ID`. Real AuthKit sign-in (auth.tpcomm.co) only accepts its registered
redirects and puts a Cloudflare human check in front of sign-in and sign-up, which automated
browsers can't pass; leave that test to a person.

## Production

links.tpcomm.co runs the server. `curl https://links.tpcomm.co/version` says which commit it was
built from, no sign-in needed (`deploy/deploy.sh` compiles it in; a local build says `dev`). Only
`deploy/deploy.sh` ships to it, and only from a clean `main` that matches `origin/main`.
