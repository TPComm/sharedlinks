import { Database } from "bun:sqlite";
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../src/app.ts";
import { configFromEnv } from "../src/config.ts";
import { canonical, expandShortLink, extractUrl, platformOf } from "../src/links.ts";
import { BlockedAddressError, isPrivateAddress, safeFetch } from "../src/net.ts";
import { decodeEntities, ogTags, previewFromTags } from "../src/previews.ts";

// 1x1 PNG
const PNG = Uint8Array.from(atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="), (c) => c.charCodeAt(0));
const VERIFIER = "v".repeat(43);

const dataDir = mkdtempSync(join(tmpdir(), "links-test-"));
let api: string;
let origin: string;
let stop: () => void;
let idle: () => Promise<void>;
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
      `<html><head><title>Fallback</title><meta property="og:title" content="Cats &amp; Dogs"><meta property="og:site_name" content="PetTube"><meta property="og:image" content="/thumb.png"></head></html>`,
      { headers: { "Content-Type": "text/html" } }),
    "/plain": new Response("<html><head><title> Just a &quot;page&quot; </title></head></html>", { headers: { "Content-Type": "text/html" } }),
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

  const config = {
    ...configFromEnv({}),
    port: 0,
    hostname: "127.0.0.1",
    dataDir,
    publicUrl: "https://links.example.com",
    workosClientId: "client_TEST",
    workosApi: fakeWorkOS.url.origin,
    allowedEmails: ["friend@example.com", "@team.test"],
    allowPrivateNetwork: true,
    logRequests: false,
  };
  const { app, server } = startServer(config);
  api = server.url.origin;
  origin = fakeOrigin.url.origin;
  idle = app.idle;
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

const signIn = (code: string, verifier = VERIFIER) =>
  call("/api/auth/token", { body: { code, code_verifier: verifier } });

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

  test("code exchange: guest list, verification, PKCE", async () => {
    expect((await signIn("stranger")).status).toBe(403);
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
    expect((db.query("PRAGMA user_version").get() as any).user_version).toBe(4);
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
    expect(link).toMatchObject({ title: "Cats & Dogs", author: "PetTube", meta: "done", thumb: `/thumbs/${link.id}` });

    const thumb = await fetch(api + link.thumb, { headers: { Authorization: `Bearer ${token}` } });
    expect(thumb.status).toBe(200);
    expect(thumb.headers.get("content-type")).toBe("image/png");
    expect(new Uint8Array(await thumb.arrayBuffer())).toEqual(PNG);
    expect((await fetch(api + link.thumb)).status).toBe(401);

    const dup = await call("/api/links", { token, body: { url: `${origin}/video/?id=7&fbclid=zzz` } });
    expect(dup.status).toBe(200);
    expect(dup.data).toMatchObject({ duplicate: true, link: { id: link.id } });

    const plain = await call("/api/links", { token, body: { text: `${origin}/plain` } });
    await idle();
    const plainLink = (await call("/api/state", { token })).data.links.find((l: any) => l.id === plain.data.link.id);
    expect(plainLink).toMatchObject({ title: 'Just a "page"', thumb: null, meta: "done" });

    expect((await call("/api/links", { token, body: { url: "no link here" } })).status).toBe(400);
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
    r = await call("/api/links/1", { method: "PATCH", token, body: { note: "x".repeat(600) } });
    expect(r.data.link.note.length).toBe(500);
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

describe("deleting an account", () => {
  test("removes the person, every session, their marks and reactions; their links stay, from no one", async () => {
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
    } finally {
      db.close();
    }

    // Her link stays for the friend, from "deleted", with its note, thumbnail and the friend's marks.
    const { data } = await call("/api/state", { token: friendToken });
    expect(data.users.map((u: any) => u.id)).not.toContain(janeId);
    expect(data.users.map((u: any) => u.id)).not.toContain("deleted");
    const kept = data.links.find((l: any) => l.id === sent.id);
    expect(kept).toMatchObject({ added_by: "deleted", note: "from jane", thumb: `/thumbs/${sent.id}` });
    expect(Object.keys(kept.seen)).toEqual([friendId]);
    expect(kept.reactions).toEqual({ [friendId]: "🔥" });
    expect(existsSync(join(dataDir, "thumbs", String(sent.id)))).toBe(true);
    expect((await call(kept.thumb, { token: friendToken })).status).toBe(200);
    // The friend's own link keeps the friend's marks, not hers.
    const theirs = data.links.find((l: any) => l.id === friends.id);
    expect(Object.keys(theirs.seen)).toEqual([friendId]);
    expect(theirs.reactions).toEqual({ [friendId]: "❤️" });

    // Still on the guest list, so she can sign up again (same WorkOS id, same email), but as a new,
    // empty account: her old links stay "deleted" rather than coming back to her.
    const again = await signIn("domain");
    expect(again.status).toBe(200);
    expect(again.data.user).toMatchObject({ id: janeId, name: "Jane Doe", email: "jane.doe@team.test" });
    const after = (await call("/api/state", { token: again.data.token })).data;
    expect(after.links.find((l: any) => l.id === sent.id).added_by).toBe("deleted");
    expect(after.links.some((l: any) => l.added_by === janeId || l.seen[janeId] || l.reactions[janeId])).toBe(false);
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
      .toEqual({ title: null, author: "Scout, Suki & Stella", image: "https://cdn/x.jpg" });
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
