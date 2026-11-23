# Links

A tiny shared inbox for the articles, videos, recipes, gift ideas and other links you send each
other. Each person sees what's still
**Queue**, what they've **Seen**, and whether the stuff they **Sent** has been seen, like
iMessage read receipts.

- **`ios/`**: native SwiftUI app for iOS 18+, with a Share Extension, widgets and App Intents
- **`server/`**: the API, TypeScript on [Bun](https://bun.sh), SQLite, one self-contained binary
- **`deploy/`**: scripts to run it on a cheap VPS behind Caddy (automatic HTTPS)

Sign-in is [WorkOS AuthKit](https://workos.com/docs/authkit).

## How sharing works

| From | What happens |
| --- | --- |
| **Any app's share sheet** (TikTok, Instagram, Safari…) | Tap **Links**. A compose sheet shows a preview (LinkPresentation), you can add a note, and Send. |
| **Share sheet suggestions row** | Once a friend has joined (and after each send), Links donates the group to iOS, which then offers it in the top row next to Messages contacts, one tap from any app. |
| **Shortcuts / Siri / Spotlight / Action button** | "Send a link with Links" (`Send Link` intent, takes a URL or any text containing one), "What's in Links", "New Links". |
| **In the app** | **+** opens a sheet with the system Paste button (no "Allow Paste" prompt). Drag a link from Safari onto the list (iPad, iPhone). |
| **Sharing out** | Long-press or swipe a row, or Share on a link's page: the system share sheet sends the link's public `/l/` page (the original URL on servers without one), with the thumbnail as the preview. Opening an `/l/` link in the app shows that link's page when it's in your inbox. |

An invite starts a private one-to-one chat with the inviter. Once a friend joins, you can add
them to an ordinary group or start a new group with them; people who share a group also get
one-to-one chats. Everyone is a legacy chat: its existing members can still use it, but nobody
can add or invite new members. If you leave a group, the direct chats stay;
leave a direct chat once you no longer share any groups with that person.

Plus: a **Home Screen / Lock Screen widget** (Queue or Sent receipts, small/medium/large and
lock screen sizes) whose ✓ buttons mark things seen without opening the app, an **app icon
badge** with the Queue count, reactions, notes, search and swipe actions. Tapping a row (or a
widget row) opens the link's page: **Open in TikTok** (or Instagram, YouTube…), react, see who
has seen it, and mark it seen when you're back. On a link you sent, tap **Nudge** next to someone
who hasn't watched, or **Nudge Everyone**; each person can be nudged once per day. Coming back from TikTok lands on that page,
even if iOS closed the app meanwhile. Long-press **Open in TikTok** still goes straight there and
marks it seen in one go.

**Profile → Links Wrapped** shows monthly and yearly highlights: your top sender, watch rate,
top platform and most-reacted link, with an opt-in shareable card. It covers only links you can
see in your current chats; dates use your local calendar and reactions/seen marks reflect now.

**Shared with You** shows who shared a Links universal link in Messages on the link's page,
when available. Tap their name to return to the conversation and reply.

The **Throwback** card in Seen resurfaces links from at least a week ago that you and a friend
loved, with a different starting pick each day.

**Chat Info → Taste Match** counts links in that chat that every current member has reacted to
with ❤️, 😂 or 🔥, and opens the three most recently shared matches on their normal link pages.
It needs at least two people, uses only links visible to you, and updates as reactions and chat
membership change. Browsing a match does not mark it seen.

Each link's page also has a comment thread: read and reply below the reactions and receipts,
edit or delete your own comments, or report someone else's. Commenting marks the link seen. The list shows comment counts and
highlights new replies; read positions stay on this device, separate for each account. The
sender's original note stays separate from the conversation.

New people get a short **welcome tour** after their first sign-in (Profile → Show Tour Again).
It walks through putting Links at the front of the share sheet, with a practice share that ticks
itself off, and TipKit tips then point out the gestures once each.

## Feature tours

New features appear once per device after the welcome tour, and can be replayed from
**Profile → What's New**. To add one, add a stable case to `FeatureTour` in
`ios/Links/Views/FeatureTour.swift`, supply its page content and optional action, and add an
assertion to `ios/LinksUITests/FeatureTourUITests.swift`. Case order is presentation order;
never rename a shipped case's id. `FeatureTours` in LinksKit keeps seen ids in App Group defaults.
Debug launches can use `LINKS_RESET_FEATURE_TOURS=1` to start fresh and
`LINKS_COMPLETE_ONBOARDING=1` to act as an existing user. `LINKS_RESET_ONBOARDING=1` resets both
tours; `LINKS_UI_TESTS=1` suppresses automatic tours.

## Messages extension

In Messages, open **+ → Links** (under **More** if needed), browse **Queue / Recent**, and tap
a link to insert a draft, **not send it**. The draft uses the public `/l/<token>` share page,
never the original URL. Older cached links without a share page stay greyed out until refreshed
in Links. Select a Links message to see **Open in Links** for its link page; open the main app
to sign in if needed.

**Today's roll-up** inserts one draft card with the links you sent to a chosen Links chat today
(your local day). Select a roll-up to open that chat in Links or open its links that are in your inbox.

On the iOS 27 Simulator, this flow works in the seeded iMessage conversation
**+1 (555) 564-8583**, which `MessagesUITests` uses to check draft insertion without sending.
New conversations stay SMS, with the iMessage app drawer disabled.

## Set up WorkOS (once)

1. Create a WorkOS account and enable **AuthKit** (email + password, passkeys, Apple…). If you turn
   on **Google** (or any other social login), turn on **Sign in with Apple** too: App Store guideline
   4.8 asks for an equivalent login next to a social one. Email + password and passkeys alone don't
   need it.
2. **Redirects**: add `https://YOUR-HOST/auth/callback`. For local development (staging environment)
   also add `http://localhost:8000/auth/callback`.
3. Copy the **Client ID** (and optionally an **API key**; the code exchange also works with PKCE
   alone).
4. Links is invite-only: signing in to your AuthKit isn't enough, someone has to let you in.
   Let yourself in first: on the server, `links-server invite you@x.com` prints an invite, and
   signing in with that (verified) email uses it. This grants access to the app, not to any chats.
   After that, anyone who's in can let a friend in
   from the app (**People → Invite a Friend**): the invite link works once, for 7 days, and an
   invite sent to an email address also lets that (verified) address in without the link. Set
   `APP_STORE_ID` (the app's numeric App Store ID) to show a Smart App Banner on invite pages.
   Servers from before invites had an `ALLOWED_EMAILS` guest list instead: the first start of
   this version keeps everyone already signed up who's still on it (everyone already signed up,
   if it isn't set), and after that it's never read, so take it out of the env file.
5. **Custom domain** (optional, so saved passwords are under your name): in WorkOS → Domains, give
   AuthKit a host of yours, e.g. `auth.YOUR-DOMAIN` (it points at WorkOS, so it can't be the
   server's host). iCloud Keychain and 1Password save the sign-up password under the host in the
   sign-in page's address bar, so it's now yours instead of WorkOS's. The redirect in step 2 stays
   `https://YOUR-HOST/auth/callback`. To tie those passwords to the app, that host has to serve
   `https://auth.YOUR-DOMAIN/.well-known/apple-app-site-association` (200, JSON, no redirect) with
   `{"webcredentials": {"apps": ["TEAMID.com.yourname.links"]}}`, and `LINKS_AUTH_DOMAIN` in
   `ios/Config.xcconfig` names it (the app's entitlements add `webcredentials:` for it). Without the
   file the password is still saved under that host, just not linked to Links. Logins saved under
   the old AuthKit domain aren't offered on the new one, since AutoFill matches by domain.

**Sign in with Apple and email invites.** Someone who picks *Hide My Email* signs in with a relay
address (`…@privaterelay.appleid.com`, and `…@private.icloud.com` for new ones from late 2026), not
the email you invited, so that invite doesn't match them without its link: have them tap the invite
link before signing in (an invite's link lets in a relay address even if it was sent to an email),
or ask them to choose *Share My Email*. Someone already in who later signs in with Hide My Email is
a different account to WorkOS, so the server turns them away and asks them to sign in the way they
did before.

Deleting an account (`DELETE /api/me` with `WORKOS_API_KEY` set) deletes the WorkOS user too.
WorkOS's docs don't say whether that also revokes the person's Sign in with Apple tokens, and
Links never sees those tokens (WorkOS keeps them). If it doesn't, Apple's
[TN3194](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple)
covers it: once the account data is gone, the person can stop using Sign in with Apple with Links
in their Apple Account settings.

How it fits together: the app opens `/auth/authorize` in `ASWebAuthenticationSession` with a PKCE
challenge; the server forwards to AuthKit; AuthKit redirects back to `/auth/callback`, which hands
the code to the app's `sharedlinks://` URL; the app sends the code and its PKCE verifier to
`/api/auth/token`; the server exchanges them with WorkOS, checks they're in (or have an invite), and returns a
long-lived Links session token. The token lives in the keychain under the App Group, so the Share
Extension and widgets use the same session (no refresh-token races between processes).

## Develop locally

Failed link previews retry in the background after roughly 1 minute, 5 minutes, 30 minutes,
2 hours, then every 12 hours, one at a time. Retry history is in memory and resets on server
restart. “Try Loading the Preview Again” bypasses this delay. Reddit previews combine its
public oEmbed title/author with thumbnail metadata fetched as a link-preview bot.
An incomplete thumbnail fetch also retries with this backoff, even after the title arrives;
Reddit title-only results remain eligible because HTML and oEmbed can recover separately.

```bash
curl -fsSL https://bun.sh/install | bash        # once; then add ~/.bun/bin to your PATH
cd server && bun install
WORKOS_CLIENT_ID=client_... bun run dev          # http://localhost:8000
bun test                                         # API tests (offline: WorkOS is stubbed)
```

Then open `ios/Links.xcodeproj`. `ios/Config.xcconfig` holds the shipped app's team
(`DEVELOPMENT_TEAM`) and bundle id (`LINKS_BUNDLE_ID = com.tpcomm.links`; the App Group is
`group.<that>`); a fork that runs on its own devices sets its own team and an id it owns there.
Debug builds talk to `http://localhost:8000`, which the Simulator can reach, and Release builds
(archives for TestFlight) to `https://links.tpcomm.co` (`LINKS_SERVER_URL_Debug` /
`LINKS_SERVER_URL_Release`). Bump `CURRENT_PROJECT_VERSION` there before each TestFlight upload.

TestFlight feedback becomes GitHub issues on its own: every 6 hours
`.github/workflows/testflight-feedback.yml` files each new screenshot comment or crash report as
an issue labelled `testflight` (public, like the repo, but without the tester's name or email),
with its screenshots copied to the `testflight-feedback` branch. It needs the App Store Connect API
key in the repo's Actions secrets (`ASC_ISSUER_ID`, `ASC_KEY_ID`, `ASC_KEY_P8`); run it from the
Actions tab to file feedback right away, or with "dry run" to preview.

**Skip WorkOS in the Simulator:** mint a session and hand it to the app.

```bash
cd server && bun run mint-session you@example.com "Your Name"
```

Put the printed token in a private copy of the Links scheme, not the shared one: the shared
scheme is committed, and CI and `ios/scripts/ui-tests.sh` use it. In Product → Scheme → Manage
Schemes, select Links, click Duplicate, and make sure **Shared** is unchecked on the copy (Xcode
then keeps it in the gitignored `xcuserdata/`). Add `LINKS_DEV_TOKEN` under that copy's Edit
Scheme → Run → Environment Variables, run it once, and the app is signed in (Debug builds only).
Add `LINKS_RESET_ONBOARDING=1` too to see the welcome tour and tips again, as on a first launch.
(The UI tests set `LINKS_UI_TESTS=1`, which skips the tour, the tips and the badge prompt.)

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
a free `sslip.io` name like `203-0-113-7.sslip.io` also does), and make sure `ssh root@<ip>` works
with an SSH key, since the scripts connect about a dozen times. Log in as root, or as a user with
passwordless sudo (the scripts run their remote steps without a terminal). Then, from this repo:

```bash
read -rs 'WORKOS_API_KEY?WorkOS API key (Enter to skip): ' && export WORKOS_API_KEY   # zsh: not saved to shell history
WORKOS_CLIENT_ID=client_... \
  deploy/setup.sh root@203.0.113.7 links.example.com
```

That adds swap on small boxes, installs Caddy and automatic security updates, creates a locked-down
`links` service and a daily database backup (`/var/lib/links/backups`, newest 14 nightly snapshots, plus `photos/` and `report-photos/` copies for every retained snapshot), opens only
SSH/80/443, then builds the right binary for the VPS's CPU on your Mac and deploys it. Finally set
`LINKS_SERVER_URL_Release = https:/$()/links.example.com` in `ios/Config.xcconfig`, and let yourself
in: `sudo -u links sh -c 'set -a && . /etc/links/links.env && DATA_DIR=/var/lib/links /opt/links/links-server invite you@x.com'`.

**Updates:** `deploy/deploy.sh root@203.0.113.7` tests, builds, uploads, swaps and health-checks.
It only ships a clean `main` that matches `origin/main`, and compiles the commit in: `curl
https://links.example.com/version` says what's live, and `/opt/links/deploys.log` lists each deploy.
A build that doesn't come up healthy is rolled back automatically; the last good one is kept as
`links-server.prev`. Re-running `setup.sh` only changes the settings you pass. The OS and Caddy patch themselves; Bun's
runtime is inside the binary, so run `bun upgrade && deploy/deploy.sh …` about once a month.

**Push notifications** (new links, when someone watches or reacts to a link you sent, and the app badge while Links is closed). Without
them the app still works, polling while it's open. To turn them on:

1. In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list),
   open the app's identifier (`LINKS_BUNDLE_ID`) and tick **Push Notifications** and **Communication
   Notifications** (new-link pushes show the sender's photo). The notification service extension,
   `LINKS_BUNDLE_ID.notifications`, which adds that photo and the link's thumbnail, needs its own
   identifier with the App Group, like `.share` and `.widgets`.
2. Under [Keys](https://developer.apple.com/account/resources/authkeys/list), add a key with
   **Apple Push Notifications service (APNs)**, for **Sandbox & Production** so one key covers Xcode
   builds and TestFlight/App Store builds. Download the `.p8` (only possible once) and note its Key ID.
3. Pass them to `setup.sh`, which installs the key as `/etc/links/apns.p8` (`640 root:links`) and
   restarts the server:

```bash
APNS_TEAM_ID=9F2D9SPG9Z APNS_TOPIC=com.tpcomm.links \
APNS_KEY_ID=ABC123DEFG APNS_KEY_FILE=~/Downloads/AuthKey_ABC123DEFG.p8 \
  deploy/setup.sh root@203.0.113.7 links.example.com
```

Instead of `APNS_KEY_FILE`, `APNS_KEY_P8` can hold the `.p8`'s contents (for example from a secret
store). `APNS_TOPIC` is the app's bundle ID (`LINKS_BUNDLE_ID`). Without a key the server logs one warning
at startup and sends nothing.

**Backups off the box:** `rsync -a root@203.0.113.7:/var/lib/links/backups/ ./backups/`

**Restoring:** alongside the `.db`, copy `backups/photos/*` into `DATA_DIR/photos` and `backups/report-photos/*` into `DATA_DIR/report-photos`.

**Labelled backups:** a copy named `links-YYYY-MM-DD-<label>.db` in the backups folder (say one made
before a deploy) is removed by the nightly backup once its date is 14 days old, except the newest such
copy, which stays so a rollback always has one.

**Logs and metrics in Grafana Cloud** (its free tier covers them). `deploy/monitoring.sh` installs
[Fluent Bit](https://fluentbit.io) (~25 MB of RAM, capped at 80 MB) to ship the journal of `links`,
`links-backup` and Caddy to Loki and host CPU, memory, disk, network and unit metrics to Prometheus
once a minute, labelled `job="links"`. Get the URLs and numeric users from the stack's Loki and
Prometheus **Details** pages on grafana.com, and an access policy token with `logs:write` and
`metrics:write`; the token goes to a root-only `/etc/fluent-bit/links.env`, never a command line:

```bash
read -rs 'GRAFANA_CLOUD_TOKEN?Grafana Cloud token: ' && export GRAFANA_CLOUD_TOKEN   # zsh
LOKI_URL=https://logs-prod-000.grafana.net LOKI_USER=123456 \
PROM_URL=https://prometheus-prod-00-prod-us-east-0.grafana.net/api/prom/push PROM_USER=654321 \
  deploy/monitoring.sh root@203.0.113.7
```

It checks both pushes before it finishes and is safe to re-run, for example with a new token. In
Grafana's Explore: `{job="links"}` for logs, `node_memory_MemAvailable_bytes{job="links"}` for metrics.

**Grafana dashboard:** `deploy/grafana/links-dashboard.json` reads what `deploy/monitoring.sh` ships:
host health, API traffic parsed from the request log, the daily backup, unit state and the logs, per
host. Import it in Grafana (Dashboards → New → Import); it finds the stack's Prometheus and Loki
data sources itself. The live copy is "Links" in the Links folder of the Grafana Cloud stack; after
editing it there, export it (Share → Export, without "Export for sharing externally") over this file.

**Grafana alerts:** `deploy/grafana/links-alerts.json` defines the "links-prod" rule group in the
Links folder: **Links site down** (`links` or `caddy` unit not active for 3m, or the host stops
sending metrics), **Links 5xx spike** (5 or more 5xx request lines in 5m), **Links disk filling
up** (under 15% free on `/` for 10m), **Links backup stalled** (no `backed up to` line from
`links-backup` in 26h, so the daily backup stopped running or kept failing), **Links push
notifications failing** (3 or more push failure log lines in 15m for 5m, so a one-off 429 rate
limit doesn't page; successful sends aren't logged) and **Links Loki heartbeat missing** (no
Fluent Bit heartbeat in Loki for 5m, persisting for another 3m). They match
`instance`/`host` `links.tpcomm.co` only, so test servers never fire them, and send to the
"Links → Sherlog (Devin webhook)" contact point. After changing them in Grafana, export the group
(Alert rules → links-prod → Export, JSON) over this file.

Before enabling the Loki heartbeat rule, rerun `deploy/monitoring.sh` and verify
`{job="links",host="links.tpcomm.co",systemd_unit="links-loki-heartbeat"}` receives a line each
minute. The heartbeat checks Fluent Bit's Loki output, not the journal input or application traffic.

**Reports and moderation** (App Store guideline 1.2). Whoever runs the server reads the reports:

- People report a link, comment or person from its long-press menu or its page. A reported link or comment is hidden
  for the reporter at once, and everyone else still sees it. Each report logs a line
  (`journalctl -u links | grep report`).
- `links-server reports` (as the `links` user: `sudo -u links env DATA_DIR=/var/lib/links /opt/links/links-server reports`)
  lists open reports, each with a copy of what was reported then. `links-server reports resolve <id>`
  marks one handled; `--remove` also deletes the comment, or the link and its thumbnail, for everyone. To remove a
  person, `links-server delete-user <email>`: they're out, and only a new invite lets them back in.
- Blocking is one-way and only for the blocker: they stop seeing the blocked person's links,
  comments, watched marks and reactions (including comment counts and last-comment previews). Notes can only be changed by the link's sender.
- Notes, comments and display names with a word on the list in `server/src/moderation.ts` are refused. Add
  your own, one per line, to `/var/lib/links/blocked-words.txt` and restart (`systemctl restart links`).
- The support address, `support@tpcomm.co`, is shown on `https://YOUR-HOST/support`: use that page as
  the App Store listing's Support URL. The app shows the same address (`LINKS_SUPPORT_URL` in
  `ios/Config.xcconfig`) in the profile and on the sign-in screen. A different server can set
  its own with `SUPPORT_EMAIL` (pass it to `setup.sh`), along with `LINKS_SUPPORT_URL`.
- The privacy policy (App Store guideline 5.1.1) is on `https://YOUR-HOST/privacy`: use that page as
  the listing's Privacy Policy URL. The app opens it from the profile and the sign-in screen.
  It gives `SUPPORT_EMAIL` for privacy requests. Keep it in step with
  `ios/Links/PrivacyInfo.xcprivacy` and the listing's privacy answers.
- Trademarks (App Store guideline 5.2): the sign-in screen and the tour say TikTok and Instagram
  are their owners' trademarks and that Links isn't affiliated with them, and **About Links** in
  the profile lists every platform the app names (`Platform.trademarkOwner` in
  `ios/LinksKit`). Add an owner there when you add a platform.

**Universal links** (needs a paid Apple Developer membership; free teams can't sign the
Associated Domains entitlement). With them, `https://YOUR-HOST/l/…`, `/invite/…` and `/g/…` links
open the app instead of Safari. When it isn't installed, link pages show the title, thumbnail and
a button to watch the original; group links show "Open this in the Links app". The server serves `/.well-known/apple-app-site-association` once you pass
`APPLE_APP_IDS=TEAMID.com.yourname.links` (comma-separated, case kept; the team ID is on
developer.apple.com → Membership) to `setup.sh`; `APP_STORE_ID=<number>` adds a Smart App Banner to
those pages once the app is on the App Store. In `ios/Config.xcconfig` set `LINKS_ASSOCIATED_DOMAIN`
to the bare host name (no `https://`, no port). Debug builds add `?mode=developer`, so the phone
reads the file straight from your server instead of Apple's CDN: on the phone turn on Settings →
Developer → Associated Domains Development, and use Settings → Developer → Universal Links →
Diagnostics to check a URL. Release builds go through Apple's CDN, which can take a day to pick up
a change. Test on a real device. It can't be `localhost:8000`: the file must come over HTTPS with a
valid certificate and no redirect, and the domain can't have a port. A link tapped on a page of the
same host stays in Safari (Apple's rule); links from Messages, Mail or Notes open the app.

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
entries. Anyone can type a name, so the admin decides who is who: `links-server claim` lists them,
and `links-server claim you@x.com Sam` lets that account (a member of the default chat) claim Sam.
The app then asks "Were you one of these?" (or offers Claim Earlier Links… in the profile)
and moves that person's links, comments, watched marks and reactions to the account. `claimable` lists only
the legacy people approved for your account.

## API

API endpoints except sign-in need `Authorization: Bearer <session token>`; pages marked public do not.

| Method | Path | Body / notes |
| --- | --- | --- |
| GET | `/api/wrapped` | `?start=<unix seconds>&end=<unix seconds>[&group_id=<id>]` → `{start, end, received, sent, watched, top_sender, top_platform, most_reacted}`; integer half-open range shorter than 367 days to allow local leap years with offset changes, current visible chats only; top fields null without qualifying shares, `most_reacted` contains link fields with `sender_name` and a numeric `reactions` count; 400 for invalid dates, 404 for a chat you aren't in |
| GET | `/` | public browser landing page; opens the iPhone app, explains invites, and links to support and privacy; `APP_STORE_ID` adds an App Store link and Smart App Banner |
| GET | `/app-preview.png` | public iPhone app screenshot with fictional sample data, embedded in the server binary for the landing page |
| GET | `/auth/authorize` | `?code_challenge=&state=[&screen_hint=sign-up]` → redirects to AuthKit |
| GET | `/auth/callback` | AuthKit's redirect; bounces to `sharedlinks://auth/callback?code=…` |
| POST | `/api/auth/token` | `{code, code_verifier, invite?}` → `{token, user, claimable, group_id}`; `invite` is the token from an invite link, used up here or by `/api/invites/accept`; `group_id` is the chat it took them to (null without one) |
| POST | `/api/auth/logout` | ends this session (and removes its device tokens) |
| POST | `/api/devices` | `{token, env}`: this session's APNs device token (hex), `env` is `sandbox` or `production` → `{ok, push}` (`push`: whether the server sends any). Registering a token again moves it to this session |
| DELETE | `/api/devices/:token` | forget one of your device tokens |
| GET/PATCH/DELETE | `/api/me` | `{user, claimable, notifications}`; PATCH `{name}` and/or `{notifications: {watched?, reactions?}}` (booleans, both on to start: whether I get a push when someone watches or reacts to a link I sent; a watch and a reaction from one person within a minute go out as one); DELETE deletes the account, its sessions, watched marks and reactions, and the links it sent (with their notes and thumbnails, for everyone). Also the WorkOS user, given `WORKOS_API_KEY` |
| PUT/DELETE | `/api/me/photo` | PUT's body is my profile photo itself, a JPEG or PNG up to 2 MB and 4096px a side (the app sends a 512px JPEG); it replaces the WorkOS picture as my `avatar` everywhere, at a new `/photos/:token` address each time. DELETE goes back to initials. Both return what `GET /api/me` does |
| GET | `/photos/:token` | A profile photo, no sign-in needed (`AsyncImage` sends none): the address is random and stops working once its photo is replaced or removed, or its account deleted |
| POST | `/api/me/claim` | `{id}` of a legacy person in my `claimable` (one `links-server claim` approved for my account) |
| GET | `/api/state` | `{me, users, groups, links, blocked}`: `users` is only people I share a chat with, plus anyone named on a link in my chats and people I blocked; the chats I'm in (`{id, name, created_by, created_at, default, direct, members, muted, muted_until}`; `direct` marks a private 1:1 chat; my effective mute and its Unix-seconds deadline, null when unmuted or indefinite) and their links (each with its `group_id`), without links I reported or that people I blocked sent, and without blocked people's watched marks and reactions; `?group_id=` for one chat's links |
| POST | `/api/links` | `{url, note?, group_id?}`; `url` may be any text containing a link; without `group_id` (apps from before chats) it goes to the default chat, or my only chat if I left that → `{link, duplicate}` (a duplicate only within the same chat) |
| POST | `/api/groups` | `{name?, members?}` (user ids; I'm added) → 201 `{group}`. An empty name means the app names it after its members; up to 50 people |
| PATCH | `/api/groups/:id` | `{name?, muted?, muted_until?}` (at least one): rename the chat or change only my mute → `{group}`. `muted: true` mutes indefinitely with an omitted/null deadline, or until `muted_until` (finite future Unix seconds); `muted: false` clears the deadline. A deadline alone updates the existing mute's deadline. Muting suppresses new-link, comment and watched/reaction alerts, not Queue counts or badges |
| POST | `/api/groups/:id/members` | `{members}`: any group member adds people who are in Links → `{group}`. The legacy Everyone chat and direct chats cannot accept more members. Direct chats cannot be renamed. Nobody removes anyone else |
| DELETE | `/api/groups/:id` | Leave the chat; the links I sent stay in it. The last one out deletes it and its links (never the default chat). Leave shared group chats before leaving the direct chat with a group mate |
| POST | `/api/links/:id/seen` | `{seen: true/false}` |
| POST | `/api/links/:id/nudge` | Sender only: `{people?: [userId, …]}`; omitted or empty means all eligible unwatched chat members. Skips reports and blocks in either direction; at most once per person per link per 24 hours (even without devices or when muted) → `{nudged: [userId, …], link}`. 429 if only the cooldown prevents a nudge, otherwise 400 when nobody is eligible. Only the sender's link JSON includes `nudged: {personId: UnixSeconds, …}` (all recorded times) |
| POST | `/api/links/:id/react` | `{emoji}` (`null` removes) |
| POST | `/api/links/:id/refresh` | `{}` → `{link}`; fetch the preview again immediately, unless already pending |
| PATCH / DELETE | `/api/links/:id` | `{note}` (sender only) / –; 403 if the sender blocked you |
| GET/POST | `/api/links/:id/comments` | Chat members only. GET → `{comments}` oldest first (ties by id); POST `{body}` (nonempty text, trimmed and clipped to 1000 Unicode characters) → 201 `{comment}`, and marks the link seen for the commenter. Comments are `{id, link_id, person, body, created_at, edited_at}`; blocked authors and reported comments are hidden for the reader |
| PATCH/DELETE | `/api/comments/:id` | Author only, while still in the chat. PATCH `{body}` → `{comment}` (sets `edited_at`); DELETE → `{ok:true}`. Deleting a link or account cascades its comments |
| POST | `/api/reports` | `{link_id \| comment_id \| user_id, reason, details?}`; reason is `spam`, `offensive`, `harassment` or `other` → 201 |
| POST | `/api/blocks` | `{user_id}` → `{blocked}` |
| DELETE | `/api/blocks/:user_id` | unblock (URL-encode the id) → `{blocked}` |
| GET/POST | `/api/invites` | GET → `{invites}` (mine, still pending); POST `{email?}` → 201 `{invite: {id, email, group_id, created_at, expires_at, url}}`. Using the invite opens a direct chat with me, never a group. Older clients' `group_id` is ignored and returned as null |
| POST | `/api/invites/accept` | `{token}` → `{group}`: someone already in opens or starts a direct chat with the inviter; `group` is null for their own or an admin's invite. An open invite stays pending if the pair already had a chat; a verified recipient uses up an email-bound invite. Invites addressed to verified people already paired with the sender are omitted from the sender's pending list but their links remain usable. Without recorded email verification they can return to an existing direct chat without claiming an email-bound invite, but can't use it to start a new one; 404 for inactive links, 403 for a mismatched or unverified email |
| DELETE | `/api/invites/:id` | cancels a pending invite → `{invites}` |
| GET | `/invite/:token` | public page for an invite link: who sent it, Open in Links, the Smart App Banner. Loading it never uses the invite up |
| GET | `/.well-known/apple-app-site-association` | public; which paths open the app (only with `APPLE_APP_IDS`) |
| GET | `/l/:token` | public link page (optional trailing slash) with only the title, thumbnail and original URL; rich previews and a universal link into the app. Unknown or deleted tokens return 404 |
| GET | `/l/:token/image` | public cached thumbnail, accessible only with the link's unguessable token; 404 without a thumbnail or after deletion |
| GET | `/g/:id` | public "Open this in the Links app" page; universal link into the app |
| GET | `/privacy` | public privacy policy page, with the same address, for the App Store Privacy Policy URL |
| GET | `/support` | public page with the support address (`SUPPORT_EMAIL`, default `support@tpcomm.co`), for the App Store Support URL |
| GET | `/thumbs/:id` | the cached thumbnail |
| GET | `/version` | public: `{commit}`, the git commit the server was built from (`dev` unless built by `deploy/deploy.sh`) |

Each link includes `token` (its unguessable share token) and `share_url` (the absolute public `/l/:token` URL).
Adding a `share_url` from this server adds the original URL, with duplicate detection within the destination chat.
Anyone with that URL can view its title and thumbnail and open the original URL, without seeing the inbox.
Each link also includes `comment_count` and `last_comment: {person, snippet, at} | null`, scoped to
what the reader may see. The snippet is at most 120 Unicode characters; `at` is the comment's
creation time in Unix seconds, not its edit time. Comments stay separate from the sender's note.
New comments alert every current chat member except the author, on devices with live app sessions.
Members who muted the chat, reported the link, or blocked its sender or the commenter get no alert.
Alerts identify the commenter and include a shortened comment preview; tapping opens the link.
Edits, deletions and reports stay silent. Posting a comment marks the link seen for its author, so a
first comment on someone else's unseen link leaves the author's Queue and lowers their badge. Other
members' counts and badges don't change; the app tracks read threads locally.

Admin: `links-server invite [email]` admits a new account without any chats.
`links-server mint-session <email> [name]` is the trusted local development shortcut and puts newly
minted accounts in Everyone. Other commands: `links-server delete-user <email>` (what the app's Delete Account does),
`links-server claim [<email> <legacy name>]` (list legacy people, or let that account claim one),
`links-server reports`, `links-server reports resolve <id> [--remove]`, `links-server backup [dir]` and
`links-server version` (the commit it was built from).

The app icon is `assets/icon/SharedLinks.icon`, a layered Icon Composer document the Xcode project uses
directly; open it in Icon Composer to edit. `assets/icon/README.md` has previews and the alternate design.
