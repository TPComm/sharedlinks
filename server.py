#!/usr/bin/env python3
"""Shared Links: a tiny, dependency-free app for swapping reels and TikToks.

Run:  python3 server.py            (then open http://localhost:8000)
Env:  PORT=8000  HOST=0.0.0.0  DATA_DIR=./data  APP_KEY=<optional room code>
"""
import hmac
import html
import json
import mimetypes
import os
import re
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
STATIC = ROOT / "static"
DATA = Path(os.environ.get("DATA_DIR", ROOT / "data")).resolve()
THUMBS = DATA / "thumbs"
KEY = os.environ.get("APP_KEY", "")
PORT = int(os.environ.get("PORT", "8000"))
HOST = os.environ.get("HOST", "0.0.0.0")

BROWSER_UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
              "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1")
# Instagram only serves Open Graph tags (title, thumbnail) to link-preview bots.
BOT_UA = "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)"
EMOJIS = {"❤️", "😂", "🔥", "😮", "😭", "👎"}

mimetypes.add_type("application/manifest+json", ".webmanifest")
mimetypes.add_type("text/javascript", ".js")


# ---------------------------------------------------------------- database

db_lock = threading.Lock()
db: sqlite3.Connection


def init_db():
    global db
    THUMBS.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(DATA / "links.db", check_same_thread=False)
    db.row_factory = sqlite3.Row
    db.executescript("""
        PRAGMA journal_mode = WAL;
        PRAGMA foreign_keys = ON;
        CREATE TABLE IF NOT EXISTS people (
            name TEXT PRIMARY KEY COLLATE NOCASE,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS links (
            id INTEGER PRIMARY KEY,
            url TEXT NOT NULL UNIQUE,
            platform TEXT NOT NULL,
            title TEXT,
            author TEXT,
            thumb_type TEXT,
            meta TEXT NOT NULL DEFAULT 'pending',
            note TEXT NOT NULL DEFAULT '',
            added_by TEXT NOT NULL,
            added_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS seen (
            link_id INTEGER NOT NULL REFERENCES links(id) ON DELETE CASCADE,
            person TEXT NOT NULL,
            seen_at REAL NOT NULL,
            PRIMARY KEY (link_id, person)
        );
        CREATE TABLE IF NOT EXISTS reactions (
            link_id INTEGER NOT NULL REFERENCES links(id) ON DELETE CASCADE,
            person TEXT NOT NULL,
            emoji TEXT NOT NULL,
            PRIMARY KEY (link_id, person)
        );
    """)
    # Previews that were mid-fetch when the server last stopped get retried.
    for row in q("SELECT id, url, platform FROM links WHERE meta = 'pending'"):
        start_metadata_fetch(row["id"], row["url"], row["platform"])


def q(sql, args=()):
    with db_lock:
        cur = db.execute(sql, args)
        rows = cur.fetchall()
        db.commit()
        return rows


def insert(sql, args=()):
    with db_lock:
        cur = db.execute(sql, args)
        db.commit()
        return cur.lastrowid


def clean_name(name):
    name = re.sub(r"\s+", " ", str(name or "")).strip()[:30]
    if not name:
        raise ValueError("Missing name.")
    row = q("SELECT name FROM people WHERE name = ?", (name,))
    if row:
        return row[0]["name"]  # keep the original capitalisation
    q("INSERT INTO people (name, created_at) VALUES (?, ?)", (name, time.time()))
    return name


def get_state():
    links = {}
    for r in q("SELECT * FROM links ORDER BY added_at DESC"):
        links[r["id"]] = {
            "id": r["id"], "url": r["url"], "platform": r["platform"],
            "title": r["title"], "author": r["author"], "note": r["note"],
            "thumb": f"/thumbs/{r['id']}" if r["thumb_type"] else None,
            "meta": r["meta"], "added_by": r["added_by"], "added_at": r["added_at"],
            "seen": {}, "reactions": {},
        }
    for r in q("SELECT * FROM seen"):
        if r["link_id"] in links:
            links[r["link_id"]]["seen"][r["person"]] = r["seen_at"]
    for r in q("SELECT * FROM reactions"):
        if r["link_id"] in links:
            links[r["link_id"]]["reactions"][r["person"]] = r["emoji"]
    people = [r["name"] for r in q("SELECT name FROM people ORDER BY created_at")]
    return {"people": people, "links": list(links.values())}


def get_link(link_id):
    return next((l for l in get_state()["links"] if l["id"] == link_id), None)


# ---------------------------------------------------------------- links

