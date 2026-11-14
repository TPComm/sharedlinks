import type { Database } from "bun:sqlite";
import { join } from "node:path";
import { Accounts, AuthError, publicUser } from "./accounts.ts";
import type { Config } from "./config.ts";
import { deleteLink, now, openDatabase, type LinkRow, type UserRow } from "./db.ts";
import { BadRequest, canonical, clipText, extractUrl } from "./links.ts";
import { REPORT_REASONS } from "./moderation.ts";
import { fetchMetadata, PREVIEW_VERSION } from "./previews.ts";
import { Pusher, type PushOptions } from "./push.ts";
import { BUILD_COMMIT } from "./version.ts";

export const EMOJIS = new Set(["❤️", "😂", "🔥", "😮", "😭", "👎"]);

class NotFound extends Error {}

const json = (body: unknown, status = 200) =>
  Response.json(body, { status, headers: { "Cache-Control": "no-store" } });

const redirect = (location: string) =>
  new Response(null, { status: 302, headers: { Location: location, "Cache-Control": "no-store" } });

async function readJson(req: Request): Promise<Record<string, any>> {
  const text = await req.text();
  if (text.length > 65536) throw new BadRequest("Request too large.");
  if (!text.trim()) return {};
  try {
    const value = JSON.parse(text);
    return value && typeof value === "object" ? value : {};
  } catch {
    throw new BadRequest("Invalid JSON.");
  }
}

const escapeHtml = (s: string) =>
  s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

/** The page the App Store listing's Support URL points at (guideline 1.2: published contact information). */
function supportPage(email: string): string {
  const contact = email
    ? `<p>Email <a href="mailto:${escapeHtml(email)}">${escapeHtml(email)}</a>. We read every message.</p>`
    : "<p>Ask the person who runs this Links server.</p>";
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Links Support</title><style>body{font:17px/1.5 -apple-system,system-ui,sans-serif;max-width:36em;margin:3em auto;padding:0 1em}</style></head>
<body><h1>Links Support</h1>${contact}
<p>To report a link or a person, long-press the link in the app and choose <b>Report…</b> or <b>Block…</b>. Reported links are hidden for you straight away.</p>
</body></html>
`;
}

/**
 * The privacy policy (guideline 5.1.1(i)): the App Store listing's Privacy Policy URL, and the app's
 * account menu and sign-in screen. Keep it in step with ios/Links/PrivacyInfo.xcprivacy.
 */
function privacyPage(email: string, sessionDays: number): string {
  const contact = email
    ? `<a href="mailto:${escapeHtml(email)}">${escapeHtml(email)}</a>`
    : "the person who runs this Links server";
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Links Privacy Policy</title><style>body{font:17px/1.5 -apple-system,system-ui,sans-serif;max-width:36em;margin:3em auto;padding:0 1em}h2{font-size:1.1em;margin-top:1.6em}</style></head>
<body><h1>Links Privacy Policy</h1>
<p>Last updated 14 November 2026.</p>
<p>Links is a private inbox for the links a few friends send each other. This policy covers the Links app and this server, which keeps what the app shows. Questions or requests: ${contact}.</p>

<h2>What Links keeps, and why</h2>
<ul>
<li><b>Your account:</b> your email address, display name and profile photo address. They come from WorkOS, our sign-in provider, when you first sign in, and you can change your name in the app. They sign you in, check you're on this server's guest list, and show your friends who sent what.</li>
<li><b>What you do in Links:</b> the links you send and their notes, which links you've watched, your reactions, the reports you make and the people you block. For each link the server also fetches its title, author and thumbnail from the link's page.</li>
<li><b>Signed-in devices:</b> a scrambled (hashed) copy of each device's sign-in token, with when it was created and last used.</li>
<li><b>Server logs:</b> one line per request, with what was asked for (for example, "mark link 12 watched") and whether it worked. They're used to fix problems.</li>
<li><b>Backups:</b> a copy of the server's database, made every day.</li>
</ul>
<p>Links uses this only to run the app. There are no ads, no analytics and no tracking, and nothing is sold or shared for marketing.</p>

<h2>Who else sees it</h2>
<ul>
<li><b>The other people on this server</b> see your name and photo, the links you send and their notes, and your watched marks and reactions. Reports and blocks are private: only the person who runs the server reads reports.</li>
<li><b>WorkOS</b> runs sign-in. It keeps your email, your sign-in details and the sign-ins you make, and gets the app's name and version and your iOS version when you sign in, plus, like any website, your IP address and browser details while you sign in. See the <a href="https://workos.com/legal/privacy">WorkOS privacy policy</a>.</li>
<li><b>The company that hosts this server</b> stores it on its computers.</li>
</ul>
<p>Links only uses services like these that protect your data the way this policy describes. When the server fetches a link's preview, the site sees the server, not you. When you open a link, it opens in its own app (such as TikTok or Instagram) or in Safari, and their privacy policies apply there.</p>

<h2>How long it's kept</h2>
<ul>
<li>Your account and what you do in Links: until you delete them, or your account.</li>
<li>A device's sign-in: until you sign out on it, or ${sessionDays} days after it was last used.</li>
<li>Server logs: until the server's system log replaces them with newer ones, usually within a few weeks.</li>
<li>Backups: the newest 14 days are kept, so anything deleted is gone from the backups within two weeks.</li>
</ul>

<h2>Your choices</h2>
<ul>
<li>Change your display name in the app's account menu. Delete a link you sent, or change its note, from the link's long-press menu.</li>
<li>To delete your account, open the account menu in the app and choose <b>Delete Account</b>. That deletes your account, your sign-ins on every device, the links you sent with their notes and thumbnails (for your friends too), your watched marks and reactions, and your WorkOS account.</li>
<li>You can also email ${contact} to ask what Links keeps about you, to correct it, or to delete it.</li>
</ul>

<h2>Changes</h2>
<p>If this policy changes, this page shows the new version and its date.</p>
</body></html>
`;
}

