# Links

A tiny shared inbox for the reels and TikToks you send each other. Each person sees what's still
**To Watch**, what they've **Watched**, and whether the stuff they **Sent** has been seen, like
iMessage read receipts.

- **`ios/`**: native SwiftUI app for iOS 18+, with a Share Extension, widgets and App Intents
- **`server/`**: the API, TypeScript on [Bun](https://bun.sh), SQLite, one self-contained binary
- **`deploy/`**: scripts to run it on a cheap VPS behind Caddy (automatic HTTPS)

Sign-in is [WorkOS AuthKit](https://workos.com/docs/authkit).

## How sharing works

| From | What happens |
| --- | --- |
| **Any app's share sheet** (TikTok, Instagram, Safari…) | Tap **Links**. A compose sheet shows a preview (LinkPresentation), you can add a note, and Send. |
| **Share sheet suggestions row** | After you've sent a few, iOS offers your Links group in the top row next to Messages contacts, one tap from any app. |
| **Shortcuts / Siri / Spotlight / Action button** | "Send a link with Links" (`Send Link` intent, takes a URL or any text containing one), "What's in Links", "New Links". |
| **In the app** | **+** opens a sheet with the system Paste button (no "Allow Paste" prompt). Drag a link from Safari onto the list (iPad, iPhone). |
| **Sharing out** | Long-press or swipe a row: Share… uses the system share sheet with the thumbnail as the preview. |

Plus: a **Home Screen / Lock Screen widget** (To Watch or Sent receipts, small/medium/large and
lock screen sizes) whose ✓ buttons mark things watched without opening the app, an **app icon
badge** with the To Watch count, reactions, notes, search, swipe actions, and tapping a row opens
the video straight in TikTok/Instagram/YouTube.

## Set up WorkOS (once)

1. Create a WorkOS account and enable **AuthKit** (email + password, Google, Apple, passkeys,
   whatever you like).
2. **Redirects**: add `https://YOUR-HOST/auth/callback`. For local development (staging environment)
   also add `http://localhost:8000/auth/callback`.
3. Copy the **Client ID** (and optionally an **API key**; the code exchange also works with PKCE
   alone).
4. Decide who can get in: set `ALLOWED_EMAILS` on the server (`you@x.com,friend@y.com`, or
   `@yourdomain.com` for a whole domain). Without it, anyone who can sign in to your AuthKit
   can see everything. You can also turn off sign-ups in the WorkOS dashboard.

How it fits together: the app opens `/auth/authorize` in `ASWebAuthenticationSession` with a PKCE
challenge; the server forwards to AuthKit; AuthKit redirects back to `/auth/callback`, which hands
the code to the app's `sharedlinks://` URL; the app sends the code and its PKCE verifier to
`/api/auth/token`; the server exchanges them with WorkOS, checks the guest list, and returns a
long-lived Links session token. The token lives in the keychain under the App Group, so the Share
Extension and widgets use the same session (no refresh-token races between processes).

## Develop locally

```bash
curl -fsSL https://bun.sh/install | bash        # once; then add ~/.bun/bin to your PATH
cd server && bun install
WORKOS_CLIENT_ID=client_... bun run dev          # http://localhost:8000
bun test                                         # API tests (offline: WorkOS is stubbed)
```

Then open `ios/Links.xcodeproj`. In `ios/Config.xcconfig` set `DEVELOPMENT_TEAM` and
`LINKS_BUNDLE_ID` (something you own, e.g. `com.yourname.links`); the App Group becomes
`group.<that>`. `LINKS_SERVER_URL` defaults to `http://localhost:8000`, which the Simulator can reach.

**Skip WorkOS in the Simulator:** mint a session and hand it to the app.

```bash
cd server && bun run mint-session you@example.com "Your Name"
```

Put the printed token in the Links scheme (Edit Scheme → Run → Environment Variables) as
`LINKS_DEV_TOKEN`, run once, and the app is signed in (Debug builds only).

`ios/LinksKit` is a Swift package shared by all three targets; `swift test` in that folder runs
its tests on the Mac.

## Host it on the cheapest VPS

The server is one ~100 MB binary that idles around 20 MB of RAM, plus Caddy. Any 512 MB+ Linux VPS
with a **public IPv4** works. Prices checked on official pages on 2026-11-12:

| Provider | Plan | Price | Notes |
| --- | --- | --- | --- |
| **RackNerd** | 1 GB KVM (specials page) | **$21.99/year** (≈$1.83/mo) | Recommended: US locations, renews at the same price, long-running budget host |
| Servitro | "$1 Server" 1 GB | $12/year | Cheapest with IPv4, but Frankfurt only and a small provider |
| Oracle Cloud | Always Free (Ampere A1 or E2 micro) | $0 | Needs a card; idle free instances can be reclaimed unless you upgrade the account to Pay As You Go (still $0 within limits). Also open 80/443 in the VCN security list, and on Oracle's Ubuntu images remove their iptables REJECT rule (`/etc/iptables/rules.v4`), or Caddy can't get a certificate |
| UpCloud | Starter 1 GB | $3.50/month | Mainstream, hourly billing |

Avoid IPv6-only plans (TikTok's servers have no IPv6, so previews would fail) and VirMach "Lite"
plans (ports 80/443 blocked).

**Deploy:** pick Debian 12/13 or Ubuntu 24.04, point a DNS name at the VPS (any domain works;
a free `sslip.io` name like `203-0-113-7.sslip.io` also does), then from this repo. Log in as
root, or as a user with passwordless sudo (the scripts run their remote steps without a terminal):

```bash
WORKOS_CLIENT_ID=client_... WORKOS_API_KEY=sk_... ALLOWED_EMAILS=you@x.com,friend@y.com \
  deploy/setup.sh root@203.0.113.7 links.example.com
```

That adds swap on small boxes, installs Caddy and automatic security updates, creates a locked-down
`links` service and a daily database backup (`/var/lib/links/backups`, newest 14), opens only
SSH/80/443, then builds the right binary for the VPS's CPU on your Mac and deploys it. Finally set
`LINKS_SERVER_URL = https:/$()/links.example.com` in `ios/Config.xcconfig`.

**Updates:** `deploy/deploy.sh root@203.0.113.7` tests, builds, uploads, swaps and health-checks.
A build that doesn't come up healthy is rolled back automatically; the last good one is kept as
`links-server.prev`. Re-running `setup.sh` only changes the settings you pass. The OS and Caddy patch themselves; Bun's
runtime is inside the binary, so run `bun upgrade && deploy/deploy.sh …` about once a month.

**Backups off the box:** `rsync -a root@203.0.113.7:/var/lib/links/backups/ ./backups/`

### Moving over from the old Python web app

SQLite keeps recent writes in a `-wal` file next to the database, so copy a consolidated snapshot
rather than the raw file, and stop the new service while you swap it in:

```bash
# On the old machine, with the old server stopped:
sqlite3 data/links.db ".backup links-export.db"
scp links-export.db root@203.0.113.7:/tmp/
rsync -a data/thumbs/ root@203.0.113.7:/tmp/thumbs/

# On the VPS:
systemctl stop links
rm -f /var/lib/links/links.db /var/lib/links/links.db-wal /var/lib/links/links.db-shm
mv /tmp/links-export.db /var/lib/links/links.db && cp -a /tmp/thumbs/. /var/lib/links/thumbs/
chown -R links:links /var/lib/links && systemctl start links
```

On start the server upgrades the database in place. People from before sign-in become "legacy"
entries: on first sign-in the app asks "Were you one of these?" and moves that person's links,
watched marks and reactions to your account.

## API

All endpoints except sign-in need `Authorization: Bearer <session token>`.

| Method | Path | Body / notes |
| --- | --- | --- |
| GET | `/auth/authorize` | `?code_challenge=&state=[&screen_hint=sign-up]` → redirects to AuthKit |
| GET | `/auth/callback` | AuthKit's redirect; bounces to `sharedlinks://auth/callback?code=…` |
| POST | `/api/auth/token` | `{code, code_verifier}` → `{token, user, claimable}` |
| POST | `/api/auth/logout` | ends this session |
| GET/PATCH | `/api/me` | `{user, claimable}`; PATCH `{name}` |
| POST | `/api/me/claim` | `{id}` of a legacy person |
| GET | `/api/state` | `{me, users, links}` |
| POST | `/api/links` | `{url, note?}`; `url` may be any text containing a link → `{link, duplicate}` |
| POST | `/api/links/:id/seen` | `{seen: true/false}` |
| POST | `/api/links/:id/react` | `{emoji}` (`null` removes) |
| PATCH / DELETE | `/api/links/:id` | `{note}` / – |
| GET | `/thumbs/:id` | the cached thumbnail |

Admin: `links-server mint-session <email> [name]` and `links-server backup [dir]`.

`tools/make-icon.ts` redraws the app icon (`bun tools/make-icon.ts`).
