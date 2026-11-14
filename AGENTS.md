# Agent instructions

Links is a shared inbox for the reels and TikToks people send each other. Read `README.md` first:
it covers the product, sign-in, deployment and the API. `server/AGENTS.md` and `ios/AGENTS.md`
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
| `ios/` | on a Mac with Xcode 27: `(cd ios/LinksKit && swift test)`, the `xcodebuild build-for-testing` in `ios/AGENTS.md`, then `ios/scripts/ui-tests.sh` |

All of these run offline: WorkOS and preview pages are stubbed, and the UI tests sign in with
minted session tokens.

## GitHub Actions minutes are limited

The iOS workflow runs on macOS, which costs about 10x a Linux job, on every push to a PR that
touches `ios/`, `assets/icon/` or `.github/workflows/ios.yml`.

- Never use CI as the compiler. Build and test iOS changes on a Mac before pushing.
- Batch fixes into as few pushes as you can; each push to such a PR starts a new macOS run.
- Keep server-only and iOS changes in separate PRs where that's natural, so server PRs skip the
  macOS job.

## Conventions

- Commit subjects are one plain sentence saying what changes, in the imperative, with no
  `feat:`-style prefix ("Let people delete their account from the app").
- Comments explain why, briefly; the existing code is the style guide.
- Keep `README.md` current: its API table, admin commands and settings are the reference people
  use. Add a row when you add or change an endpoint.
- Never commit secrets or session tokens. `LINKS_DEV_TOKEN` belongs in a private (unshared) copy
  of the Links scheme, never the shared one CI uses.

## Sign-in (WorkOS AuthKit)

You rarely need real sign-in: `cd server && bun run mint-session you@example.com "Your Name"`
prints a session token for `Authorization: Bearer <token>` on `/api/*`, and the server starts
without `WORKOS_CLIENT_ID`. Real AuthKit sign-in (auth.tpcomm.co) only accepts its registered
redirects and puts a Cloudflare human check in front of sign-in and sign-up, which automated
browsers can't pass; leave that test to a person.

## Production

links.tpcomm.co runs the server. To tell which build it runs without signing in, request a route:
one the build has answers 401 without a token, one it lacks falls through to 404 (for example
`curl -X DELETE https://links.tpcomm.co/api/me`). Only `deploy/deploy.sh` ships to it.