URL_RE = re.compile(r"https?://[^\s<>\"']+", re.I)
BARE_RE = re.compile(r"\b(?:[\w-]+\.)+[a-z]{2,}/[^\s<>\"']*", re.I)
TRACKING_RE = re.compile(r"^(utm_\w+|igsh|igshid|fbclid|gclid|si|feature|ref|ref_src|s)$")
PLATFORMS = {
    "tiktok": ("tiktok.com",),
    "instagram": ("instagram.com", "instagr.am"),
    "youtube": ("youtube.com", "youtu.be"),
    "x": ("x.com", "twitter.com"),
    "reddit": ("reddit.com", "redd.it"),
    "facebook": ("facebook.com", "fb.watch"),
}


def extract_url(text):
    """Pull the first link out of whatever was pasted ('lol look https://...')."""
    text = str(text or "")
    m = URL_RE.search(text) or BARE_RE.search(text)
    if not m:
        return None
    url = m.group(0).rstrip(").,!?;:'\"")
    return url if url.lower().startswith("http") else "https://" + url


def platform_of(host):
    for name, domains in PLATFORMS.items():
        if any(host == d or host.endswith("." + d) for d in domains):
            return name
    return "web"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


_no_redirect = urllib.request.build_opener(_NoRedirect)


def resolve_redirects(url, hops=6):
    """Expand share short-links (vm.tiktok.com/..., instagram.com/share/...)."""
    for _ in range(hops):
        req = urllib.request.Request(url, headers={"User-Agent": BROWSER_UA})
        try:
            with _no_redirect.open(req, timeout=6):
                return url
        except urllib.error.HTTPError as e:
            loc = e.headers.get("Location")
            if e.code in (301, 302, 303, 307, 308) and loc:
                nxt = urllib.parse.urljoin(url, loc)
                if "login" in urllib.parse.urlsplit(nxt).path:
                    return url  # bounced to a login wall; the short link is the best we have
                url = nxt
                continue
            return url
        except Exception:
            return url
    return url


def canonical(url):
    """Normalise a link so the same video shared twice is detected as a duplicate."""
    parts = urllib.parse.urlsplit(url)
    host = (parts.hostname or "").lower()
    path = parts.path
    if (host in ("vm.tiktok.com", "vt.tiktok.com") or
            (host.endswith("tiktok.com") and path.startswith("/t/")) or
            (host.endswith("instagram.com") and path.startswith("/share/"))):
        parts = urllib.parse.urlsplit(resolve_redirects(url))
        host = (parts.hostname or "").lower()
        path = parts.path

    platform = platform_of(host)
    if platform == "instagram":
        path = re.sub(r"^/reels/", "/reel/", path)
        path = re.sub(r"^/[^/]+/(reel|p)/", r"/\1/", path)  # /username/reel/ID -> /reel/ID
        query = ""
    elif platform == "tiktok":
        query = ""
    else:
        pairs = urllib.parse.parse_qsl(parts.query, keep_blank_values=True)
        query = urllib.parse.urlencode([(k, v) for k, v in pairs if not TRACKING_RE.match(k)])
    # One spelling per site (TikTok's oEmbed only accepts www.tiktok.com).
    bare = host.removeprefix("www.").removeprefix("m.")
    if bare in ("tiktok.com", "instagram.com", "youtube.com", "facebook.com", "reddit.com"):
        host = "www." + bare
    path = path.rstrip("/") or "/"
    netloc = host + (f":{parts.port}" if parts.port else "")
    return urllib.parse.urlunsplit(("https" if platform != "web" else parts.scheme.lower(),
                                    netloc, path, query, "")), platform


def add_link(text, note, by):
    raw = extract_url(text)
    if not raw:
        raise ValueError("That doesn't look like a link.")
    url, platform = canonical(raw)
    if not urllib.parse.urlsplit(url).hostname:
        raise ValueError("That doesn't look like a link.")
    existing = q("SELECT id FROM links WHERE url = ?", (url,))
    if existing:
        return get_link(existing[0]["id"]), True
    link_id = insert(
        "INSERT INTO links (url, platform, note, added_by, added_at) VALUES (?, ?, ?, ?, ?)",
        (url, platform, str(note or "").strip()[:500], by, time.time()))
    start_metadata_fetch(link_id, url, platform)
    return get_link(link_id), False


# ---------------------------------------------------------------- previews