function bearer(req: Request): string | null {
  const auth = req.headers.get("authorization") ?? "";
  return auth.slice(0, 7).toLowerCase() === "bearer " ? auth.slice(7).trim() || null : null;
}

export interface AppOptions extends PushOptions {
  /** How long a new link's push waits for its preview (title) before going out without it. */
  previewWaitMs?: number;
}

export function createApp(config: Config, opts: AppOptions = {}) {
  const db = openDatabase(config.dataDir);
  const accounts = new Accounts(db, config);
  const fetchOpts = { allowPrivateNetwork: config.allowPrivateNetwork };
  const pending = new Set<Promise<void>>();
  function track(task: Promise<void>) {
    const settled: Promise<void> = task.catch((e) => console.error(`push: ${e}`)).finally(() => pending.delete(settled));
    pending.add(settled);
  }
  const push = new Pusher(db, config, accounts, track, opts);

  // One fetch per link at a time (a retry during the backfill, an edit mid-fetch): the next waits its turn.
  const latest = new Map<number, Promise<void>>();
  function queueFetch(id: number, url: string, platform: string): Promise<void> {
    const run = (latest.get(id) ?? Promise.resolve()).then(() => fetchMetadata(db, config.dataDir, id, url, platform, fetchOpts));
    const settled = run.catch(() => {});
    latest.set(id, settled);
    void settled.then(() => { if (latest.get(id) === settled) latest.delete(id); });
    return run;
  }

  function startMetadataFetch(id: number, url: string, platform: string): Promise<void> {
    const task = queueFetch(id, url, platform)
      .catch((e) => console.error(`metadata ${id}: ${e}`))
      .finally(() => pending.delete(task));
    pending.add(task);
    return task;
  }

  // Previews that were mid-fetch when the server last stopped get retried.
  for (const row of db.query("SELECT id, url, platform FROM links WHERE meta = 'pending'").all() as LinkRow[]) {
    startMetadataFetch(row.id, row.url, row.platform);
  }

  // Links whose preview predates PREVIEW_VERSION (or failed before) are re-fetched one at a time, gently.
  function backfillNext() {
    let row: LinkRow | null;
    try {
      row = db.query("SELECT id, url, platform FROM links WHERE preview_v < ? AND meta != 'pending' ORDER BY added_at DESC LIMIT 1")
        .get(PREVIEW_VERSION) as LinkRow | null;
    } catch (e) {
      return console.error(`backfill stopped: ${e}`); // the database closed under us (shutdown)
    }
    if (!row) return;
    const task = queueFetch(row.id, row.url, row.platform)
      .catch((e) => {
        console.error(`backfill ${row.id}: ${e}`);
        db.run("UPDATE links SET preview_v = ? WHERE id = ?", [PREVIEW_VERSION, row.id]);
      })
      .finally(() => {
        pending.delete(task);
        setTimeout(backfillNext, config.previewBackfillMs).unref();
      });
    pending.add(task);
  }
  if (config.previewBackfillMs > 0) setTimeout(backfillNext, config.previewBackfillMs).unref();

  /**
   * A link `?1` can see: not one they reported, nor one from someone they blocked. Everyone else
   * still sees it. getState, getLink's callers (via linkId) and addLink's duplicate check use this.
   */
  const VISIBLE = `NOT EXISTS (SELECT 1 FROM reports WHERE reporter = ?1 AND link_id = links.id)
    AND NOT EXISTS (SELECT 1 FROM blocks WHERE blocker = ?1 AND blocked = links.added_by)`;

  const isVisible = (id: number, me: string) =>
    !!db.query(`SELECT 1 FROM links WHERE ${VISIBLE} AND id = ?2`).get(me, id);

  /** The people `me` has blocked. */
  function blockedBy(me: string): Set<string> {
    const rows = db.query("SELECT blocked FROM blocks WHERE blocker = ? ORDER BY created_at").all(me) as { blocked: string }[];
    return new Set(rows.map((r) => r.blocked));
  }

  const hasBlocked = (blocker: string, blocked: string) =>
    !!db.query("SELECT 1 FROM blocks WHERE blocker = ? AND blocked = ?").get(blocker, blocked);

  /** `me`'s view: no hidden links, and no seen marks or reactions from people they blocked. */
  function getState(me: string) {
    const blocked = blockedBy(me);
    const links = new Map<number, ReturnType<typeof toLink>>();
    for (const r of db.query(`SELECT * FROM links WHERE ${VISIBLE} ORDER BY added_at DESC`).all(me) as LinkRow[]) {
      links.set(r.id, toLink(r));
    }
    for (const r of db.query("SELECT * FROM seen").all() as { link_id: number; person: string; seen_at: number }[]) {
      const link = links.get(r.link_id);
      if (link && !blocked.has(r.person)) link.seen[r.person] = r.seen_at;
    }
    for (const r of db.query("SELECT * FROM reactions").all() as { link_id: number; person: string; emoji: string }[]) {
      const link = links.get(r.link_id);
      if (link && !blocked.has(r.person)) link.reactions[r.person] = r.emoji;
    }
    // Blocked people stay in `users`, so the app can name them under Blocked People.
    const users = (db.query("SELECT * FROM users ORDER BY created_at").all() as UserRow[]).map(publicUser);
    return { me, users, links: [...links.values()], blocked: [...blocked] };
  }

  function toLink(r: LinkRow) {
    return {
      id: r.id, url: r.url, platform: r.platform, title: r.title, author: r.author, note: r.note,
      description: r.description, site_name: r.site_name,
      thumb: r.thumb_type ? `/thumbs/${r.id}${r.thumb_v ? `/${r.thumb_v}` : ""}` : null, thumb_w: r.thumb_w, thumb_h: r.thumb_h, meta: r.meta, added_by: r.added_by, added_at: r.added_at,
      seen: {} as Record<string, number>, reactions: {} as Record<string, string>,
    };
  }

  /** One link as `me` sees it (see getState). Callers check it's visible to them first. */
  function getLink(id: number, me: string) {
    const row = db.query("SELECT * FROM links WHERE id = ?").get(id) as LinkRow | null;
    if (!row) return null;
    const blocked = blockedBy(me);
    const link = toLink(row);
    for (const r of db.query("SELECT person, seen_at FROM seen WHERE link_id = ?").all(id) as { person: string; seen_at: number }[]) {
      if (!blocked.has(r.person)) link.seen[r.person] = r.seen_at;
    }
    for (const r of db.query("SELECT person, emoji FROM reactions WHERE link_id = ?").all(id) as { person: string; emoji: string }[]) {
      if (!blocked.has(r.person)) link.reactions[r.person] = r.emoji;
    }
    return link;
  }

  /**
   * A write on `me`'s behalf, if their account still exists. A request can outlive it: DELETE /api/me
   * (or `links-server delete-user`) can land while it awaits its body or a short link, and rows
   * written after that would stay under the deleted id instead of going with the account.
   */
  function asUser<T>(me: string, write: () => T): T {
    return db.transaction(() => {
      if (!db.query("SELECT 1 FROM users WHERE id = ?").get(me)) throw new AuthError("Sign in to continue.");
      return write();
    }).immediate();
  }

  async function addLink(text: unknown, note: unknown, by: string) {
    const raw = extractUrl(text);
    if (!raw) throw new BadRequest("That doesn't look like a link.");
    const cleanNote = clipText(note, 500);
    accounts.screen(cleanNote, "note");
    const { url, platform } = await canonical(raw, fetchOpts);
    if (!new URL(url).hostname) throw new BadRequest("That doesn't look like a link.");
    const existing = db.query("SELECT id FROM links WHERE url = ?").get(url) as { id: number } | null;
    if (existing) {
      // Hidden for them (reported, or from someone they blocked): don't hand it back.
      if (!isVisible(existing.id, by)) throw new BadRequest("That link was already shared.");
      return { link: getLink(existing.id, by)!, duplicate: true };
    }
    const { lastInsertRowid } = asUser(by, () => db.run(
      "INSERT INTO links (url, platform, note, added_by, added_at) VALUES (?, ?, ?, ?, ?)",
      [url, platform, cleanNote, by, now()],
    ));
    const id = Number(lastInsertRowid);
    const preview = startMetadataFetch(id, url, platform);
    // Wait (briefly) for the preview, so the notification can show the link's title.
    if (push.enabled) track(Promise.race([preview, Bun.sleep(opts.previewWaitMs ?? 5000)]).then(() => push.newLink(id)));
    return { link: getLink(id, by)!, duplicate: false };
  }

  /** The link in the path, if `me` can see it; a hidden one is a 404, as if it were gone. */
  function linkId(req: Request & { params: { id: string } }, me: string): number {
    if (!/^\d+$/.test(req.params.id)) throw new NotFound("Not found");
    const id = Number(req.params.id);
    if (!isVisible(id, me)) throw new NotFound("That link was deleted.");
    return id;
  }

  const sender = (id: number) => (db.query("SELECT added_by FROM links WHERE id = ?").get(id) as { added_by: string }).added_by;

  /** A report snapshot: what was reported as it was, since it can be edited or deleted later. */
  function reportTarget(data: Record<string, any>, me: string) {
    const given = (["link_id", "comment_id", "user_id"] as const).filter((k) => data[k] !== undefined && data[k] !== null);
    if (given.length !== 1) throw new BadRequest("Report one link or one person.");
    if (given[0] === "link_id") {
      const id = data.link_id;
      const row = Number.isSafeInteger(id) ? db.query("SELECT * FROM links WHERE id = ?").get(id) as LinkRow | null : null;
      if (!row) throw new NotFound("That link was deleted.");
      if (row.added_by === me) throw new BadRequest("That's your own link. Delete it instead.");
      const from = db.query("SELECT name, email FROM users WHERE id = ?").get(row.added_by) as { name: string; email: string | null } | null;
      return {
        link_id: row.id as number, user_id: null, label: `link ${row.id}`,
        snapshot: { url: row.url, title: row.title, author: row.author, note: row.note, sender: row.added_by,
                    sender_name: from?.name ?? null, sender_email: from?.email ?? null },
      };
    }
    if (given[0] === "user_id") {
      const id = String(data.user_id);
      if (id === me) throw new BadRequest("You can't report yourself.");
      const user = db.query("SELECT * FROM users WHERE id = ?").get(id) as UserRow | null;
      if (!user) throw new NotFound("That person isn't in Links anymore.");
      return {
        link_id: null, user_id: id, label: `person ${id}`,
        snapshot: { name: user.name, avatar: user.avatar, email: user.email },
      };
    }
    throw new NotFound("That comment was deleted."); // comments arrive with #6
  }

  type Handler<R extends Request> = (req: R, me: string) => Response | Promise<Response>;

  /** Wrap a route: map errors to JSON, log, and (unless public) require a session. */
  function route<R extends Request>(handler: Handler<R>, opts: { public?: boolean } = {}) {
    return async (req: R): Promise<Response> => {
      let res: Response;
      try {
        const me = accounts.sessionUser(bearer(req));
        if (!me && !opts.public) {
          res = json({ error: "Sign in to continue." }, 401);
        } else {
          res = await handler(req, me ?? "");
        }
      } catch (e) {
        if (e instanceof AuthError) res = json({ error: e.message }, e.status);
        else if (e instanceof BadRequest) res = json({ error: e.message }, 400);
        else if (e instanceof NotFound) res = json({ error: e.message }, 404);
        else {
          console.error(`error handling ${req.method} ${new URL(req.url).pathname}:`, e);
          res = json({ error: "Something went wrong." }, 500);
        }
      }
      const path = new URL(req.url).pathname;
      if (config.logRequests && path !== "/api/state") console.log(`${req.method} ${path} ${res.status}`);
      return res;
    };
  }

  const pub = { public: true };
  type WithId = Request & { params: { id: string } };

  const routes = {
    "/": new Response("Links API. Open the Links app to use it.\n", { headers: { "Content-Type": "text/plain; charset=utf-8" } }),
    "/healthz": new Response("ok\n"),
    // What's deployed: the nightly check compares `commit` with origin/main.
    "/version": Response.json({ commit: BUILD_COMMIT }),

    // -- sign-in (AuthKit authorization code + PKCE)
    // 1. The app opens /auth/authorize in ASWebAuthenticationSession with its PKCE challenge.
    "/auth/authorize": {
      GET: route((req) => {
        const q = new URL(req.url).searchParams;
        return redirect(accounts.authorizeUrl(q.get("code_challenge") ?? "", q.get("state") ?? "", q.get("screen_hint")));
      }, pub),
    },
    // 2. AuthKit redirects here (an https URL WorkOS accepts in production); bounce the code to
    //    the app's URL scheme, which ASWebAuthenticationSession is listening for.
    "/auth/callback": {
      GET: route((req) => redirect(`${config.appScheme}://auth/callback${new URL(req.url).search}`), pub),
    },
    // 3. The app sends the code and its PKCE verifier; we exchange them and start a session.
    "/api/auth/token": {
      POST: route(async (req) => {
        const data = await readJson(req);
        return json(await accounts.signIn(String(data.code ?? ""), String(data.code_verifier ?? ""),
                                          req.headers.get("user-agent") ?? ""));
      }, pub),
    },
    "/api/auth/logout": {
      POST: route((req) => {
        accounts.endSession(bearer(req)!);
        return json({ ok: true });
      }),
    },

    // The app's APNs token for this session. Signing out (which ends the session) removes it, and
    // registering it again (another account signing in on that phone) moves it.
    "/api/devices": {
      POST: route(async (req, me) => {
        const data = await readJson(req);
        const token = typeof data.token === "string" ? data.token.trim().toLowerCase() : "";
        if (!/^[0-9a-f]{16,400}$/.test(token) || token.length % 2) throw new BadRequest("That isn't a device token.");
        if (data.env !== "sandbox" && data.env !== "production") throw new BadRequest("env must be sandbox or production.");
        const session = accounts.sessionHash(bearer(req)!);
        const t = now();
        asUser(me, () => db.run(
          `INSERT INTO device_tokens (token, user_id, session_hash, env, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)
             ON CONFLICT (token) DO UPDATE SET user_id = excluded.user_id, session_hash = excluded.session_hash,
               env = excluded.env, updated_at = excluded.updated_at`,
          [token, me, session, data.env, t, t],
        ));
        // `push`: whether this server sends any, so the app knows it can poll less often.
        return json({ ok: true, push: push.enabled });
      }),
    },
    "/api/devices/:token": {
      DELETE: route<Request & { params: { token: string } }>((req, me) => {
        db.run("DELETE FROM device_tokens WHERE token = ? AND user_id = ?", [decodeURIComponent(req.params.token).toLowerCase(), me]);
        return json({ ok: true });
      }),
    },

    "/api/me": {
      GET: route((_req, me) => json(accounts.mePayload(me))),
      PATCH: route(async (req, me) => {
        const { name } = await readJson(req);
        return json(asUser(me, () => {
          accounts.rename(me, name);
          return accounts.mePayload(me);
        }));
      }),
      // Delete the account and the links it sent, with their notes (see Accounts.deleteUser).
      DELETE: route(async (_req, me) => {
        await accounts.deleteUser(me);
        return json({ ok: true });
      }),
    },
    "/api/me/claim": {
      POST: route(async (req, me) => {
        const id = String((await readJson(req)).id ?? "");
        return json(asUser(me, () => {
          accounts.claimLegacy(me, id);
          // Their links leave your To Watch, and blocks of them now hide your links too.
          const blockers = db.query("SELECT blocker FROM blocks WHERE blocked = ?").all(me) as { blocker: string }[];
          push.badges([me, ...blockers.map((b) => b.blocker)]);
          return accounts.mePayload(me);
        }));
      }),
    },

    "/support": new Response(supportPage(config.supportEmail), { headers: { "Content-Type": "text/html; charset=utf-8" } }),
    "/privacy": new Response(privacyPage(config.supportEmail, config.sessionDays), { headers: { "Content-Type": "text/html; charset=utf-8" } }),

    "/api/state": { GET: route((_req, me) => json(getState(me))) },

    // Report a link or a person. It's hidden for the reporter at once; the owner reads reports
    // with `links-server reports` (and in the log).
    "/api/reports": {
      POST: route(async (req, me) => {
        const data = await readJson(req);
        if (!REPORT_REASONS.includes(data.reason)) throw new BadRequest("Pick a reason for the report.");
        const details = clipText(data.details, 1000);
        const { id, label } = asUser(me, () => {
          const target = reportTarget(data, me);
          const { changes, lastInsertRowid } = db.run(
            "INSERT OR IGNORE INTO reports (reporter, link_id, user_id, reason, details, snapshot, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [me, target.link_id, target.user_id, data.reason, details, JSON.stringify(target.snapshot), now()],
          );
          return { id: changes ? Number(lastInsertRowid) : null, label: target.label };
        });
        if (id !== null) {
          console.log(`report ${id}: ${data.reason}, ${label}, by ${me}`);
          push.badges([me]); // a reported link leaves To Watch
        }
        return json({ ok: true }, 201);
      }),
    },

    // One-way: the blocker stops seeing the blocked person's links, marks and reactions. The
    // blocked person isn't told, and sees no change.
    "/api/blocks": {
      POST: route(async (req, me) => {
        const id = String((await readJson(req)).user_id ?? "");
        if (id === me) throw new BadRequest("You can't block yourself.");
        asUser(me, () => {
          if (!db.query("SELECT 1 FROM users WHERE id = ?").get(id)) throw new NotFound("That person isn't in Links anymore.");
          db.run("INSERT OR IGNORE INTO blocks (blocker, blocked, created_at) VALUES (?, ?, ?)", [me, id, now()]);
        });
        push.badges([me]);
        return json({ blocked: [...blockedBy(me)] });
      }),
    },
    // The id is URL-encoded (legacy ones look like legacy:<name>); Bun has already decoded the param.
    "/api/blocks/:user_id": {
      DELETE: route<Request & { params: { user_id: string } }>((req, me) => {
        db.run("DELETE FROM blocks WHERE blocker = ? AND blocked = ?", [me, req.params.user_id]);
        push.badges([me]);
        return json({ blocked: [...blockedBy(me)] });
      }),
    },

    "/api/links": {
      POST: route(async (req, me) => {
        const data = await readJson(req);
        const { link, duplicate } = await addLink(data.url ?? data.text, data.note, me);
        return json({ link, duplicate }, duplicate ? 200 : 201);
      }),
    },
    "/api/links/:id": {
      // Only the sender writes a link's note, so nobody someone blocked can put words under it.
      PATCH: route<WithId>(async (req, me) => {
        const id = linkId(req, me);
        const note = clipText((await readJson(req)).note, 500);
        if (sender(id) !== me) throw new AuthError("Only the person who sent a link can change its note.", 403);
        accounts.screen(note, "note");
        db.run("UPDATE links SET note = ? WHERE id = ?", [note, id]);
        return json({ link: getLink(id, me) });
      }),
      DELETE: route<WithId>((req, me) => {
        const id = linkId(req, me);
        if (hasBlocked(sender(id), me)) throw new AuthError("You can't delete this link.", 403);
        const badgesChange = push.enabled ? push.unwatchedBy(id) : [];
        deleteLink(db, config.dataDir, id);
        push.badges(badgesChange);
        return json({ ok: true });
      }),
    },
    "/api/links/:id/refresh": {
      POST: route<WithId>((req, me) => {
        const id = linkId(req, me);
        const row = db.query("SELECT * FROM links WHERE id = ?").get(id) as LinkRow;
        if (row.meta !== "pending") {
          db.run("UPDATE links SET meta = 'pending' WHERE id = ?", [id]);
          startMetadataFetch(id, row.url, row.platform);
        }
        return json({ link: getLink(id, me) });
      }),
    },
    "/api/links/:id/seen": {
      POST: route<WithId>(async (req, me) => {
        const id = linkId(req, me);
        const seen = (await readJson(req)).seen ?? true;
        asUser(me, () => {
          if (seen) {
            db.run("INSERT OR IGNORE INTO seen (link_id, person, seen_at) VALUES (?, ?, ?)", [id, me, now()]);
          } else {
            db.run("DELETE FROM seen WHERE link_id = ? AND person = ?", [id, me]);
          }
        });
        push.badges([me]);
        return json({ link: getLink(id, me) });
      }),
    },
    "/api/links/:id/react": {
      POST: route<WithId>(async (req, me) => {
        const id = linkId(req, me);
        const emoji = (await readJson(req)).emoji;
        const changed = asUser(me, () => {
          if (typeof emoji === "string" && EMOJIS.has(emoji)) {
            const before = db.query("SELECT emoji FROM reactions WHERE link_id = ? AND person = ?").get(id, me) as { emoji: string } | null;
            db.run("INSERT OR REPLACE INTO reactions (link_id, person, emoji) VALUES (?, ?, ?)", [id, me, emoji]);
            return before?.emoji !== emoji;
          }
          db.run("DELETE FROM reactions WHERE link_id = ? AND person = ?", [id, me]);
          return false;
        });
        if (changed && push.enabled) track(push.reaction(id, me, emoji));
        return json({ link: getLink(id, me) });
      }),
    },

    "/thumbs/:id": { GET: route<WithId>(serveThumb) },
    // The version only changes the URL, so phones re-download a replaced thumbnail.
    "/thumbs/:id/:v": { GET: route<WithId>(serveThumb) },
  };

  function serveThumb(req: WithId, me: string) {
    const id = linkId(req, me);
    const row = db.query("SELECT thumb_type FROM links WHERE id = ?").get(id) as { thumb_type: string | null };
    const file = Bun.file(join(config.dataDir, "thumbs", String(id)));
    if (!row.thumb_type) throw new NotFound("Not found");
    return file.exists().then((exists) => {
      if (!exists) throw new NotFound("Not found");
      return new Response(file, { headers: { "Content-Type": row.thumb_type!, "Cache-Control": "private, max-age=2592000" } });
    });
  }

  return {
    db,
    accounts,
    routes,
    push,
    /** Resolves once in-flight preview fetches and pushes finish (tests use this). */
    idle: async () => { while (pending.size) await Promise.all([...pending]); },
    fallback: route(() => { throw new NotFound("Not found"); }, pub),
  };
}

export function startServer(config: Config, opts: AppOptions = {}) {
  const app = createApp(config, opts);
  const server = Bun.serve({
    port: config.port,
    hostname: config.hostname,
    maxRequestBodySize: 65536,
    routes: app.routes,
    fetch: app.fallback,
  });
  return { app, server };
}
