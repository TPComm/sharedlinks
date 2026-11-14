import type { Database } from "bun:sqlite";
import { rmSync } from "node:fs";
import { join } from "node:path";
import { Accounts, AuthError, publicUser } from "./accounts.ts";
import type { Config } from "./config.ts";
import { now, openDatabase, type LinkRow, type UserRow } from "./db.ts";
import { BadRequest, canonical, clipText, extractUrl } from "./links.ts";
import { fetchMetadata, PREVIEW_VERSION } from "./previews.ts";

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

function bearer(req: Request): string | null {
  const auth = req.headers.get("authorization") ?? "";
  return auth.slice(0, 7).toLowerCase() === "bearer " ? auth.slice(7).trim() || null : null;
}

export function createApp(config: Config) {
  const db = openDatabase(config.dataDir);
  const accounts = new Accounts(db, config);
  const fetchOpts = { allowPrivateNetwork: config.allowPrivateNetwork };
  const pending = new Set<Promise<void>>();

  // One fetch per link at a time (a retry during the backfill, an edit mid-fetch): the next waits its turn.
  const latest = new Map<number, Promise<void>>();
  function queueFetch(id: number, url: string, platform: string): Promise<void> {
    const run = (latest.get(id) ?? Promise.resolve()).then(() => fetchMetadata(db, config.dataDir, id, url, platform, fetchOpts));
    const settled = run.catch(() => {});
    latest.set(id, settled);
    void settled.then(() => { if (latest.get(id) === settled) latest.delete(id); });
    return run;
  }

  function startMetadataFetch(id: number, url: string, platform: string) {
    const task = queueFetch(id, url, platform)
      .catch((e) => console.error(`metadata ${id}: ${e}`))
      .finally(() => pending.delete(task));
    pending.add(task);
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

  function getState(me: string | null) {
    const links = new Map<number, ReturnType<typeof toLink>>();
    for (const r of db.query("SELECT * FROM links ORDER BY added_at DESC").all() as LinkRow[]) links.set(r.id, toLink(r));
    for (const r of db.query("SELECT * FROM seen").all() as { link_id: number; person: string; seen_at: number }[]) {
      const link = links.get(r.link_id);
      if (link) link.seen[r.person] = r.seen_at;
    }
    for (const r of db.query("SELECT * FROM reactions").all() as { link_id: number; person: string; emoji: string }[]) {
      const link = links.get(r.link_id);
      if (link) link.reactions[r.person] = r.emoji;
    }
    const users = (db.query("SELECT * FROM users ORDER BY created_at").all() as UserRow[]).map(publicUser);
    return { me, users, links: [...links.values()] };
  }

  function toLink(r: LinkRow) {
    return {
      id: r.id, url: r.url, platform: r.platform, title: r.title, author: r.author, note: r.note,
      description: r.description, site_name: r.site_name,
      thumb: r.thumb_type ? `/thumbs/${r.id}${r.thumb_v ? `?v=${r.thumb_v}` : ""}` : null, thumb_w: r.thumb_w, thumb_h: r.thumb_h, meta: r.meta, added_by: r.added_by, added_at: r.added_at,
      seen: {} as Record<string, number>, reactions: {} as Record<string, string>,
    };
  }

  function getLink(id: number) {
    const row = db.query("SELECT * FROM links WHERE id = ?").get(id) as LinkRow | null;
    if (!row) return null;
    const link = toLink(row);
    for (const r of db.query("SELECT person, seen_at FROM seen WHERE link_id = ?").all(id) as { person: string; seen_at: number }[]) {
      link.seen[r.person] = r.seen_at;
    }
    for (const r of db.query("SELECT person, emoji FROM reactions WHERE link_id = ?").all(id) as { person: string; emoji: string }[]) {
      link.reactions[r.person] = r.emoji;
    }
    return link;
  }

  async function addLink(text: unknown, note: unknown, by: string) {
    const raw = extractUrl(text);
    if (!raw) throw new BadRequest("That doesn't look like a link.");
    const { url, platform } = await canonical(raw, fetchOpts);
    if (!new URL(url).hostname) throw new BadRequest("That doesn't look like a link.");
    const existing = db.query("SELECT id FROM links WHERE url = ?").get(url) as { id: number } | null;
    if (existing) return { link: getLink(existing.id)!, duplicate: true };
    const { lastInsertRowid } = db.run(
      "INSERT INTO links (url, platform, note, added_by, added_at) VALUES (?, ?, ?, ?, ?)",
      [url, platform, clipText(note, 500), by, now()],
    );
    const id = Number(lastInsertRowid);
    startMetadataFetch(id, url, platform);
    return { link: getLink(id)!, duplicate: false };
  }

  function linkId(req: Request & { params: { id: string } }): number {
    if (!/^\d+$/.test(req.params.id)) throw new NotFound("Not found");
    const id = Number(req.params.id);
    if (!db.query("SELECT 1 FROM links WHERE id = ?").get(id)) throw new NotFound("That link was deleted.");
    return id;
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

    "/api/me": {
      GET: route((_req, me) => json(accounts.mePayload(me))),
      PATCH: route(async (req, me) => {
        accounts.rename(me, (await readJson(req)).name);
        return json(accounts.mePayload(me));
      }),
      // Delete the account. The links it sent stay, from "Deleted user" (see Accounts.deleteUser).
      DELETE: route(async (_req, me) => {
        await accounts.deleteUser(me);
        return json({ ok: true });
      }),
    },
    "/api/me/claim": {
      POST: route(async (req, me) => {
        accounts.claimLegacy(me, String((await readJson(req)).id ?? ""));
        return json(accounts.mePayload(me));
      }),
    },

    "/api/state": { GET: route((_req, me) => json(getState(me))) },

    "/api/links": {
      POST: route(async (req, me) => {
        const data = await readJson(req);
        const { link, duplicate } = await addLink(data.url ?? data.text, data.note, me);
        return json({ link, duplicate }, duplicate ? 200 : 201);
      }),
    },
    "/api/links/:id": {
      PATCH: route<WithId>(async (req) => {
        const id = linkId(req);
        db.run("UPDATE links SET note = ? WHERE id = ?", [clipText((await readJson(req)).note, 500), id]);
        return json({ link: getLink(id) });
      }),
      DELETE: route<WithId>((req) => {
        const id = linkId(req);
        db.run("DELETE FROM links WHERE id = ?", [id]);
        rmSync(join(config.dataDir, "thumbs", String(id)), { force: true });
        return json({ ok: true });
      }),
    },
    "/api/links/:id/refresh": {
      POST: route<WithId>((req) => {
        const id = linkId(req);
        const row = db.query("SELECT * FROM links WHERE id = ?").get(id) as LinkRow;
        if (row.meta !== "pending") {
          db.run("UPDATE links SET meta = 'pending' WHERE id = ?", [id]);
          startMetadataFetch(id, row.url, row.platform);
        }
        return json({ link: getLink(id) });
      }),
    },
    "/api/links/:id/seen": {
      POST: route<WithId>(async (req, me) => {
        const id = linkId(req);
        if ((await readJson(req)).seen ?? true) {
          db.run("INSERT OR IGNORE INTO seen (link_id, person, seen_at) VALUES (?, ?, ?)", [id, me, now()]);
        } else {
          db.run("DELETE FROM seen WHERE link_id = ? AND person = ?", [id, me]);
        }
        return json({ link: getLink(id) });
      }),
    },
    "/api/links/:id/react": {
      POST: route<WithId>(async (req, me) => {
        const id = linkId(req);
        const emoji = (await readJson(req)).emoji;
        if (typeof emoji === "string" && EMOJIS.has(emoji)) {
          db.run("INSERT OR REPLACE INTO reactions (link_id, person, emoji) VALUES (?, ?, ?)", [id, me, emoji]);
        } else {
          db.run("DELETE FROM reactions WHERE link_id = ? AND person = ?", [id, me]);
        }
        return json({ link: getLink(id) });
      }),
    },

    "/thumbs/:id": {
      GET: route<WithId>((req) => {
        const id = linkId(req);
        const row = db.query("SELECT thumb_type FROM links WHERE id = ?").get(id) as { thumb_type: string | null };
        const file = Bun.file(join(config.dataDir, "thumbs", String(id)));
        if (!row.thumb_type) throw new NotFound("Not found");
        return file.exists().then((exists) => {
          if (!exists) throw new NotFound("Not found");
          return new Response(file, { headers: { "Content-Type": row.thumb_type!, "Cache-Control": "private, max-age=2592000" } });
        });
      }),
    },
  };

  return {
    db,
    accounts,
    routes,
    /** Resolves once in-flight preview fetches finish (tests use this). */
    idle: () => Promise.all([...pending]).then(() => {}),
    fallback: route(() => { throw new NotFound("Not found"); }, pub),
  };
}

export function startServer(config: Config) {
  const app = createApp(config);
  const server = Bun.serve({
    port: config.port,
    hostname: config.hostname,
    maxRequestBodySize: 65536,
    routes: app.routes,
    fetch: app.fallback,
  });
  return { app, server };
}