def http_get(url, ua=BROWSER_UA, limit=2_000_000):
    req = urllib.request.Request(url, headers={"User-Agent": ua, "Accept-Language": "en-US,en"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.read(limit), r.headers.get_content_type()


def og_tags(page):
    tags = {}
    for meta in re.findall(r"<meta\b[^>]*>", page, re.I):
        attrs = {k.lower(): html.unescape(v1 or v2)
                 for k, v1, v2 in re.findall(r'([\w:-]+)\s*=\s*(?:"([^"]*)"|\'([^\']*)\')', meta)}
        key = attrs.get("property") or attrs.get("name")
        if key and "content" in attrs:
            tags.setdefault(key.lower(), attrs["content"])
    m = re.search(r"<title[^>]*>(.*?)</title>", page, re.I | re.S)
    if m:
        tags.setdefault("title", html.unescape(m.group(1)).strip())
    return tags


def fetch_preview(url, platform):
    if platform in ("tiktok", "youtube"):
        endpoint = {"tiktok": "https://www.tiktok.com/oembed?url=",
                    "youtube": "https://www.youtube.com/oembed?format=json&url="}[platform]
        body, _ = http_get(endpoint + urllib.parse.quote(url, safe=""))
        d = json.loads(body)
        return {"title": d.get("title"), "author": d.get("author_name"), "image": d.get("thumbnail_url")}

    body, _ = http_get(url, BOT_UA if platform in ("instagram", "facebook") else BROWSER_UA)
    og = og_tags(body.decode("utf-8", "replace"))
    title = og.get("og:title") or og.get("twitter:title") or og.get("title")
    desc = og.get("og:description") or og.get("description") or ""
    author = None
    if platform == "instagram":
        # og:title looks like: Name on Instagram: "caption"
        # og:description like: 12K likes, 40 comments - handle on May 1, 2025: "caption"
        m = re.search(r"-\s+([\w.]+)\s+on\s+\w+ \d", desc)
        author = "@" + m.group(1) if m else None
        m = re.match(r'^(.*?) on Instagram: ["“](.*)["”]\s*$', title or "", re.S)
        if m:
            author = author or m.group(1)
            title = m.group(2)
        elif title and title.strip().lower() == "instagram":
            title = None
    return {"title": title, "author": author or og.get("og:site_name"),
            "image": og.get("og:image") or og.get("twitter:image")}


def start_metadata_fetch(link_id, url, platform):
    threading.Thread(target=_fetch_metadata, args=(link_id, url, platform), daemon=True).start()


def _fetch_metadata(link_id, url, platform):
    meta = {}
    try:
        meta = fetch_preview(url, platform)
    except Exception as e:
        print(f"preview failed for {url}: {e}", file=sys.stderr)
    thumb_type = None
    if meta.get("image"):
        try:
            data, ctype = http_get(urllib.parse.urljoin(url, meta["image"]), limit=6_000_000)
            if ctype.startswith("image/"):
                (THUMBS / str(link_id)).write_bytes(data)
                thumb_type = ctype
        except Exception as e:
            print(f"thumbnail failed for {url}: {e}", file=sys.stderr)
    title = re.sub(r"\s+", " ", meta.get("title") or "").strip()[:300] or None
    author = (meta.get("author") or "").strip()[:80] or None
    q("UPDATE links SET title = ?, author = ?, thumb_type = ?, meta = ? WHERE id = ?",
      (title, author, thumb_type, "done" if (title or thumb_type) else "failed", link_id))


# ---------------------------------------------------------------- http

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "SharedLinks/1.0"

    def do_GET(self): self.handle_request()
    def do_HEAD(self): self.handle_request()
    def do_POST(self): self.handle_request()
    def do_PATCH(self): self.handle_request()
    def do_DELETE(self): self.handle_request()

    def log_message(self, fmt, *args):
        if not self.path.startswith("/api/state"):
            super().log_message(fmt, *args)

    def handle_request(self):
        self.extra_headers = []
        try:
            self.route()
        except ValueError as e:
            self.send_json({"error": str(e)}, 400)
        except Exception as e:
            print(f"error handling {self.command} {self.path}: {e!r}", file=sys.stderr)
            self.send_json({"error": "Something went wrong."}, 500)

    # -- helpers

    def send(self, code, body=b"", ctype="application/json", cache="no-cache"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        for k, v in self.extra_headers:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_json(self, obj, code=200):
        self.send(code, json.dumps(obj).encode())

    def redirect(self, location):
        self.extra_headers.append(("Location", location))
        self.send(303, b"", "text/plain")

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > 65536:
            raise ValueError("Request too large.")
        raw = self.rfile.read(length) if length else b""
        return json.loads(raw) if raw.strip() else {}

    def authorized(self, query):
        if not KEY:
            return True
        cookies = dict(c.strip().split("=", 1) for c in (self.headers.get("Cookie") or "").split(";") if "=" in c)
        for candidate in (self.headers.get("X-Key"), query.get("key"), cookies.get("k")):
            if candidate and hmac.compare_digest(urllib.parse.unquote(candidate), KEY):
                if candidate != cookies.get("k"):
                    # Remember the code so <img> thumbnails work too.
                    self.extra_headers.append(("Set-Cookie", f"k={urllib.parse.quote(KEY)}; Path=/; "
                                               "Max-Age=31536000; SameSite=Lax; HttpOnly"))
                return True
        return False

    def static(self, name):
        path = (STATIC / name).resolve()
        if STATIC not in path.parents or not path.is_file():
            return self.send_json({"error": "Not found"}, 404)
        ctype = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        if ctype.startswith("text/") or ctype.endswith(("json", "javascript")):
            ctype += "; charset=utf-8"
        self.send(200, path.read_bytes(), ctype)

    # -- routes

    def route(self):
        parts = urllib.parse.urlsplit(self.path)
        path, query = parts.path, dict(urllib.parse.parse_qsl(parts.query))
        method = self.command if self.command != "HEAD" else "GET"

        if method == "GET" and not path.startswith(("/api/", "/thumbs/", "/add")):
            self.authorized(query)  # an invite link (/?key=...) sets the cookie
            return self.static("index.html" if path == "/" else path.lstrip("/"))

        if not self.authorized(query):
            return self.send_json({"error": "locked"}, 401)

        if method == "GET" and path == "/api/state":
            return self.send_json(get_state())

        if method == "GET" and (m := re.fullmatch(r"/thumbs/(\d+)", path)):
            row = q("SELECT thumb_type FROM links WHERE id = ?", (int(m[1]),))
            file = THUMBS / m[1]
            if not row or not row[0]["thumb_type"] or not file.is_file():
                return self.send_json({"error": "Not found"}, 404)
            return self.send(200, file.read_bytes(), row[0]["thumb_type"], "private, max-age=2592000")

        # Share-sheet entry point: /add?url=...&by=Name  (Android share target, iOS Shortcut, bookmarklet)
        if method == "GET" and path == "/add":
            text = " ".join(query.get(k, "") for k in ("url", "text", "title"))
            if not query.get("by"):
                return self.redirect("/#add=" + urllib.parse.quote(extract_url(text) or ""))
            link, dup = add_link(text, query.get("note"), clean_name(query["by"]))
            return self.redirect(f"/?added={link['id']}&dup={int(dup)}")

        if method == "POST" and path == "/api/people":
            return self.send_json({"name": clean_name(self.body().get("name"))})

        if method == "POST" and path == "/api/links":
            data = self.body()
            link, dup = add_link(data.get("url") or data.get("text"), data.get("note"),
                                 clean_name(data.get("by") or "Someone"))
            return self.send_json({"link": link, "duplicate": dup}, 200 if dup else 201)

        m = re.fullmatch(r"/api/links/(\d+)(?:/(seen|react))?", path)
        if not m:
            return self.send_json({"error": "Not found"}, 404)
        link_id, action = int(m[1]), m[2]
        if not q("SELECT 1 FROM links WHERE id = ?", (link_id,)):
            return self.send_json({"error": "That link was deleted."}, 404)

        if method == "DELETE" and not action:
            q("DELETE FROM links WHERE id = ?", (link_id,))
            (THUMBS / str(link_id)).unlink(missing_ok=True)
            return self.send_json({"ok": True})

        data = self.body()
        if method == "PATCH" and not action:
            q("UPDATE links SET note = ? WHERE id = ?", (str(data.get("note") or "").strip()[:500], link_id))
        elif method == "POST" and action == "seen":
            person = clean_name(data.get("by"))
            if data.get("seen", True):
                q("INSERT OR IGNORE INTO seen (link_id, person, seen_at) VALUES (?, ?, ?)",
                  (link_id, person, time.time()))
            else:
                q("DELETE FROM seen WHERE link_id = ? AND person = ?", (link_id, person))
        elif method == "POST" and action == "react":
            person, emoji = clean_name(data.get("by")), data.get("emoji")
            if emoji in EMOJIS:
                q("INSERT OR REPLACE INTO reactions (link_id, person, emoji) VALUES (?, ?, ?)",
                  (link_id, person, emoji))
            else:
                q("DELETE FROM reactions WHERE link_id = ? AND person = ?", (link_id, person))
        else:
            return self.send_json({"error": "Not found"}, 404)
        return self.send_json({"link": get_link(link_id)})


def main():
    init_db()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Shared Links running on http://{'localhost' if HOST == '0.0.0.0' else HOST}:{PORT}"
          f"{'  (room code required)' if KEY else ''}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
