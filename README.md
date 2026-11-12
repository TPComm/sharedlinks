# Links

A tiny shared inbox for the reels and TikToks you text each other. Each person sees
what's still **To Watch**, what they've **Watched**, and whether the stuff they **Sent**
has been seen (like iMessage read receipts). It's styled like a native iPhone app and
can be added to the Home Screen.

No accounts, no dependencies: one Python file plus a static frontend. Data lives in
`data/links.db` (SQLite), and thumbnails are cached in `data/thumbs/`.

## Run it

```bash
python3 server.py                 # http://localhost:8000
PORT=9000 python3 server.py       # different port
APP_KEY=tacos python3 server.py   # require a room code (recommended if it's on the internet)
```

Requires Python 3.10+ and nothing else.

## Features

- **Paste anything.** Paste a whole text message and the link is pulled out. Tracking junk
  (`?igsh=`, `?is_from_webapp=`, `utm_*`…) is stripped, and short links (`vm.tiktok.com/…`)
  are expanded.
- **Duplicate detection.** If you both send the same video, it tells you who sent it first.
- **Previews.** Titles, creators and thumbnails come from TikTok and YouTube oEmbed and from
  Open Graph tags for everything else. Instagram previews are best effort: Instagram often
  refuses, and then you get a gradient "Instagram reel" tile instead.
- **Auto-mark as watched** when you tap a link to open it, or tap the circle (like Reminders).
- **Read receipts.** On things you sent: "Not seen yet" / "✓ Seen by Sam".
- **Reactions and notes.** Use the ⋯ menu for 6 quick reactions, notes, share, copy and delete.
- **Badge.** The unwatched count shows on the To Watch tab and, once added to the Home Screen,
  on the app icon (iOS 16.4+).
- **Live sync.** The app polls every 8 seconds while it's open. It also has search,
  dark mode, and a slide-up "Who's this?" picker the first time you open it.

## Put it on your phones

The server has to be reachable from both phones. Pick one:

1. **This computer + [Tailscale](https://tailscale.com) (free, private).** Install Tailscale here
   and on both phones, then [share this machine](https://tailscale.com/kb/1084/sharing) with your
   friend. Open `http://<this-machine>:8000` (MagicDNS name or 100.x IP). Downside: the computer
   has to be on.
2. **Always-on host.** Anything that runs a container with a persistent volume mounted at `/data`
   (Fly.io, Railway, a $5 VPS…). Use the included `Dockerfile` and set `APP_KEY`. Avoid hosts with
   no persistent disk (e.g. Render's free tier), because you'd lose the database on every deploy.

If you set `APP_KEY`, send your friend an invite link like `https://your-host/?key=tacos`.
They only need to open it once.

Then, on each iPhone: open the site in **Safari → Share → Add to Home Screen**. Do this
*after* opening the invite link if you use a room code. Open it from the Home Screen icon
and pick your name.

## One-tap saving from TikTok / Instagram (iOS Shortcut)

This is the part that actually replaces texting links. Set it up once per phone:

1. Open **Shortcuts** → **+** → name it **Save to Links**.
2. Tap the ⓘ (or the name at the top) → turn on **Show in Share Sheet**, and set it to receive
   **URLs** and **Text**.
3. Add the action **Get Contents of URL**:
   - URL: `https://your-host/api/links`
   - Method: **POST**
   - Headers: `X-Key` = your room code (only if you set `APP_KEY`)
   - Request Body: **JSON**, with `url` = *Shortcut Input* and `by` = *your name, exactly as
     you picked it in the app*
4. Add **Show Notification** → "Saved to Links ✓".

Now in TikTok or Instagram tap **Share → Share to… / More → Save to Links**. It's saved without
leaving the app, and it lands in your friend's To Watch list.

On Android, installing the app from Chrome adds **Links** to the share sheet automatically.

## API

| Method | Path | Body |
| --- | --- | --- |
| GET | `/api/state` | returns `{people, links}` |
| POST | `/api/links` | `{url, note?, by}`; `url` may be any text containing a link |
| POST | `/api/links/:id/seen` | `{by, seen: true/false}` |
| POST | `/api/links/:id/react` | `{by, emoji}` (`null` removes it) |
| PATCH | `/api/links/:id` | `{note}` |
| DELETE | `/api/links/:id` | |
| GET | `/add?url=…&by=…` | adds a link and redirects to the app (share targets, bookmarklets) |

When `APP_KEY` is set, send it as an `X-Key` header, a `?key=` query parameter, or the `k` cookie.

`tools/make_icons.py` regenerates the app icons.
