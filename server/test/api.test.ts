import { Database } from "bun:sqlite";
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../src/app.ts";
import { configFromEnv } from "../src/config.ts";
import { canonical, expandShortLink, extractUrl, platformOf } from "../src/links.ts";
import { BlockedAddressError, isPrivateAddress, safeFetch } from "../src/net.ts";
import { decodeEntities, ogTags, PREVIEW_VERSION, previewFromTags } from "../src/previews.ts";
import { openDatabase } from "../src/db.ts";

// 1x1 PNG
const PNG = Uint8Array.from(atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="), (c) => c.charCodeAt(0));
const VERIFIER = "v".repeat(43);

const dataDir = mkdtempSync(join(tmpdir(), "links-test-"));
let api: string;
let origin: string;
let stop: () => void;
let idle: () => Promise<void>;
let mint: (email: string, name: string) => string;
let baseConfig: ReturnType<typeof configFromEnv>;
let flakyUp = false;
const workosRequests: Record<string, any>[] = [];

/** A stand-in for api.workos.com. Codes: good / stranger / unverified. */
const fakeWorkOS = Bun.serve({
  port: 0,
  routes: {
    "/user_management/authenticate": {
      POST: async (req) => {
        const body = await req.json() as Record<string, any>;
        workosRequests.push(body);
        if (body.code_verifier !== VERIFIER) {
          return Response.json({ error: "invalid_grant", error_description: "Invalid code verifier." }, { status: 400 });
        }
        const users: Record<string, object> = {
          good: { id: "user_01FRIEND", email: "friend@example.com", email_verified: true, first_name: "Riley", profile_picture_url: "https://example.com/r.png" },
          domain: { id: "user_01TEAM", email: "jane.doe@team.test", email_verified: true, first_name: "", profile_picture_url: null },
          stranger: { id: "user_01STRANGER", email: "stranger@evil.test", email_verified: true },
          unverified: { id: "user_01UNVERIFIED", email: "friend2@team.test", email_verified: false },
          rude: { id: "user_01RUDE", email: "rude.person@team.test", email_verified: true, first_name: "Zonk" },
          blocker: { id: "user_01BLOCKER", email: "blocker@team.test", email_verified: true, first_name: "Bea" },
          // No invite yet: they get in with one from someone who's in.
          nova: { id: "user_01NOVA", email: "nova@else.test", email_verified: true, first_name: "Nova" },
          sol: { id: "user_01SOL", email: "Sol@Else.test", email_verified: true, first_name: "Sol" },
          kit: { id: "user_01KIT", email: "kit@else.test", email_verified: true, first_name: "Kit" },
          pip: { id: "user_01PIP", email: "pip@else.test", email_verified: true, first_name: "Pip" },
          lee: { id: "user_01LEE", email: "lee@else.test", email_verified: true, first_name: "Lee" },
          unverifiedGuest: { id: "user_01UNVGUEST", email: "unv@else.test", email_verified: false },
        };
        const user = users[body.code];
        if (!user) return Response.json({ error: "invalid_grant", error_description: "Invalid authorization code." }, { status: 400 });
        return Response.json({ user, access_token: "jwt", refresh_token: "refresh" });
      },
    },
  },
});

/** A web page with Open Graph tags and a thumbnail. */
const fakeOrigin = Bun.serve({
  port: 0,
  routes: {
    "/video": new Response(
      `<html><head><title>Fallback</title><meta property="og:title" content="Cats &amp; Dogs"><meta property="og:site_name" content="PetTube"><meta property="og:description" content="Two pets"><meta property="og:image" content="/thumb.png"></head></html>`,
      { headers: { "Content-Type": "text/html" } }),
    "/plain": new Response("<html><head><title> Just a &quot;page&quot; </title></head></html>", { headers: { "Content-Type": "text/html" } }),
    // Fails until flakyUp, then has a title.
    "/flaky": () => (flakyUp ? new Response("<title>Back up</title>", { headers: { "Content-Type": "text/html" } })
                             : new Response("down", { status: 503 })),
    "/thumb.png": new Response(PNG, { headers: { "Content-Type": "image/png" } }),
    // Stand-ins for TikTok short links: a live code, and a dead one (TikTok sends those home).
    "/t/live": Response.redirect(`https://www.tiktok.com/@/video/7506136711311772958?_r=1&_d=abc&u_code=def&share_item_id=7506136711311772958&utm_campaign=client_share&utm_source=short_fallback`, 302),
    "/t/dead": Response.redirect("https://www.tiktok.com/?_r=1", 302),
  },
});

beforeAll(() => {
  // Start from a v0 database (people identified by typed names) to exercise the migration.
  const legacy = new Database(join(dataDir, "links.db"), { create: true });
  legacy.exec(`
    CREATE TABLE people (name TEXT PRIMARY KEY COLLATE NOCASE, created_at REAL NOT NULL);
    CREATE TABLE links (id INTEGER PRIMARY KEY, url TEXT NOT NULL UNIQUE, platform TEXT NOT NULL, title TEXT, author TEXT, thumb_type TEXT, meta TEXT NOT NULL DEFAULT 'pending', note TEXT NOT NULL DEFAULT '', added_by TEXT NOT NULL, added_at REAL NOT NULL);
    CREATE TABLE seen (link_id INTEGER NOT NULL REFERENCES links(id) ON DELETE CASCADE, person TEXT NOT NULL, seen_at REAL NOT NULL, PRIMARY KEY (link_id, person));
    CREATE TABLE reactions (link_id INTEGER NOT NULL REFERENCES links(id) ON DELETE CASCADE, person TEXT NOT NULL, emoji TEXT NOT NULL, PRIMARY KEY (link_id, person));
    INSERT INTO people VALUES ('Sam', 1), ('Alex', 2);
    INSERT INTO links (url, platform, title, meta, added_by, added_at) VALUES ('https://www.youtube.com/watch?v=old', 'youtube', 'Old one', 'done', 'Sam', 10);
    INSERT INTO links (url, platform, title, meta, added_by, added_at) VALUES ('https://de.wikipedia.org/wiki/München', 'web', 'München', 'done', 'Alex', 9);
    INSERT INTO links (url, platform, title, meta, added_by, added_at) VALUES ('https://www.tiktok.com/@old_handle/video/7506136711311772958', 'tiktok', 'A TikTok', 'done', 'Sam', 8);
    INSERT INTO seen VALUES (1, 'Alex', 11);
    INSERT INTO reactions VALUES (1, 'Alex', '🔥');
  `);
  legacy.close();
  // The owner's own additions to the moderation word list.
  writeFileSync(join(dataDir, "blocked-words.txt"), "# extra words\nzonk\n");

  const config = {
    ...configFromEnv({}),
    port: 0,
    hostname: "127.0.0.1",
    dataDir,
    publicUrl: "https://links.example.com",
    workosClientId: "client_TEST",
    workosApi: fakeWorkOS.url.origin,
    allowPrivateNetwork: true,
    logRequests: false,
    previewBackfillMs: 0,
    appleAppIds: ["ABCDE12345.com.yourname.links"],
  };
  baseConfig = config;
  const { app, server } = startServer(config);
  // Invites are the only way in: these people were sent one (by the admin, `links-server invite`).
  for (const email of ["friend@example.com", "jane.doe@team.test", "rude.person@team.test", "blocker@team.test", "friend2@team.test"]) {
    app.accounts.createInvite(null, email);
  }
  api = server.url.origin;
  origin = fakeOrigin.url.origin;
  idle = app.idle;
  mint = (email, name) => app.accounts.mintSession(email, name);
  stop = () => server.stop(true);
});

afterAll(() => {
  stop();
  fakeWorkOS.stop(true);
  fakeOrigin.stop(true);
  rmSync(dataDir, { recursive: true, force: true });
});

async function call(path: string, opts: { method?: string; token?: string; body?: unknown } = {}) {
  const res = await fetch(api + path, {
    method: opts.method ?? (opts.body ? "POST" : "GET"),
    redirect: "manual",
    headers: {
      ...(opts.token ? { Authorization: `Bearer ${opts.token}` } : {}),
      ...(opts.body ? { "Content-Type": "application/json" } : {}),
    },
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  const text = await res.text();
  let data: any = text;
  try { data = JSON.parse(text); } catch {}
  return { status: res.status, data, headers: res.headers };
}

const signIn = (code: string, verifier = VERIFIER, invite?: string) =>
  call("/api/auth/token", { body: { code, code_verifier: verifier, ...(invite ? { invite } : {}) } });

describe("auth", () => {
  test("everything but sign-in needs a session", async () => {
    for (const path of ["/api/state", "/api/me", "/thumbs/1"]) {
      expect((await call(path)).status).toBe(401);
    }
    expect((await call("/api/state", { token: "nope" })).status).toBe(401);
    expect((await call("/api/links", { body: { url: "https://x.com/a" } })).status).toBe(401);
  });

  test("authorize forwards the PKCE challenge to AuthKit", async () => {
    const challenge = "c".repeat(43);
    const res = await call(`/auth/authorize?code_challenge=${challenge}&state=abc&screen_hint=sign-up`);
    expect(res.status).toBe(302);
    const location = new URL(res.headers.get("location")!);
    expect(location.origin + location.pathname).toBe(`${fakeWorkOS.url.origin}/user_management/authorize`);
    expect(Object.fromEntries(location.searchParams)).toEqual({
      client_id: "client_TEST", response_type: "code", provider: "authkit",
      redirect_uri: "https://links.example.com/auth/callback", code_challenge: challenge,
      code_challenge_method: "S256", state: "abc", screen_hint: "sign-up",
    });
    expect((await call("/auth/authorize?code_challenge=short&state=x")).status).toBe(400);
  });

  test("callback bounces the code to the app's URL scheme", async () => {
    const res = await call("/auth/callback?code=abc&state=xyz");
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("sharedlinks://auth/callback?code=abc&state=xyz");
  });

  test("code exchange: invite-only, verification, PKCE", async () => {
    const stranger = await signIn("stranger");
    expect(stranger.status).toBe(403);
    expect(stranger.data.token).toBeUndefined();
    expect((await signIn("unverified")).data.error).toContain("Verify");
    const bad = await signIn("good", "w".repeat(43));
    expect(bad.status).toBe(400); // not 401, which the app would read as "signed out"
    expect(bad.data.error).toBe("Invalid code verifier.");

    const ok = await signIn("good");
    expect(ok.status).toBe(200);
    expect(ok.data.token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(ok.data.user).toEqual({ id: "user_01FRIEND", name: "Riley", avatar: "https://example.com/r.png", email: "friend@example.com" });
    expect(ok.data.claimable.map((u: any) => u.name)).toEqual(["Sam", "Alex"]);
    expect(workosRequests.at(-1)).toMatchObject({ client_id: "client_TEST", grant_type: "authorization_code", code: "good" });
    expect(workosRequests.at(-1)!.client_secret).toBeUndefined();

    const domain = await signIn("domain");
    expect(domain.data.user.name).toBe("Jane Doe"); // from the email when there's no first name
  });
});

describe("invites", () => {
  const tokenOf = (url: string) => url.split("/invite/")[1]!;
  let me: string;
  let novaToken = "";
  const nova = () => novaToken;
  beforeAll(async () => { me = (await signIn("good")).data.token; });

  test("make one, share its page, use it once", async () => {
    expect((await call("/api/invites", { body: {} })).status).toBe(401);
    const made = await call("/api/invites", { token: me, body: {} });
    expect(made.status).toBe(201);
    expect(made.data.invite.url).toMatch(/^https:\/\/links\.example\.com\/invite\/[A-Za-z0-9_-]{43}$/);
    expect(made.data.invite.email).toBeNull();
    const token = tokenOf(made.data.invite.url);
    expect(made.data.invite.expires_at - made.data.invite.created_at).toBe(7 * 86400);

    const listed = await call("/api/invites", { token: me });
    expect(listed.data.invites.map((i: any) => i.id)).toContain(made.data.invite.id);
    expect(JSON.stringify(listed.data)).not.toContain(token);

    // Link previews and page loads don't use it up.
    for (let i = 0; i < 2; i++) {
      const page = await call(`/invite/${token}`);
      expect(page.status).toBe(200);
      expect(page.headers.get("content-type")).toContain("text/html");
      expect(page.data).toContain('<meta property="og:title" content="Riley invited you to Links">');
      expect(page.data).toContain(`href="sharedlinks://invite/${token}"`);
      expect(page.data).not.toContain("apple-itunes-app"); // no App Store ID set
    }
    expect((await call("/icon.png")).headers.get("content-type")).toBe("image/png");

    expect((await signIn("nova")).data.error).toBe("Links is invite-only. Ask a friend who uses it to invite you, then tap their invite link.");
    const nova = await signIn("nova", VERIFIER, token);
    expect(nova.status).toBe(200);
    novaToken = nova.data.token;
    // A member now: in, and still in on the next sign-in without a link.
    expect((await call("/api/state", { token: nova.data.token })).status).toBe(200);
    expect((await signIn("nova")).status).toBe(200);
    const state = await call("/api/state", { token: me });
    expect(state.data.users.map((u: any) => u.name)).toContain("Nova");

    // Single use.
    expect((await signIn("kit", VERIFIER, token)).status).toBe(403);
    expect((await call(`/invite/${token}`)).status).toBe(404);
    expect((await call(`/invite/${token}`)).data).toContain("doesn&#39;t work anymore");
    expect((await call("/api/invites", { token: me })).data.invites.map((i: any) => i.id)).not.toContain(made.data.invite.id);
    expect((await call("/invite/not-a-token")).status).toBe(404);
  });

  test("an invite to an email lets that verified email in without the link", async () => {
    expect((await call("/api/invites", { token: me, body: { email: "nope" } })).status).toBe(400);
    const made = await call("/api/invites", { token: me, body: { email: " sol@else.TEST " } });
    expect(made.data.invite.email).toBe("sol@else.test");
    // Someone else holding the link can't use an invite meant for Sol.
    expect((await signIn("kit", VERIFIER, tokenOf(made.data.invite.url))).status).toBe(403);
    const sol = await signIn("sol");
    expect(sol.status).toBe(200);
    expect((await call("/api/state", { token: sol.data.token })).status).toBe(200);

    await call("/api/invites", { token: me, body: { email: "unv@else.test" } });
    expect((await signIn("unverifiedGuest")).status).toBe(403);
  });

  test("someone who isn't a member can't read or write anything, even with a session", async () => {
    const db = new Database(join(dataDir, "links.db"));
    db.run("INSERT INTO users (id, email, name, created_at) VALUES ('user_01OUTSIDER', 'out@else.test', 'Outsider', 1)");
    const outsider = "o".repeat(43);
    db.run("INSERT INTO sessions VALUES (?, 'user_01OUTSIDER', ?, ?)",
      [new Bun.CryptoHasher("sha256").update(outsider).digest("hex"), Date.now() / 1000, Date.now() / 1000]);
    const linkId = (db.query("SELECT id FROM links ORDER BY id LIMIT 1").get() as { id: number }).id;
    db.close();
    for (const [method, path, body] of [
      ["GET", "/api/state"], ["GET", "/api/me"], ["GET", "/api/invites"], ["POST", "/api/invites", {}],
      ["POST", "/api/links", { url: `${origin}/plain?n=outsider` }], ["POST", `/api/links/${linkId}/seen`, { seen: true }],
      ["GET", `/thumbs/${linkId}`], ["POST", "/api/blocks", { user_id: "user_01FRIEND" }], ["POST", "/api/reports", { link_id: linkId, reason: "spam" }],
    ] as [string, string, object?][]) {
      expect((await call(path, { method, token: outsider, body })).status, `${method} ${path}`).toBe(401);
    }
  });

  test("an admin's invite (links-server invite) has a page with no inviter, and lets its holder in", async () => {
    const db = new Database(join(dataDir, "links.db"));
    const token = "a".repeat(43);
    db.run("INSERT INTO invites (token_hash, invited_by, created_at, expires_at) VALUES (?, NULL, ?, ?)",
      [new Bun.CryptoHasher("sha256").update(token).digest("hex"), Date.now() / 1000, Date.now() / 1000 + 86400]);
    db.close();
    const page = await call(`/invite/${token}`);
    expect(page.status).toBe(200);
    expect(page.data).toContain("<title>You&#39;re invited to Links</title>");
    expect(page.data).toContain("If the invite was sent to your email address");
    expect((await signIn("pip", VERIFIER, token)).status).toBe(200);
  });

  test("revoked and expired invites stop working", async () => {
    const made = await call("/api/invites", { token: me, body: {} });
    const { id } = made.data.invite;
    expect((await call(`/api/invites/${id}`, { method: "DELETE", token: nova() })).status).toBe(404); // not theirs
    const revoked = await call(`/api/invites/${id}`, { method: "DELETE", token: me });
    expect(revoked.status).toBe(200);
    expect(revoked.data.invites.map((i: any) => i.id)).not.toContain(id);
    expect((await call(`/api/invites/${id}`, { method: "DELETE", token: me })).status).toBe(404);
    expect((await call(`/invite/${tokenOf(made.data.invite.url)}`)).status).toBe(404);
    expect((await signIn("kit", VERIFIER, tokenOf(made.data.invite.url))).status).toBe(403);

    const old = await call("/api/invites", { token: me, body: {} });
    const db = new Database(join(dataDir, "links.db"));
    db.run("UPDATE invites SET expires_at = ? WHERE id = ?", [Date.now() / 1000 - 1, old.data.invite.id]);
    db.close();
    expect((await call(`/invite/${tokenOf(old.data.invite.url)}`)).status).toBe(404);
    expect((await signIn("kit", VERIFIER, tokenOf(old.data.invite.url))).status).toBe(403);
    expect((await call("/api/invites", { token: me })).data.invites.map((i: any) => i.id)).not.toContain(old.data.invite.id);
  });

});

describe("links", () => {
  let token: string;
  let friendId: string;
  beforeAll(async () => {
    const res = await signIn("good");
    token = res.data.token;
    friendId = res.data.user.id;
  });

  test("migrations: AUTOINCREMENT ids and today's URL spelling", async () => {
    const db = new Database(join(dataDir, "links.db"), { readonly: true });
    const { sql } = db.query("SELECT sql FROM sqlite_master WHERE name = 'links'").get() as { sql: string };
    expect(sql).toContain("AUTOINCREMENT");
    expect((db.query("PRAGMA user_version").get() as any).user_version).toBe(9);
    db.close();
    const { data } = await call("/api/state", { token });
    expect(data.links.map((l: any) => l.url)).toContain("https://de.wikipedia.org/wiki/M%C3%BCnchen");
    // Sharing it again now finds the migrated row instead of adding a second one.
    const again = await call("/api/links", { token, body: { url: "https://de.wikipedia.org/wiki/München" } });
    expect(again.data.duplicate).toBe(true);
    // TikTok posts are stored by id, so the same video shared with another handle is a duplicate.
    expect(data.links.map((l: any) => l.url)).toContain("https://www.tiktok.com/@/video/7506136711311772958");
    const tiktok = await call("/api/links", { token, body: { url: "https://www.tiktok.com/@new_handle/video/7506136711311772958?_r=1&_t=ZS-abc" } });
    expect(tiktok.data.duplicate).toBe(true);
  });

  test("deleted ids are never reused", async () => {
    const a = await call("/api/links", { token, body: { url: `${origin}/plain?n=1` } });
    await call(`/api/links/${a.data.link.id}`, { method: "DELETE", token });
    const b = await call("/api/links", { token, body: { url: `${origin}/plain?n=2` } });
    expect(b.data.link.id).toBeGreaterThan(a.data.link.id);
    await idle();
  });

  test("links iOS couldn't parse are refused", async () => {
    // A local host, so the preview fetch this starts stays offline.
    const braces = await call("/api/links", { token, body: { url: `see {${origin}}` } });
    expect(braces.status).toBe(201); // the brace is message punctuation, not part of the link
    expect(braces.data.link.url).toBe(`${origin}/`);
    expect((await call("/api/links", { token, body: { url: "https://exa{mple.com/x" } })).status).toBe(400);
    await idle();
  });

  test("migrated history is there under legacy people", async () => {
    const { data } = await call("/api/state", { token });
    expect(data.me).toBe(friendId);
    const old = data.links.find((l: any) => l.id === 1);
    expect(old.added_by).toBe("legacy:Sam");
    expect(old.seen).toEqual({ "legacy:Alex": 11 });
    expect(old.reactions).toEqual({ "legacy:Alex": "🔥" });
  });

  test("add pulls the link out of text, fetches a preview and thumbnail", async () => {
    const add = await call("/api/links", { token, body: { url: `lol look ${origin}/video?utm_source=x&id=7 !!`, note: "  for you  " } });
    expect(add.status).toBe(201);
    expect(add.data.duplicate).toBe(false);
    expect(add.data.link).toMatchObject({ url: `${origin}/video?id=7`, platform: "web", meta: "pending", note: "for you", added_by: friendId });
    await idle();
    const { data } = await call("/api/state", { token });
    const link = data.links.find((l: any) => l.id === add.data.link.id);
    expect(link).toMatchObject({
      title: "Cats & Dogs", author: "PetTube", meta: "done", thumb: `/thumbs/${link.id}/1`,
      description: "Two pets", site_name: "PetTube", thumb_w: 1, thumb_h: 1,
    });

    const thumb = await fetch(api + link.thumb, { headers: { Authorization: `Bearer ${token}` } });
    expect(thumb.status).toBe(200);
    expect(thumb.headers.get("content-type")).toBe("image/png");
    expect(new Uint8Array(await thumb.arrayBuffer())).toEqual(PNG);
    expect((await fetch(api + link.thumb)).status).toBe(401);
    // Apps from before versioned thumbnail URLs still get the image at the plain URL.
    expect((await fetch(`${api}/thumbs/${link.id}`, { headers: { Authorization: `Bearer ${token}` } })).status).toBe(200);
    expect((await fetch(`${api}/thumbs/${link.id}/x`, { headers: { Authorization: `Bearer ${token}` } })).status).toBe(200);

    const dup = await call("/api/links", { token, body: { url: `${origin}/video/?id=7&fbclid=zzz` } });
    expect(dup.status).toBe(200);
    expect(dup.data).toMatchObject({ duplicate: true, link: { id: link.id } });

    const plain = await call("/api/links", { token, body: { text: `${origin}/plain` } });
    await idle();
    const plainLink = (await call("/api/state", { token })).data.links.find((l: any) => l.id === plain.data.link.id);
    expect(plainLink).toMatchObject({ title: 'Just a "page"', thumb: null, meta: "done" });

    expect((await call("/api/links", { token, body: { url: "no link here" } })).status).toBe(400);
  });

  test("refresh re-fetches a failed preview", async () => {
    const add = await call("/api/links", { token, body: { url: `${origin}/flaky` } });
    await idle();
    const id = add.data.link.id;
    expect((await call("/api/state", { token })).data.links.find((l: any) => l.id === id)).toMatchObject({ meta: "failed", title: null });
    flakyUp = true;
    const r = await call(`/api/links/${id}/refresh`, { token, body: {} });
    expect(r.status).toBe(200);
    expect(r.data.link).toMatchObject({ id, meta: "pending" });
    await idle();
    expect((await call("/api/state", { token })).data.links.find((l: any) => l.id === id)).toMatchObject({ meta: "done", title: "Back up" });
    expect((await call("/api/links/99999/refresh", { token, body: {} })).status).toBe(404);
    expect((await call(`/api/links/${id}/refresh`, { body: {} })).status).toBe(401);
  });

  test("seen, reactions, notes, delete", async () => {
    let r = await call("/api/links/1/seen", { token, body: { seen: true } });
    expect(Object.keys(r.data.link.seen).sort()).toEqual([friendId, "legacy:Alex"].sort());
    r = await call("/api/links/1/seen", { token, body: { seen: false } });
    expect(Object.keys(r.data.link.seen)).toEqual(["legacy:Alex"]);
    r = await call("/api/links/1/react", { token, body: { emoji: "😂" } });
    expect(r.data.link.reactions[friendId]).toBe("😂");
    r = await call("/api/links/1/react", { token, body: { emoji: "💩" } }); // not allowed -> removes
    expect(r.data.link.reactions[friendId]).toBeUndefined();
    // Notes are the sender's: link 1 is Sam's (still unclaimed).
    r = await call("/api/links/1", { method: "PATCH", token, body: { note: "mine now" } });
    expect(r.status).toBe(403);
    const own = (await call("/api/links", { token, body: { url: `${origin}/plain?n=note` } })).data.link;
    r = await call(`/api/links/${own.id}`, { method: "PATCH", token, body: { note: "x".repeat(600) } });
    expect(r.data.link.note.length).toBe(500);
    await idle();
    expect((await call("/api/links/999/seen", { token, body: {} })).status).toBe(404);
    expect((await call("/api/links/abc", { method: "DELETE", token })).status).toBe(404);
    const invalid = await fetch(`${api}/api/links/1`, {
      method: "PATCH", body: "{", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    });
    expect(invalid.status).toBe(400);
  });

  test("claiming a legacy person moves their history", async () => {
    const r = await call("/api/me/claim", { token, body: { id: "legacy:Sam" } });
    expect(r.status).toBe(200);
    expect(r.data.user.name).toBe("Sam");
    expect(r.data.claimable.map((u: any) => u.id)).toEqual(["legacy:Alex"]);
    expect((await call("/api/me/claim", { token, body: { id: "legacy:Sam" } })).status).toBe(400);
    const { data } = await call("/api/state", { token });
    expect(data.links.find((l: any) => l.id === 1).added_by).toBe(friendId);
    expect(data.users.some((u: any) => u.id === "legacy:Sam")).toBe(false);

    const renamed = await call("/api/me", { method: "PATCH", token, body: { name: "  Sammy   J  " } });
    expect(renamed.data.user.name).toBe("Sammy J");
    expect((await call("/api/me", { method: "PATCH", token, body: { name: "  " } })).status).toBe(400);
  });

  test("delete removes the link and its thumbnail", async () => {
    const { data } = await call("/api/state", { token });
    const withThumb = data.links.find((l: any) => l.thumb);
    expect((await call(`/api/links/${withThumb.id}`, { method: "DELETE", token })).data).toEqual({ ok: true });
    expect((await call(withThumb.thumb, { token })).status).toBe(404);
  });

  test("logout ends the session", async () => {
    const { data } = await signIn("good");
    expect((await call("/api/auth/logout", { method: "POST", token: data.token })).data).toEqual({ ok: true });
    expect((await call("/api/me", { token: data.token })).status).toBe(401);
    expect((await call("/api/me", { token })).status).toBe(200); // other sessions unaffected
  });
});

describe("reports, blocks and the word list", () => {
  // Riley sends; Bea reports and blocks. Jane is the bystander who still sees everything.
  let riley: { id: string; token: string };
  let bea: { id: string; token: string };
  let jane: { id: string; token: string };
  beforeAll(async () => {
    const who = async (code: string) => {
      const { data } = await signIn(code);
      return { id: data.user.id as string, token: data.token as string };
    };
    [riley, bea, jane] = [await who("good"), await who("blocker"), await who("domain")];
  });
  const state = async (t: { token: string }) => (await call("/api/state", { token: t.token })).data;
  const send = async (n: string) =>
    (await call("/api/links", { token: riley.token, body: { url: `${origin}/video?id=${n}`, note: n } })).data.link;

  test("a report hides the link for the reporter only; reporting it again is a no-op", async () => {
    const link = await send("reported");
    await idle();
    const report = { link_id: link.id, reason: "offensive", details: "not nice" };
    const logged: string[] = [];
    const log = console.log;
    console.log = (line: string) => logged.push(line);
    try {
      expect((await call("/api/reports", { token: bea.token, body: report })).status).toBe(201);
      expect((await call("/api/reports", { token: bea.token, body: { ...report, reason: "spam" } })).status).toBe(201);
    } finally {
      console.log = log;
    }
    expect(logged).toEqual([expect.stringMatching(new RegExp(`^report \\d+: offensive, link ${link.id}, by ${bea.id}$`))]);

    expect((await state(bea)).links.some((l: any) => l.id === link.id)).toBe(false);
    for (const [path, body] of [[`/api/links/${link.id}/seen`, { seen: true }], [`/api/links/${link.id}/react`, { emoji: "🔥" }]] as const) {
      expect((await call(path, { token: bea.token, body })).status).toBe(404);
    }
    expect((await call(`/thumbs/${link.id}/1`, { token: bea.token })).status).toBe(404);
    expect((await call(`/api/links/${link.id}`, { method: "DELETE", token: bea.token })).status).toBe(404);
    // Sharing it again doesn't hand it back.
    const again = await call("/api/links", { token: bea.token, body: { url: `${origin}/video?id=reported` } });
    expect(again).toMatchObject({ status: 400, data: { error: "That link was already shared." } });

    for (const t of [riley, jane]) expect((await state(t)).links.some((l: any) => l.id === link.id)).toBe(true);
    expect((await call(`/thumbs/${link.id}/1`, { token: jane.token })).status).toBe(200);

    const db = new Database(join(dataDir, "links.db"), { readonly: true });
    try {
      const rows = db.query("SELECT * FROM reports WHERE link_id = ?").all(link.id) as any[];
      expect(rows).toHaveLength(1);
      expect(rows[0]).toMatchObject({ reporter: bea.id, reason: "offensive", details: "not nice", resolved_at: null });
      expect(JSON.parse(rows[0].snapshot)).toMatchObject({ url: link.url, note: "reported", sender: riley.id });
    } finally {
      db.close();
    }
  });

  test("bad reports", async () => {
    const link = await send("bad-reports");
    const report = (body: object, t = bea) => call("/api/reports", { token: t.token, body });
    expect((await report({ link_id: link.id, reason: "offensive" }, riley)).status).toBe(400); // own link
    expect((await report({ user_id: bea.id, reason: "spam" })).status).toBe(400);              // yourself
    expect((await report({ link_id: link.id, reason: "boring" })).status).toBe(400);
    expect((await report({ link_id: link.id })).status).toBe(400);
    expect((await report({ reason: "spam" })).status).toBe(400);
    expect((await report({ link_id: link.id, user_id: riley.id, reason: "spam" })).status).toBe(400);
    expect((await report({ link_id: 99999, reason: "spam" })).status).toBe(404);
    expect((await report({ link_id: "1", reason: "spam" })).status).toBe(404);
    expect((await report({ user_id: "user_NOBODY", reason: "spam" })).status).toBe(404);
    expect((await report({ comment_id: 1, reason: "spam" })).status).toBe(404);
    expect((await report({ user_id: riley.id, reason: "harassment" })).status).toBe(201);
    expect((await call("/api/reports", { body: { link_id: link.id, reason: "spam" } })).status).toBe(401);
    // Reporting a person hides nothing by itself.
    expect((await state(bea)).links.some((l: any) => l.id === link.id)).toBe(true);
    await call(`/api/links/${link.id}`, { method: "DELETE", token: riley.token });
    await idle();
  });

  test("a block hides their links, marks and reactions for the blocker only, until unblocked", async () => {
    const rileys = await send("blocked");
    const beas = (await call("/api/links", { token: bea.token, body: { url: `${origin}/plain?n=beas` } })).data.link;
    for (const t of [riley, jane]) {
      await call(`/api/links/${beas.id}/seen`, { token: t.token, body: { seen: true } });
      await call(`/api/links/${beas.id}/react`, { token: t.token, body: { emoji: "😂" } });
    }
    await idle();

    expect((await call("/api/blocks", { token: bea.token, body: { user_id: riley.id } })).data).toEqual({ blocked: [riley.id] });
    let mine = await state(bea);
    expect(mine.blocked).toEqual([riley.id]);
    expect(mine.users.some((u: any) => u.id === riley.id)).toBe(true); // to name under Blocked People
    expect(mine.links.some((l: any) => l.added_by === riley.id)).toBe(false);
    const seenByBea = mine.links.find((l: any) => l.id === beas.id);
    expect(Object.keys(seenByBea.seen)).toEqual([jane.id]);
    expect(seenByBea.reactions).toEqual({ [jane.id]: "😂" });
    // The link that seen and react hand back is filtered the same way.
    const reacted = await call(`/api/links/${beas.id}/react`, { token: bea.token, body: { emoji: "❤️" } });
    expect(reacted.data.link.reactions).toEqual({ [jane.id]: "😂", [bea.id]: "❤️" });
    const seen = await call(`/api/links/${beas.id}/seen`, { token: bea.token, body: { seen: true } });
    expect(Object.keys(seen.data.link.seen).sort()).toEqual([jane.id, bea.id].sort());
    expect((await call(`/api/links/${rileys.id}/seen`, { token: bea.token, body: { seen: true } })).status).toBe(404);

    // Nobody else sees a change, and Riley isn't told.
    const theirs = await state(riley);
    expect(theirs.blocked).toEqual([]);
    expect(theirs.links.find((l: any) => l.id === beas.id).reactions).toEqual({ [riley.id]: "😂", [jane.id]: "😂", [bea.id]: "❤️" });
    expect((await state(jane)).links.some((l: any) => l.id === rileys.id)).toBe(true);

    // Riley can't touch Bea's link any more.
    expect((await call(`/api/links/${beas.id}`, { method: "PATCH", token: riley.token, body: { note: "hi" } })).status).toBe(403);
    expect((await call(`/api/links/${beas.id}`, { method: "DELETE", token: riley.token })).status).toBe(403);
    expect((await call(`/api/links/${beas.id}`, { method: "PATCH", token: jane.token, body: { note: "hi" } })).status).toBe(403);

    expect((await call(`/api/blocks/${encodeURIComponent(riley.id)}`, { method: "DELETE", token: bea.token })).data).toEqual({ blocked: [] });
    mine = await state(bea);
    expect(mine.blocked).toEqual([]);
    expect(mine.links.some((l: any) => l.id === rileys.id)).toBe(true);
    expect(mine.links.find((l: any) => l.id === beas.id).reactions[riley.id]).toBe("😂");

    for (const [t, id] of [[riley, rileys.id], [bea, beas.id]] as const) {
      expect((await call(`/api/links/${id}`, { method: "DELETE", token: t.token })).status).toBe(200);
    }
  });

  test("blocks: yourself, unknown people, legacy ids in the path", async () => {
    expect((await call("/api/blocks", { token: bea.token, body: { user_id: bea.id } })).status).toBe(400);
    expect((await call("/api/blocks", { token: bea.token, body: { user_id: "user_NOBODY" } })).status).toBe(404);
    expect((await call("/api/blocks", { token: bea.token, body: { user_id: "legacy:Alex" } })).data).toEqual({ blocked: ["legacy:Alex"] });
    expect((await call("/api/blocks/legacy%3AAlex", { method: "DELETE", token: bea.token })).data).toEqual({ blocked: [] });
  });

  test("unblocking a legacy name with a % in it", async () => {
    const id = "legacy:100%";
    const db = new Database(join(dataDir, "links.db"));
    db.run("INSERT INTO users (id, name, created_at) VALUES (?, '100%', 1)", [id]);
    try {
      expect((await call("/api/blocks", { token: bea.token, body: { user_id: id } })).data).toEqual({ blocked: [id] });
      expect((await call(`/api/blocks/${encodeURIComponent(id)}`, { method: "DELETE", token: bea.token })).data).toEqual({ blocked: [] });
    } finally {
      db.run("DELETE FROM blocks WHERE blocked = ?", [id]);
      db.run("DELETE FROM users WHERE id = ?", [id]);
      db.close();
    }
  });

  test("a listed word in a note or a name is refused; a WorkOS name with one still signs in", async () => {
    const add = await call("/api/links", { token: riley.token, body: { url: `${origin}/plain?n=words`, note: "what a ZONK!" } });
    expect(add).toMatchObject({ status: 400, data: { error: expect.stringContaining("note") } });
    const link = (await call("/api/links", { token: riley.token, body: { url: `${origin}/plain?n=words`, note: "fine" } })).data.link;
    expect((await call(`/api/links/${link.id}`, { method: "PATCH", token: riley.token, body: { note: "zonks" } })).status).toBe(400);
    expect((await call(`/api/links/${link.id}`, { method: "PATCH", token: riley.token, body: { note: "Scunthonk" } })).status).toBe(200);
    expect((await call("/api/me", { method: "PATCH", token: riley.token, body: { name: "Mr Zonk" } })).status).toBe(400);
    await call(`/api/links/${link.id}`, { method: "DELETE", token: riley.token });

    const rude = await signIn("rude");
    expect(rude.status).toBe(200);
    expect(rude.data.user.name).toBe("Rude Person");
    await idle();
  });

  test("/support shows the contact address", async () => {
    const res = await call("/support");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
    expect(res.data).toContain("Links Support");
    expect(res.data).toContain('<a href="mailto:support@tpcomm.co">support@tpcomm.co</a>');
  });

  test("/privacy serves the privacy policy without signing in", async () => {
    const res = await call("/privacy");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
    expect(res.data).toContain("Links Privacy Policy");
    expect(res.data).toContain('<a href="mailto:support@tpcomm.co">support@tpcomm.co</a>');
    expect(res.data).toContain("Delete Account");
    expect(res.data).toContain("newest 14 days");
  });

  test("/version says which commit is running, without signing in", async () => {
    const res = await call("/version");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");
    expect(res.data).toEqual({ commit: "dev" });
  });
});

describe("group chats", () => {
  let ann: string, bo: string, cy: string;
  let annId: string, boId: string, cyId: string;
  const state = async (token: string, query = "") => (await call(`/api/state${query}`, { token })).data;
  beforeAll(async () => {
    [ann, bo, cy] = [mint("ann@groups.test", "Ann"), mint("bo@groups.test", "Bo"), mint("cy@groups.test", "Cy")];
    [annId, boId, cyId] = await Promise.all([ann, bo, cy].map(async (t) => (await state(t)).me));
  });

  test("everyone, and every link from before groups, is in the default chat", async () => {
    const data = await state(cy);
    expect(data.groups).toHaveLength(1);
    const [everyone] = data.groups;
    expect(everyone).toMatchObject({ default: true, name: "", created_by: null });
    expect(everyone.members).toEqual(expect.arrayContaining([annId, boId, cyId, "user_01FRIEND"]));
    expect(data.links.length).toBeGreaterThan(0);
    expect(data.links.every((l: any) => l.group_id === everyone.id)).toBe(true);
  });

  test("a chat's links are only for its members; the same link can be in two chats", async () => {
    const made = await call("/api/groups", { token: ann, body: { name: "  Ann  &  Bo ", members: [boId, annId, boId] } });
    expect(made.status).toBe(201);
    const chat = made.data.group;
    expect(chat).toMatchObject({ name: "Ann & Bo", created_by: annId, default: false });
    expect(chat.members.sort()).toEqual([annId, boId].sort());

    const url = `${origin}/plain?n=group-only`;
    const sent = await call("/api/links", { token: ann, body: { url, group_id: chat.id } });
    expect(sent.status).toBe(201);
    expect(sent.data.link.group_id).toBe(chat.id);
    expect((await state(bo)).links.map((l: any) => l.id)).toContain(sent.data.link.id);
    const cyView = await state(cy);
    expect(cyView.groups.map((g: any) => g.id)).not.toContain(chat.id);
    expect(cyView.links.map((l: any) => l.id)).not.toContain(sent.data.link.id);

    // Again in that chat is a duplicate; in the default chat (where an app from before groups sends) it's new.
    const again = await call("/api/links", { token: bo, body: { url, group_id: chat.id } });
    expect(again.data).toMatchObject({ duplicate: true, link: { id: sent.data.link.id } });
    const elsewhere = await call("/api/links", { token: cy, body: { url } });
    expect(elsewhere.status).toBe(201);
    expect(elsewhere.data.link.group_id).toBe(cyView.groups[0].id);
    expect(elsewhere.data.link.id).not.toBe(sent.data.link.id);

    // ?group_id= narrows the state to one chat.
    const one = await state(bo, `?group_id=${chat.id}`);
    expect(one.links.map((l: any) => l.id)).toEqual([sent.data.link.id]);
    expect((await call(`/api/state?group_id=${chat.id}`, { token: cy })).status).toBe(404);
    await idle();
  });

  test("nobody outside a chat can read, mark, react to, edit, refresh, report or delete its links", async () => {
    const chat = (await call("/api/groups", { token: ann, body: { members: [boId] } })).data.group;
    const link = (await call("/api/links", { token: ann, body: { url: `${origin}/video?id=group`, group_id: chat.id } })).data.link;
    await idle();
    const thumb = (await state(ann)).links.find((l: any) => l.id === link.id).thumb;
    expect((await fetch(api + thumb, { headers: { Authorization: `Bearer ${bo}` } })).status).toBe(200);
    const attempts = [
      call(`/api/links/${link.id}/seen`, { token: cy, body: { seen: true } }),
      call(`/api/links/${link.id}/react`, { token: cy, body: { emoji: "😂" } }),
      call(`/api/links/${link.id}`, { method: "PATCH", token: cy, body: { note: "mine" } }),
      call(`/api/links/${link.id}/refresh`, { token: cy, body: {} }),
      call("/api/reports", { token: cy, body: { link_id: link.id, reason: "spam" } }),
      call(`/api/links/${link.id}`, { method: "DELETE", token: cy }),
      call(thumb, { token: cy }),
      call(`/thumbs/${link.id}`, { token: cy }),
      call("/api/links", { token: cy, body: { url: `${origin}/plain?n=sneak`, group_id: chat.id } }),
      call(`/api/groups/${chat.id}`, { method: "PATCH", token: cy, body: { name: "mine" } }),
      call(`/api/groups/${chat.id}/members`, { token: cy, body: { members: [cyId] } }),
      call(`/api/groups/${chat.id}`, { method: "DELETE", token: cy }),
    ];
    expect((await Promise.all(attempts)).map((r) => r.status)).toEqual(attempts.map(() => 404));
    const after = (await state(ann)).links.find((l: any) => l.id === link.id);
    expect(after).toMatchObject({ note: "", seen: {}, reactions: {} });
    expect(after.thumb).toBe(thumb);
    expect((await state(ann)).groups.find((g: any) => g.id === chat.id).members).not.toContain(cyId);
  });

  test("members rename it and add people; leaving keeps your links there; the last one out deletes it", async () => {
    const chat = (await call("/api/groups", { token: ann, body: { name: "Trip", members: [boId] } })).data.group;
    const link = (await call("/api/links", { token: bo, body: { url: `${origin}/plain?n=trip`, group_id: chat.id } })).data.link;
    expect((await call(`/api/groups/${chat.id}`, { method: "PATCH", token: bo, body: { name: "Trip 2027" } })).data.group.name).toBe("Trip 2027");
    expect((await call(`/api/groups/${chat.id}/members`, { token: bo, body: { members: ["legacy:Sam"] } })).status).toBe(400);
    expect((await call(`/api/groups/${chat.id}/members`, { token: bo, body: { members: ["user_nobody"] } })).status).toBe(400);
    expect((await call(`/api/groups/${chat.id}/members`, { token: bo, body: { members: "x" } })).status).toBe(400);
    const added = await call(`/api/groups/${chat.id}/members`, { token: bo, body: { members: [cyId, annId] } });
    expect(added.data.group.members.sort()).toEqual([annId, boId, cyId].sort());
    expect((await state(cy)).links.map((l: any) => l.id)).toContain(link.id);

    expect((await call(`/api/groups/${chat.id}`, { method: "DELETE", token: bo })).status).toBe(200);
    expect((await state(bo)).links.map((l: any) => l.id)).not.toContain(link.id);
    expect((await call(`/api/links/${link.id}/seen`, { token: bo, body: {} })).status).toBe(404);
    expect((await state(cy)).links.find((l: any) => l.id === link.id)).toMatchObject({ added_by: boId });

    await call(`/api/groups/${chat.id}`, { method: "DELETE", token: ann });
    await call(`/api/groups/${chat.id}`, { method: "DELETE", token: cy });
    const db = new Database(join(dataDir, "links.db"), { readonly: true });
    expect(db.query("SELECT COUNT(*) AS n FROM groups WHERE id = ?").get(chat.id)).toEqual({ n: 0 });
    expect(db.query("SELECT COUNT(*) AS n FROM links WHERE id = ?").get(link.id)).toEqual({ n: 0 });
    db.close();
  });

  test("someone who leaves while a request uploads can't rename the chat, add people or touch its links", async () => {
    const chat = (await call("/api/groups", { token: ann, body: { name: "Before", members: [boId] } })).data.group;
    const slow = (method: string, path: string, body: object) => {
      let send!: () => void;
      const stream = new ReadableStream({
        start(controller) {
          send = () => { controller.enqueue(new TextEncoder().encode(JSON.stringify(body))); controller.close(); };
        },
      });
      const res = fetch(api + path, {
        method, body: stream, duplex: "half",
        headers: { Authorization: `Bearer ${bo}`, "Content-Type": "application/json" },
      } as RequestInit);
      return { send, res };
    };
    const link = (await call("/api/links", { token: bo, body: { url: `${origin}/plain?n=upload`, group_id: chat.id } })).data.link;
    const inFlight = [
      slow("PATCH", `/api/groups/${chat.id}`, { name: "Mine now" }),
      slow("POST", `/api/groups/${chat.id}/members`, { members: [cyId] }),
      slow("PATCH", `/api/links/${link.id}`, { note: "late" }),
      slow("POST", `/api/links/${link.id}/seen`, { seen: true }),
      slow("POST", `/api/links/${link.id}/react`, { emoji: "🔥" }),
    ];
    await Bun.sleep(50);
    expect((await call(`/api/groups/${chat.id}`, { method: "DELETE", token: bo })).status).toBe(200);
    for (const r of inFlight) r.send();
    expect(await Promise.all(inFlight.map(async (r) => (await r.res).status))).toEqual(inFlight.map(() => 404));
    const after = await state(ann);
    expect(after.groups.find((g: any) => g.id === chat.id)).toMatchObject({ name: "Before", members: [annId] });
    expect(after.links.find((l: any) => l.id === link.id)).toMatchObject({ note: "", seen: {}, reactions: {} });
    await idle();
  });

  test("a chat holds up to 50 people", async () => {
    const people = await Promise.all(Array.from({ length: 50 }, async (_, i) => (await state(mint(`many${i}@groups.test`, `Many ${i}`))).me));
    const full = await call("/api/groups", { token: ann, body: { members: people.slice(0, 49) } });
    expect(full.status).toBe(201);
    expect(full.data.group.members).toHaveLength(50);
    const more = await call(`/api/groups/${full.data.group.id}/members`, { token: ann, body: { members: [people[49]] } });
    expect(more).toMatchObject({ status: 400, data: { error: "A chat can have up to 50 people." } });
    expect((await call("/api/groups", { token: ann, body: { members: people } })).status).toBe(400);
  });

  test("people see only who they share a chat with; an invite brings them into the inviter's chat", async () => {
    const chat = (await call("/api/groups", { token: ann, body: { name: "Invited", members: [boId] } })).data.group;
    const sent = await call("/api/links", { token: bo, body: { url: `${origin}/plain?n=before-lee`, group_id: chat.id } });
    expect((await call("/api/invites", { token: cy, body: { group_id: chat.id } })).status).toBe(404); // not cy's chat
    const made = await call("/api/invites", { token: ann, body: { group_id: chat.id } });
    expect(made.status).toBe(201);
    expect(made.data.invite.group_id).toBe(chat.id);
    const lee = await signIn("lee", VERIFIER, made.data.invite.url.split("/invite/")[1]);
    expect(lee.status).toBe(200);

    // Lee is only in Ann's chat, not the default one, and sees only its people.
    const view = await state(lee.data.token);
    expect(view.groups.map((g: any) => g.id)).toEqual([chat.id]);
    expect(view.users.map((u: any) => u.id).sort()).toEqual([annId, boId, "user_01LEE"].sort());
    expect(view.links.map((l: any) => l.id)).toEqual([sent.data.link.id]);
    const cyView = await state(cy);
    expect(cyView.users.map((u: any) => u.id)).not.toContain("user_01LEE");
    expect(cyView.groups.find((g: any) => g.default).members).not.toContain("user_01LEE");

    // Someone Lee can't see can't be added to a chat or reported by Lee.
    expect((await call("/api/groups", { token: lee.data.token, body: { members: [cyId] } })).data.error)
      .toBe("Someone you picked isn't in Links anymore.");
    expect((await call("/api/reports", { token: lee.data.token, body: { user_id: cyId, reason: "spam" } })).status).toBe(404);

    // Someone who left is still named on what they sent there.
    expect((await call(`/api/groups/${chat.id}`, { method: "DELETE", token: bo })).status).toBe(200);
    expect((await state(lee.data.token)).users.map((u: any) => u.id)).toContain(boId);
  });

  test("an invite that names no chat starts one with just the inviter", async () => {
    const made = await call("/api/invites", { token: cy, body: {} });
    expect(made.data.invite.group_id).toBeNull();
    const kit = await signIn("kit", VERIFIER, made.data.invite.url.split("/invite/")[1]);
    expect(kit.status).toBe(200);
    const view = await state(kit.data.token);
    expect(view.groups).toHaveLength(1);
    expect(view.groups[0]).toMatchObject({ default: false, name: "", created_by: cyId });
    expect(view.groups[0].members.sort()).toEqual([cyId, "user_01KIT"].sort());
    expect(view.users.map((u: any) => u.id).sort()).toEqual([cyId, "user_01KIT"].sort());
    expect((await state(cy)).groups.map((g: any) => g.id)).toContain(view.groups[0].id);
  });

  test("an app from before groups sends to the default chat, or the only chat left", async () => {
    const dee = mint("dee@groups.test", "Dee");
    const everyone = (await state(dee)).groups[0];
    const chat = (await call("/api/groups", { token: dee, body: { name: "Just me" } })).data.group;
    expect(chat.members).toEqual([(await state(dee)).me]);
    await call(`/api/groups/${everyone.id}`, { method: "DELETE", token: dee });
    const only = await call("/api/links", { token: dee, body: { url: `${origin}/plain?n=only` } });
    expect(only.data.link.group_id).toBe(chat.id);
    await call("/api/groups", { token: dee, body: { name: "Second" } });
    const none = await call("/api/links", { token: dee, body: { url: `${origin}/plain?n=which` } });
    expect(none).toMatchObject({ status: 400, data: { error: "Pick a chat to send it to." } });
    await idle();
  });
});

describe("universal links", () => {
  const AASA = "/.well-known/apple-app-site-association";

  test("the association file is public JSON for any User-Agent, with the excludes first", async () => {
    for (const agent of ["", "MyAgent-Bot/*", "AASA-Bot/1.0.0"]) {
      const res = await fetch(api + AASA, { redirect: "manual", headers: agent ? { "User-Agent": agent } : {} });
      expect(res.status).toBe(200);
      expect(res.headers.get("content-type")).toContain("application/json");
      const body = await res.json() as any;
      expect(body.webcredentials).toEqual({ apps: ["ABCDE12345.com.yourname.links"] });
      expect(body.applinks.details).toHaveLength(1);
      const [details] = body.applinks.details;
      expect(details.appIDs).toEqual(["ABCDE12345.com.yourname.links"]);
      expect(details.components.map((c: any) => [c["/"], c.exclude ?? false])).toEqual([
        ["/api/*", true], ["/auth/*", true], ["/thumbs/*", true],
        ["/l/*", false], ["/invite/*", false], ["/g/*", false],
      ]);
    }
  });

  test("without APPLE_APP_IDS there's no association file", async () => {
    const dir = mkdtempSync(join(tmpdir(), "links-aasa-"));
    const { server } = startServer({ ...baseConfig, appleAppIds: [], dataDir: dir });
    try {
      expect((await fetch(server.url.origin + AASA)).status).toBe(404);
    } finally {
      server.stop(true);
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test.each(["/l/x", "/g/x", "/l/AbC-_09", `/g/${"a".repeat(64)}`])("%p is a placeholder page", async (path) => {
    const res = await call(path);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
    expect(res.data).toContain("Open this in the Links app");
    expect(res.data).not.toContain("apple-itunes-app");
  });

  test.each(["/l/a.b", "/l/%3Cscript%3E", "/invite/a%20b", `/g/${"a".repeat(65)}`, "/l/", "/l/x/y"])("%p is a 404", async (path) => {
    expect((await call(path)).status).toBe(404);
  });

  test("the pages show no inbox data, even to someone signed in", async () => {
    const riley = await signIn("good");
    const res = await call("/l/x", { token: riley.data.token });
    expect(res.data).not.toContain("Riley");
    expect(res.data).not.toContain("friend@example.com");
  });

  test("with APP_STORE_ID, the pages have a Smart App Banner pointing back at themselves", async () => {
    const dir = mkdtempSync(join(tmpdir(), "links-banner-"));
    const { server } = startServer({ ...baseConfig, appStoreId: "6700000000", dataDir: dir });
    try {
      const html = await (await fetch(server.url.origin + "/l/tok_1")).text();
      expect(html).toContain('<meta name="apple-itunes-app" content="app-id=6700000000, app-argument=https://links.example.com/l/tok_1">');
      expect(html).toContain("https://apps.apple.com/app/id6700000000");
    } finally {
      server.stop(true);
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("deleting an account", () => {
  test("removes the person, every session, their marks and reactions, and the links they sent", async () => {
    const jane = await signIn("domain");
    const otherPhone = await signIn("domain");
    const friend = await signIn("good");
    const [janeId, token, friendId, friendToken] = [jane.data.user.id, jane.data.token, friend.data.user.id, friend.data.token];

    // Jane sends a link with a thumbnail and marks it watched; the friend watches it and reacts.
    const sent = (await call("/api/links", { token, body: { url: `${origin}/video?id=jane`, note: "from jane" } })).data.link;
    await call(`/api/links/${sent.id}/seen`, { token, body: { seen: true } });
    await call(`/api/links/${sent.id}/seen`, { token: friendToken, body: { seen: true } });
    await call(`/api/links/${sent.id}/react`, { token: friendToken, body: { emoji: "🔥" } });
    // The friend sends one, which they both watch and react to.
    const friends = (await call("/api/links", { token: friendToken, body: { url: `${origin}/plain?n=kept` } })).data.link;
    for (const [t, emoji] of [[token, "😂"], [friendToken, "❤️"]]) {
      await call(`/api/links/${friends.id}/seen`, { token: t, body: { seen: true } });
      await call(`/api/links/${friends.id}/react`, { token: t, body: { emoji } });
    }
    await idle();
    expect(existsSync(join(dataDir, "thumbs", String(sent.id)))).toBe(true);

    expect((await call("/api/me", { method: "DELETE", token })).data).toEqual({ ok: true });

    // Every session is gone, with the 401 the app reads as "signed out".
    for (const t of [token, otherPhone.data.token]) {
      expect((await call("/api/me", { token: t })).status).toBe(401);
      expect((await call("/api/state", { token: t })).status).toBe(401);
      expect((await call("/api/me", { method: "DELETE", token: t })).status).toBe(401);
    }
    const db = new Database(join(dataDir, "links.db"), { readonly: true });
    try {
      for (const where of ["users WHERE id = ?", "sessions WHERE user_id = ?", "seen WHERE person = ?",
                           "reactions WHERE person = ?", "links WHERE added_by = ?"]) {
        expect(db.query(`SELECT COUNT(*) AS n FROM ${where}`).get(janeId), where).toEqual({ n: 0 });
      }
      expect(db.query("SELECT 1 FROM users WHERE id = 'deleted'").get()).toBeNull();
      expect(db.query("SELECT COUNT(*) AS n FROM seen WHERE link_id = ?").get(sent.id)).toEqual({ n: 0 });
    } finally {
      db.close();
    }

    // Her link goes for the friend too, with its note, thumbnail and the friend's marks on it.
    const { data } = await call("/api/state", { token: friendToken });
    expect(data.users.map((u: any) => u.id)).not.toContain(janeId);
    expect(data.users.map((u: any) => u.id)).not.toContain("deleted");
    expect(data.links.find((l: any) => l.id === sent.id)).toBeUndefined();
    expect(existsSync(join(dataDir, "thumbs", String(sent.id)))).toBe(false);
    expect((await call(`/thumbs/${sent.id}/1`, { token: friendToken })).status).toBe(404);
    // The friend's own link keeps the friend's marks, not hers.
    const theirs = data.links.find((l: any) => l.id === friends.id);
    expect(Object.keys(theirs.seen)).toEqual([friendId]);
    expect(theirs.reactions).toEqual({ [friendId]: "❤️" });

    // Deleting ends her membership: back in only with a new invite (same WorkOS id, same email), as
    // a new, empty account. Her old links don't come back.
    expect((await signIn("domain")).status).toBe(403);
    await call("/api/invites", { token: friendToken, body: { email: "jane.doe@team.test" } });
    const again = await signIn("domain");
    expect(again.status).toBe(200);
    expect(again.data.user).toMatchObject({ id: janeId, name: "Jane Doe", email: "jane.doe@team.test" });
    const after = (await call("/api/state", { token: again.data.token })).data;
    expect(after.links.find((l: any) => l.id === sent.id)).toBeUndefined();
    expect(after.links.some((l: any) => l.added_by === janeId || l.seen[janeId] || l.reactions[janeId])).toBe(false);
  });

  test("a request still in flight when the account goes writes nothing for it", async () => {
    const jane = await signIn("domain");
    const friend = await signIn("good");
    const [janeId, token] = [jane.data.user.id, jane.data.token];
    const shared = (await call("/api/state", { token })).data.groups.find((g: any) => g.members.includes(friend.data.user.id));
    const link = (await call("/api/links", { token: friend.data.token, body: { url: `${origin}/plain?n=inflight`, group_id: shared.id } })).data.link;

    // Each request sends its headers (and passes the session check), then waits for its body.
    const slow = (method: string, path: string, body: unknown) => {
      let send!: () => void;
      const sent = new Promise<void>((resolve) => (send = resolve));
      const stream = new ReadableStream({
        async start(controller) {
          await sent;
          controller.enqueue(new TextEncoder().encode(JSON.stringify(body)));
          controller.close();
        },
      });
      const res = fetch(api + path, {
        method, body: stream, duplex: "half",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      } as RequestInit);
      return { send, res };
    };
    const inFlight = [
      slow("POST", "/api/links", { url: `${origin}/plain?n=late` }),
      slow("POST", `/api/links/${link.id}/seen`, { seen: true }),
      slow("POST", `/api/links/${link.id}/react`, { emoji: "🔥" }),
      slow("PATCH", "/api/me", { name: "Late Name" }),
    ];
    await Bun.sleep(50);
    expect((await call("/api/me", { method: "DELETE", token })).status).toBe(200);
    for (const r of inFlight) r.send();
    // The 401 the app reads as "signed out", and no rows left under the deleted id.
    expect(await Promise.all(inFlight.map(async (r) => (await r.res).status))).toEqual([401, 401, 401, 401]);
    await idle();

    const db = new Database(join(dataDir, "links.db"), { readonly: true });
    try {
      for (const where of ["users WHERE id = ?", "seen WHERE person = ?", "reactions WHERE person = ?", "links WHERE added_by = ?"]) {
        expect(db.query(`SELECT COUNT(*) AS n FROM ${where}`).get(janeId), where).toEqual({ n: 0 });
      }
      expect(db.query("SELECT 1 FROM links WHERE url LIKE ?").get("%n=late")).toBeNull();
    } finally {
      db.close();
    }
  });
});

describe("helpers", () => {
  test("extractUrl", () => {
    expect(extractUrl("lol look https://vm.tiktok.com/ZMabc/ 😂")).toBe("https://vm.tiktok.com/ZMabc/");
    expect(extractUrl("www.instagram.com/reel/xyz).")).toBe("https://www.instagram.com/reel/xyz");
    expect(extractUrl("nothing")).toBeNull();
  });

  test("paths are spelled so iOS keeps them byte for byte", async () => {
    expect((await canonical("https://example.com/café|menu")).url).toBe("https://example.com/caf%C3%A9%7Cmenu");
    expect((await canonical("https://example.com/a[1]b")).url).toBe("https://example.com/a%5B1%5Db");
    expect((await canonical("https://example.com/100%")).url).toBe("https://example.com/100%25");
    expect((await canonical("https://example.com/x%7Cy")).url).toBe("https://example.com/x%7Cy");
  });

  test("short-link expansion only for the real domains", async () => {
    // eviltiktok.com/t/... is not TikTok: no redirect lookup, kept as a plain web link.
    expect(await canonical("https://eviltiktok.com/t/abc")).toEqual({ url: "https://eviltiktok.com/t/abc", platform: "web" });
    expect(platformOf("eviltiktok.com")).toBe("web");
  });

  test("TikTok: one spelling per post, with no tracking", async () => {
    const want = { url: "https://www.tiktok.com/@/video/7506136711311772958", platform: "tiktok" };
    for (const raw of [
      "https://www.tiktok.com/@someone/video/7506136711311772958?_r=1&_t=ZS-92jrA0wKM6y",
      "https://www.tiktok.com/@someone/video/7506136711311772958?is_from_webapp=1&sender_device=pc&web_id=123",
      "https://tiktok.com/@/video/7506136711311772958/",
      "https://www.tiktok.com/@someone/photo/7506136711311772958",
      "https://m.tiktok.com/v/7506136711311772958.html?u_code=x",
      "https://www.tiktok.com/share/video/7506136711311772958",
      "https://www.tiktok.com/embed/v2/7506136711311772958",
    ]) expect(await canonical(raw)).toEqual(want);
    // Not a post: kept as is, without the query.
    expect(await canonical("https://www.tiktok.com/@someone?_t=x&_r=1")).toEqual({ url: "https://www.tiktok.com/@someone", platform: "tiktok" });
  });

  test("short links stop at the post, and dead TikTok codes are refused", async () => {
    // The post itself is never fetched (www.tiktok.com is out of reach in tests anyway).
    const live = await expandShortLink(`${origin}/t/live`, { allowPrivateNetwork: true });
    expect(live.searchParams.get("share_item_id")).toBe("7506136711311772958");
    expect(await canonical(live.href)).toEqual({ url: "https://www.tiktok.com/@/video/7506136711311772958", platform: "tiktok" });
    await expect(expandShortLink(`${origin}/t/dead`, { allowPrivateNetwork: true })).rejects.toThrow("expired");
  });

  test("hostile pages parse in linear time", () => {
    const big = 2_000_000;
    for (const page of [
      "<html><head><meta " + "a".repeat(big) + ">",
      "<meta ".repeat(big / 6),
      "<title>".repeat(big / 7),
      'a="'.repeat(big / 3),
    ]) {
      const t = performance.now();
      ogTags(page);
      expect(performance.now() - t).toBeLessThan(1000);
    }
  });

  test("canonical forms (no network)", async () => {
    expect(await canonical("https://instagram.com/someone/reel/ABC/?igsh=1")).toEqual({ url: "https://www.instagram.com/reel/ABC", platform: "instagram" });
    expect(await canonical("https://m.youtube.com/watch?v=1&si=2&t=3")).toEqual({ url: "https://www.youtube.com/watch?v=1&t=3", platform: "youtube" });
    expect(await canonical("http://Example.com:8080/a/b/?utm_medium=x")).toEqual({ url: "http://example.com:8080/a/b", platform: "web" });
    expect(platformOf("old.reddit.com")).toBe("reddit");
  });

  test("private addresses are refused", async () => {
    for (const ip of ["127.0.0.1", "10.1.2.3", "169.254.169.254", "192.168.0.1", "172.20.0.1", "100.64.0.1", "::1", "fe80::1", "fd00::1", "::ffff:127.0.0.1", "::ffff:7f00:1", "0.0.0.0"]) {
      expect(isPrivateAddress(ip)).toBe(true);
    }
    for (const ip of ["93.184.215.14", "1.1.1.1", "2606:4700:4700::1111", "172.32.0.1"]) {
      expect(isPrivateAddress(ip)).toBe(false);
    }
    await expect(safeFetch(`${origin}/video`)).rejects.toBeInstanceOf(BlockedAddressError);
    await expect(safeFetch("http://localhost:1/")).rejects.toBeInstanceOf(BlockedAddressError);
    await expect(safeFetch("file:///etc/passwd")).rejects.toBeInstanceOf(BlockedAddressError);
  });

  test("empty tags fall through to the next source", () => {
    expect(previewFromTags("web", { "og:title": "", title: "Fallback", "og:image": "", "twitter:image": "t.png" }))
      .toMatchObject({ title: "Fallback", image: "t.png" });
  });

  test("per-site preview clean-up", () => {
    expect(previewFromTags("tiktok", { "og:title": "TikTok · Scout, Suki & Stella", "og:image": "https://cdn/x.jpg" }))
      .toMatchObject({ title: null, author: "Scout, Suki & Stella", image: "https://cdn/x.jpg" });
    expect(previewFromTags("tiktok", { "og:title": "TikTok · Sam", "og:description": "the ending 😂" }))
      .toMatchObject({ title: "the ending 😂", author: "Sam" });
    expect(previewFromTags("instagram", {
      "og:title": 'Sam Lee on Instagram: "beach day"',
      "og:description": '12K likes, 40 comments - samlee on May 1, 2025: "beach day"',
    })).toMatchObject({ title: "beach day", author: "@samlee" });
    expect(previewFromTags("instagram", { "og:title": "Instagram" }).title).toBeNull();
  });

  test("Instagram and entity parsing", () => {
    expect(decodeEntities("Tom &amp; Jerry &#8220;hi&#x201D; &bogus;")).toBe("Tom & Jerry “hi” &bogus;");
    expect(decodeEntities("Caf&eacute; &mdash; it&rsquo;s &hellip; &Eacute;")).toBe("Café — it’s … É");
    const tags = ogTags(`<meta content='X' property="og:title"><meta name="description" content="a"><meta property="og:title" content="second">`);
    expect(tags).toEqual({ "og:title": "X", description: "a" });
  });
});

test("previews older than PREVIEW_VERSION are backfilled one at a time", async () => {
  const dir = mkdtempSync(join(tmpdir(), "links-backfill-"));
  try {
    const db = openDatabase(dir);
    const add = db.query("INSERT INTO links (group_id, url, platform, title, meta, added_by, added_at) VALUES (1, ?, 'web', ?, ?, 'u', ?)");
    add.run(`${origin}/video?id=1`, "Old title", "done", 1);
    add.run(`${origin}/plain`, null, "failed", 2);
    db.close();
    const { app, server } = startServer({ ...baseConfig, dataDir: dir, previewBackfillMs: 5 });
    try {
      const rows = () => {
        const d = new Database(join(dir, "links.db"), { readonly: true });
        try {
          return d.query("SELECT title, description, meta, preview_v FROM links ORDER BY id").all() as any[];
        } finally {
          d.close();
        }
      };
      for (let i = 0; i < 200 && rows().some((r) => r.preview_v < PREVIEW_VERSION); i++) await Bun.sleep(10);
      await app.idle();
      expect(rows()).toEqual([
        { title: "Cats & Dogs", description: "Two pets", meta: "done", preview_v: PREVIEW_VERSION },
        { title: 'Just a "page"', description: null, meta: "done", preview_v: PREVIEW_VERSION },
      ]);
    } finally {
      server.stop(true);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
