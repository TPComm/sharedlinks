import { Database } from "bun:sqlite";
import { afterAll, beforeAll, describe, expect, spyOn, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createConnection } from "node:net";
import { startServer } from "../src/app.ts";
import { configFromEnv } from "../src/config.ts";
import { canonical, expandShortLink, extractUrl, platformOf } from "../src/links.ts";
import { BlockedAddressError, isPrivateAddress, safeFetch } from "../src/net.ts";
import { decodeEntities, ogTags, PREVIEW_VERSION, previewFromTags } from "../src/previews.ts";
import { openDatabase } from "../src/db.ts";
import { fakeFetch, seedEveryoneMember } from "./unit/helpers.ts";

// 1x1 PNG
const PNG = Uint8Array.from(atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="), (c) => c.charCodeAt(0));
const VERIFIER = "v".repeat(43);

test("startup removes orphaned photos and report copies, but keeps referenced files", async () => {
  const dir = mkdtempSync(join(tmpdir(), "links-orphan-photos-"));
  const db = openDatabase(dir);
  db.run("INSERT INTO users (id, name, created_at, photo) VALUES ('person', 'Person', 1, 'kept')");
  db.run("INSERT INTO reports (reporter, user_id, reason, details, snapshot, created_at) VALUES ('person', 'person', 'spam', '', ?, 1)",
    [JSON.stringify({ photo_copy: "report-photos/evidence" })]);
  db.close();
  for (const file of ["photos/kept", "photos/orphan", "photos/unfinished.part", "report-photos/evidence", "report-photos/orphan"]) {
    writeFileSync(join(dir, file), PNG);
  }
  mkdirSync(join(dir, "photos", "directory.part"));
  mkdirSync(join(dir, "report-photos", "directory"));
  const reopened = openDatabase(dir);
  reopened.close();
  expect(existsSync(join(dir, "photos/orphan"))).toBe(true);
  const log = spyOn(console, "log").mockImplementation(() => {});
  const config = { ...configFromEnv({}), port: 0, hostname: "127.0.0.1", dataDir: dir, previewBackfillMs: 0 };
  let started: ReturnType<typeof startServer> | undefined;
  try {
    started = startServer(config);
    expect(readdirSync(join(dir, "photos")).sort()).toEqual(["directory.part", "kept"]);
    expect(readdirSync(join(dir, "report-photos")).sort()).toEqual(["directory", "evidence"]);
    expect(log.mock.calls).toEqual([["removed 2 orphaned profile photo(s) and 1 report photo(s)"]]);
    started.app.push.close();
    started.server.stop(true);
    await started.app.idle();
    started.app.db.close();
    started = undefined;
    log.mockClear();
    started = startServer(config);
    expect(log).not.toHaveBeenCalled();
    expect(readdirSync(join(dir, "photos")).sort()).toEqual(["directory.part", "kept"]);
    expect(readdirSync(join(dir, "report-photos")).sort()).toEqual(["directory", "evidence"]);
  } finally {
    log.mockRestore();
    if (started) {
      started.app.push.close();
      started.server.stop(true);
      await started.app.idle();
      started.app.db.close();
    }
    rmSync(dir, { recursive: true, force: true });
  }
});

const dataDir = mkdtempSync(join(tmpdir(), "links-test-"));
let api: string;
let origin: string;
let stop: () => void;
let idle: () => Promise<void>;
let mint: (email: string, name: string) => string;
let approveClaim: (email: string, name: string) => void;
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
          chatGuest: { id: "user_CHATGUEST", email: "chatguest@example.test", email_verified: true },
          unverified: { id: "user_01UNVERIFIED", email: "friend2@team.test", email_verified: false },
          rude: { id: "user_01RUDE", email: "rude.person@team.test", email_verified: true, first_name: "Zonk" },
          blocker: { id: "user_01BLOCKER", email: "blocker@team.test", email_verified: true, first_name: "Bea" },
          // No invite yet: they get in with one from someone who's in.
          nova: { id: "user_01NOVA", email: "nova@else.test", email_verified: true, first_name: "Nova" },
          sol: { id: "user_01SOL", email: "Sol@Else.test", email_verified: true, first_name: "Sol" },
          kit: { id: "user_01KIT", email: "kit@else.test", email_verified: true, first_name: "Kit" },
          pip: { id: "user_01PIP", email: "pip@else.test", email_verified: true, first_name: "Pip" },
          lee: { id: "user_01LEE", email: "lee@else.test", email_verified: true, first_name: "Lee" },
          max: { id: "user_01MAX", email: "max@else.test", email_verified: true, first_name: "Max" },
          ida: { id: "user_01IDA", email: "ida@else.test", email_verified: true, first_name: "Ida" },
          neo: { id: "user_01NEO", email: "neo@else.test", email_verified: true, first_name: "Neo" },
          privateGuest: { id: "user_01PRIVATEGUEST", email: "privateguest@else.test", email_verified: true },
          oldInviteGuest: { id: "user_01OLDINVITEGUEST", email: "oldinviteguest@else.test", email_verified: true },
          existingGuest: { id: "user_01EXISTINGGUEST", email: "existingguest@else.test", email_verified: true },
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

beforeAll(async () => {
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
  approveClaim = (email, name) => app.accounts.approveClaim(email, name);
  stop = () => server.stop(true);
  for (const code of ["good", "domain", "rude", "blocker"]) {
    const { status, data } = await signIn(code);
    expect(status).toBe(200);
    expect(data.group_id).toBeNull();
    seedEveryoneMember(app.db, data.user.id);
  }
});

afterAll(() => {
  stop();
  fakeWorkOS.stop(true);
  fakeOrigin.stop(true);
  rmSync(dataDir, { recursive: true, force: true });
});

async function call(path: string, opts: { method?: string; token?: string; body?: unknown } = {}, endpoint = api) {
  const res = await fetch(endpoint + path, {
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

test("nudges are sender-only, private, limited per person and skip ineligible members", async () => {
  const dir = mkdtempSync(join(tmpdir(), "links-nudges-"));
  const { app, server } = startServer({ ...baseConfig, dataDir: dir, port: 0, previewBackfillMs: 0 });
  const request = async (path: string, token: string, body?: unknown) => {
    const res = await fetch(server.url.origin + path, {
      method: body === undefined ? "GET" : "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return { status: res.status, data: await res.json() as any };
  };
  const sender = app.accounts.mintSession("nudge-sender@test.example", "Sender");
  const recipient = app.accounts.mintSession("nudge-recipient@test.example", "Recipient");
  const watcher = app.accounts.mintSession("nudge-watcher@test.example", "Watcher");
  const outsider = app.accounts.mintSession("nudge-outsider@test.example", "Outsider");
  const who = async (token: string) => (await request("/api/state", token)).data.me as string;
  const [s, r, w] = await Promise.all([sender, recipient, watcher].map(who)) as [string, string, string];
  const group = (await request("/api/groups", sender, { name: "Nudges", members: [r, w] })).data.group.id;
  const direct = (await request("/api/state", sender)).data.groups.find((g: any) => g.direct && g.members.includes(r));
  const directLink = (await request("/api/links", sender, { url: `${origin}/plain?direct-nudge`, group_id: direct.id })).data.link;
  const directNudge = await request(`/api/links/${directLink.id}/nudge`, sender, {});
  expect(directNudge.status).toBe(200);
  expect(directNudge.data.nudged).toEqual([r]);
  expect(directNudge.data.link.nudged[r]).toBeNumber();
  expect((await request(`/api/links/${directLink.id}/nudge`, sender, {})).status).toBe(429);
  const added = await request("/api/links", sender, { url: `${origin}/plain?nudge`, group_id: group });
  const id = added.data.link.id;
  await app.idle();
  const title = (await request("/api/state", sender)).data.links.find((l: any) => l.id === id).title;
  Object.defineProperty(app.push, "enabled", { value: true });
  const delivery = spyOn(app.push as any, "toPerson").mockImplementation(async (...args: any[]) => {
    const payload = args[2](0);
    expect(payload.aps.category).toBe("NUDGE");
    expect(payload.aps.alert.title).toBe("Sender nudged you");
    expect(payload.aps.alert.body).toBe(title || "link");
    expect(payload.link_id).toBe(id);
    expect(payload.sender_id).toBe(s);
    expect(payload.group_id).toBe(group);
  });
  try {
    const path = `/api/links/${id}/nudge`;
    expect((await request(path, recipient, { people: [w] })).status).toBe(403);
    expect((await request(path, outsider, {})).status).toBe(404);
    expect((await request(path, sender, { people: "bad" })).status).toBe(400);
    const first = await request(path, sender, { people: [r, r] });
    expect(first.status).toBe(200);
    expect(first.data.nudged).toEqual([r]);
    expect(first.data.link.nudged[r]).toBeNumber();
    await app.idle();
    expect(delivery).toHaveBeenCalledTimes(1);
    expect(delivery.mock.calls[0]![0]).toBe(r);
    expect((await request(path, sender, { people: [r] })).status).toBe(429);
    expect((await request("/api/state", sender)).data.links.find((l: any) => l.id === id).nudged).toEqual(first.data.link.nudged);
    expect((await request("/api/state", recipient)).data.links.find((l: any) => l.id === id).nudged).toBeUndefined();
    app.db.run("INSERT INTO blocks (blocker, blocked, created_at) VALUES (?, ?, 1)", [s, r]);
    expect((await request(path, sender, { people: [r] })).status).toBe(400);
    app.db.run("DELETE FROM blocks WHERE blocker = ? AND blocked = ?", [s, r]);
    // Their block stays private: the reply is the same as without it.
    app.db.run("INSERT INTO blocks (blocker, blocked, created_at) VALUES (?, ?, 1)", [r, s]);
    expect((await request(path, sender, { people: [r] })).status).toBe(429);
    app.db.run("DELETE FROM blocks WHERE blocker = ? AND blocked = ?", [r, s]);
    app.db.run("INSERT INTO seen (link_id, person, seen_at) VALUES (?, ?, 1)", [id, w]);
    app.db.run("UPDATE nudges SET nudged_at = nudged_at - 86401 WHERE link_id = ?", [id]);
    app.db.run("UPDATE group_members SET muted = 1 WHERE group_id = ? AND user_id = ?", [group, r]);
    const everyone = await request(path, sender, {});
    expect(everyone.data.nudged).toEqual([r]);
    await app.idle();
    expect(delivery).toHaveBeenCalledTimes(1);
    expect((await request(path, sender, { people: [] })).status).toBe(429);
    app.db.run("UPDATE group_members SET muted = 0 WHERE group_id = ? AND user_id = ?", [group, r]);
    // Reporting the link or blocking the sender still looks like a nudge to the sender, but sends no push.
    app.db.run("INSERT INTO reports (reporter, link_id, reason, details, snapshot, created_at) VALUES (?, ?, 'spam', '', '{}', 1)", [r, id]);
    app.db.run("UPDATE nudges SET nudged_at = nudged_at - 86401 WHERE link_id = ?", [id]);
    expect((await request(path, sender, {})).data.nudged).toEqual([r]);
    app.db.run("DELETE FROM reports WHERE reporter = ? AND link_id = ?", [r, id]);
    app.db.run("INSERT INTO blocks (blocker, blocked, created_at) VALUES (?, ?, 1)", [r, s]);
    app.db.run("UPDATE nudges SET nudged_at = nudged_at - 86401 WHERE link_id = ?", [id]);
    expect((await request(path, sender, {})).data.nudged).toEqual([r]);
    await app.idle();
    expect(delivery).toHaveBeenCalledTimes(1);
    app.db.run("INSERT INTO seen (link_id, person, seen_at) VALUES (?, ?, 1)", [id, r]);
    expect((await request(path, sender, {})).data).toEqual({ error: "There's nobody to nudge right now." });
    app.db.run("DELETE FROM links WHERE id = ?", [id]);
    expect(app.db.query("SELECT * FROM nudges WHERE link_id = ?").all(id)).toEqual([]);
  } finally {
    delivery.mockRestore();
    app.push.close();
    server.stop(true);
    await app.idle();
    app.db.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("nudging everyone skips unclaimed legacy people in the Everyone chat", async () => {
  const dir = mkdtempSync(join(tmpdir(), "links-legacy-nudges-"));
  const { app, server } = startServer({ ...baseConfig, dataDir: dir, port: 0, previewBackfillMs: 0 });
  try {
    const endpoint = server.url.origin;
    const sender = app.accounts.mintSession("legacy-nudge-sender@test.example", "Sender");
    const friend = app.accounts.mintSession("legacy-nudge-friend@test.example", "Friend");
    const other = app.accounts.mintSession("legacy-nudge-other@test.example", "Other Friend");
    const recipientIds = await Promise.all([friend, other].map(async (token) => (await call("/api/state", { token }, endpoint)).data.me as string));
    const legacy = "legacy:Sam";
    app.db.run("INSERT INTO users (id, name, created_at) VALUES (?, 'Sam', 1)", [legacy]);
    seedEveryoneMember(app.db, legacy);
    const { data } = await call("/api/state", { token: sender }, endpoint);
    const everyone = data.groups.find((g: any) => g.default);
    expect(everyone.members).toContain(legacy);
    const { status, data: added } = await call("/api/links", { token: sender,
      body: { url: `${origin}/plain?legacy-nudge`, group_id: everyone.id },
    }, endpoint);
    expect(status).toBe(201);
    const nudge = await call(`/api/links/${added.link.id}/nudge`, { token: sender, body: {} }, endpoint);
    expect(nudge.status).toBe(200);
    expect(nudge.data.nudged.sort()).toEqual(recipientIds.sort());
    expect(Object.keys(nudge.data.link.nudged).sort()).toEqual(recipientIds);
  } finally {
    app.push.close();
    server.stop(true);
    await app.idle();
    app.db.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

const signIn = (code: string, verifier = VERIFIER, invite?: string) =>
  call("/api/auth/token", { body: { code, code_verifier: verifier, ...(invite ? { invite } : {}) } });

test("a keep-alive connection still accepts a note PATCH after 13 seconds idle", async () => {
  const token = mint("idle@example.com", "Idle");
  const added = await call("/api/links", { token, body: { url: `${origin}/plain?idle` } });
  expect(added.status).toBe(201);
  const url = new URL(api);
  const socket = createConnection({ host: url.hostname, port: Number(url.port) });
  socket.on("error", () => {});
  const request = (method: string, path: string, body = "") => new Promise<{ status: number; body: any }>((resolve, reject) => {
    let received = Buffer.alloc(0);
    const cleanup = () => {
      socket.off("data", data);
      socket.off("error", failed);
      socket.off("close", closed);
      clearTimeout(timer);
    };
    const failed = (error: Error) => { cleanup(); reject(error); };
    const closed = () => failed(new Error("Keep-alive connection closed before the response"));
    const data = (chunk: Buffer) => {
      received = Buffer.concat([received, chunk]);
      const end = received.indexOf("\r\n\r\n");
      if (end < 0) return;
      const headers = received.subarray(0, end).toString();
      const length = headers.match(/\r\ncontent-length: (\d+)/i);
      if (!length) { failed(new Error("Expected Content-Length on JSON response")); return; }
      if (received.length < end + 4 + Number(length[1])) return;
      cleanup();
      try {
        resolve({ status: Number(headers.split(" ")[1]), body: JSON.parse(received.subarray(end + 4).toString()) });
      } catch (error) { reject(error); }
    };
    const timer = setTimeout(() => failed(new Error("Timed out reading keep-alive response")), 3000);
    socket.on("data", data);
    socket.on("error", failed);
    socket.on("close", closed);
    socket.write(`${method} ${path} HTTP/1.1\r\nHost: ${url.host}\r\nAuthorization: Bearer ${token}\r\nConnection: keep-alive\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`, (error) => {
      if (error) failed(error);
    });
  });
  try {
    expect((await request("GET", "/api/state")).status).toBe(200);
    await Bun.sleep(13_000);
    const patched = await request("PATCH", `/api/links/${added.data.link.id}`, JSON.stringify({ note: "Still connected" }));
    expect(patched.status).toBe(200);
    expect(patched.body.link.note).toBe("Still connected");
    const state = await call("/api/state", { token });
    expect(state.data.links.find((link: { id: number }) => link.id === added.data.link.id).note).toBe("Still connected");
  } finally {
    socket.destroy();
  }
}, 20_000);

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
    expect(ok.data.claimable).toEqual([]); // only legacy people an admin let you claim
    expect(workosRequests.at(-1)).toMatchObject({ client_id: "client_TEST", grant_type: "authorization_code", code: "good" });
    expect(workosRequests.at(-1)!.client_secret).toBeUndefined();

    const domain = await signIn("domain");
    expect(domain.data.user.name).toBe("Jane Doe"); // from the email when there's no first name
  });
});

describe("browser landing page", () => {
  test("introduces Links without signing in or advertising an unconfigured download", async () => {
    const res = await call("/");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/html; charset=utf-8");
    expect(res.data).toContain("Good finds.");
    expect(res.data).toContain("Links is invite-only.");
    expect(res.data).toContain('href="sharedlinks://inbox"');
    expect(res.data).toContain('href="/privacy"');
    expect(res.data).toContain('href="/support"');
    expect(res.data).toContain('href="/icon.png"');
    expect(res.data).toContain('src="/app-preview.png"');
    expect(res.data).toContain("The real Links app. A few made-up finds.");
    expect(res.data).not.toContain("apps.apple.com");
    expect(res.data).not.toContain("apple-itunes-app");
    expect(res.data).not.toContain("<script");
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
    const signedIn = await signIn("pip", VERIFIER, token);
    expect(signedIn.status).toBe(200);
    expect(signedIn.data.group_id).toBeNull();
    const view = (await call("/api/state", { token: signedIn.data.token })).data;
    expect(view).toMatchObject({ groups: [], links: [], users: [{ id: signedIn.data.user.id }] });
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

  test("adding a shared link page resolves the original within and across chats", async () => {
    const added = await call("/api/links", { token, body: { url: `${origin}/plain?shared=original` } });
    expect(added.status).toBe(201);
    const link = added.data.link;
    const again = await call("/api/links", { token, body: { url: link.share_url } });
    expect(again.data).toMatchObject({ duplicate: true, link: { id: link.id } });
    const trailing = await call("/api/links", { token, body: { url: `${link.share_url}/` } });
    expect(trailing.data).toMatchObject({ duplicate: true, link: { id: link.id } });
    const chat = await call("/api/groups", { token, body: { name: "Shared pages" } });
    const forwarded = await call("/api/links", { token, body: { url: link.share_url, group_id: chat.data.group.id } });
    expect(forwarded.status).toBe(201);
    expect(forwarded.data).toMatchObject({ duplicate: false, link: { url: link.url, group_id: chat.data.group.id } });
    expect(forwarded.data.link.id).not.toBe(link.id);
  });

  test("shared page resolution leaves unknown tokens and other origins alone", async () => {
    const realFetch = globalThis.fetch;
    const stub = fakeFetch((url, init) => new URL(url).origin === baseConfig.publicUrl
      ? new Response("Not found", { status: 404 }) : realFetch(url, init));
    try {
      const added = await call("/api/links", { token, body: { url: `${origin}/plain?shared=boundaries` } });
      for (const url of [
        `${baseConfig.publicUrl}/l/${"a".repeat(32)}`,
        `${origin}/l/${added.data.link.token}`,
        `${baseConfig.publicUrl}/l/${added.data.link.token}/image`,
      ]) {
        const result = await call("/api/links", { token, body: { url } });
        expect(result.status).toBe(201);
        expect(result.data).toMatchObject({ duplicate: false, link: { url } });
      }
    } finally {
      await idle();
      stub.restore();
    }
  });

  test("migrations: AUTOINCREMENT ids and today's URL spelling", async () => {
    const db = new Database(join(dataDir, "links.db"), { readonly: true });
    const { sql } = db.query("SELECT sql FROM sqlite_master WHERE name = 'links'").get() as { sql: string };
    expect(sql).toContain("AUTOINCREMENT");
    expect((db.query("PRAGMA user_version").get() as any).user_version).toBe(21);
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

  test("public link pages share only the title, thumbnail and original URL", async () => {
    const state = (await call("/api/state", { token })).data;
    const tokens = state.links.map((l: any) => l.token);
    expect(new Set(tokens).size).toBe(tokens.length);
    for (const link of state.links) {
      expect(link.token).toMatch(/^[A-Za-z0-9_-]{32}$/);
      expect(link.share_url).toBe(`${baseConfig.publicUrl}/l/${link.token}`);
    }
    const add = await call("/api/links", { token, body: { url: `${origin}/video?public=1`, note: "private-note-only" } });
    const link = add.data.link;
    expect(link.token).toMatch(/^[A-Za-z0-9_-]{32}$/);
    expect(tokens).not.toContain(link.token);
    expect(link.share_url).toBe(`${baseConfig.publicUrl}/l/${link.token}`);
    await idle();
    const page = await fetch(`${api}/l/${link.token}`);
    expect(page.status).toBe(200);
    const html = await page.text();
    expect(html).toContain('property="og:title" content="Cats &#38; Dogs"');
    expect(html).toContain(`property="og:image" content="${link.share_url}/image"`);
    expect(html).toContain('property="og:image:width" content="1"');
    expect(html).toContain('name="twitter:card" content="summary_large_image"');
    for (const secret of ["private-note-only", "PetTube", "Two pets", "Riley", friendId]) expect(html).not.toContain(secret);
    const image = await fetch(`${api}/l/${link.token}/image`);
    expect(image.status).toBe(200);
    expect(image.headers.get("content-type")).toBe("image/png");
    expect(image.headers.get("cache-control")).toContain("public");
    expect(image.headers.get("content-security-policy")).toBe("default-src 'none'; style-src 'unsafe-inline'; sandbox");
    expect(image.headers.get("x-content-type-options")).toBe("nosniff");
    expect(new Uint8Array(await image.arrayBuffer())).toEqual(PNG);
    for (const bad of ["unknown", "a.b", "a".repeat(65)]) {
      const missing = await fetch(`${api}/l/${bad}`);
      expect(missing.status).toBe(404);
      expect(await missing.text()).not.toContain('property="og:image"');
      expect((await fetch(`${api}/l/${bad}/image`)).status).toBe(404);
    }
    await call(`/api/links/${link.id}`, { method: "DELETE", token });
    expect((await fetch(`${api}/l/${link.token}`)).status).toBe(404);
    expect((await fetch(`${api}/l/${link.token}/image`)).status).toBe(404);
    const old = state.links.find((l: any) => l.id === 1);
    const fallback = await (await fetch(`${api}/l/${old.token}`)).text();
    expect(fallback).toContain(`${baseConfig.publicUrl}/icon.png`);
    expect(fallback).not.toContain("summary_large_image");
    expect((await fetch(`${api}/l/${old.token}/image`)).status).toBe(404);
  });

  test("public link pages accept a single trailing slash", async () => {
    const add = await call("/api/links", { token, body: { url: `${origin}/video?trailing=1` } });
    const link = add.data.link;
    await idle();
    const page = await fetch(`${api}/l/${link.token}/`);
    expect(page.status).toBe(200);
    expect(page.headers.get("content-type")).toContain("text/html");
    const html = await page.text();
    expect(html).toContain('property="og:title" content="Cats &#38; Dogs"');
    expect(html).toBe(await (await fetch(`${api}/l/${link.token}`)).text());
    for (const path of ["/l/unknown/", `/l/${link.token}//`, "/l/", "/l/x/y"]) {
      expect((await fetch(`${api}${path}`)).status).toBe(404);
    }
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
    expect(thumb.headers.get("content-security-policy")).toBe("default-src 'none'; style-src 'unsafe-inline'; sandbox");
    expect(thumb.headers.get("x-content-type-options")).toBe("nosniff");
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

  test("notification settings: both on to start; PATCH /api/me changes either, alone or with a name", async () => {
    expect((await call("/api/me", { token })).data.notifications).toEqual({ watched: true, reactions: true });
    const off = await call("/api/me", { method: "PATCH", token, body: { notifications: { reactions: false } } });
    expect(off.status).toBe(200);
    expect(off.data.notifications).toEqual({ watched: true, reactions: false });
    const name = (await call("/api/me", { token })).data.user.name;
    for (const notifications of [null, "off", [], { watched: "no" }]) {
      expect((await call("/api/me", { method: "PATCH", token, body: { notifications } })).status, JSON.stringify(notifications)).toBe(400);
    }
    const both = await call("/api/me", { method: "PATCH", token, body: { name, notifications: { watched: false, reactions: true } } });
    expect(both.data).toMatchObject({ user: { name }, notifications: { watched: false, reactions: true } });
    await call("/api/me", { method: "PATCH", token, body: { notifications: { watched: true } } });
  });

  test("claiming a legacy person moves their history", async () => {
    expect((await call("/api/me/claim", { token, body: { id: "legacy:Sam" } })).status).toBe(400); // Riley isn't Sam
    const asSam = await call("/api/me", { method: "PATCH", token, body: { name: "sam" } });
    expect(asSam.status).toBe(200);
    // Anyone can type a name, so only the admin's `links-server claim` makes Sam claimable.
    expect((await call("/api/me", { token })).data.claimable).toEqual([]);
    expect((await call("/api/me/claim", { token, body: { id: "legacy:Sam" } })).status).toBe(400);
    approveClaim("friend@example.com", "Sam");
    expect((await call("/api/me", { token })).data.claimable.map((u: any) => u.id)).toEqual(["legacy:Sam"]);
    expect((await call("/api/me/claim", { token, body: { id: "legacy:Alex" } })).status).toBe(400);
    const r = await call("/api/me/claim", { token, body: { id: "legacy:Sam" } });
    expect(r.status).toBe(200);
    expect(r.data.user.name).toBe("Sam");
    expect(r.data.claimable).toEqual([]);
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

  test("profile photos: upload replaces the WorkOS picture at a new public address; remove goes back to initials", async () => {
    const put = (body: Uint8Array | string, t = token) => fetch(api + "/api/me/photo", { method: "PUT", body,
      headers: { Authorization: `Bearer ${t}`, "Content-Type": "image/jpeg" } });
    const avatarIn = async () => ({ me: (await call("/api/me", { token })).data.user.avatar,
      state: (await call("/api/state", { token })).data.users.find((u: any) => u.id === friendId)?.avatar });
    expect((await avatarIn()).me).toBe("https://example.com/r.png");
    expect((await fetch(api + "/api/me/photo", { method: "PUT", body: PNG })).status).toBe(401);
    for (const bad of ["not a photo", new Uint8Array(0), Uint8Array.of(0xff, 0xd8, 0xff, 0, 0, 0), PNG.slice(0, 24)]) {
      expect((await put(bad)).status).toBe(400);
    }
    const huge = new Uint8Array(2_000_001);
    huge.set(PNG);
    expect((await put(huge)).status).toBe(413);
    expect((await avatarIn()).me).toBe("https://example.com/r.png");

    const first = await put(PNG);
    expect(first.status).toBe(200);
    const url = ((await first.json()) as any).user.avatar as string;
    expect(url).toMatch(/^https:\/\/links\.example\.com\/photos\/[A-Za-z0-9_-]{32}$/);
    expect(await avatarIn()).toEqual({ me: url, state: url });
    const path = new URL(url).pathname;
    const served = await fetch(api + path); // no session: AsyncImage doesn't send one
    expect(served.status).toBe(200);
    expect(served.headers.get("Content-Type")).toBe("image/png");
    expect(served.headers.get("X-Content-Type-Options")).toBe("nosniff");
    expect(new Uint8Array(await served.arrayBuffer())).toEqual(PNG);
    expect(readdirSync(join(dataDir, "photos"))).toEqual([path.split("/")[2]!]);

    const second = ((await (await put(PNG)).json()) as any).user.avatar as string;
    expect(second).not.toBe(url);
    expect((await fetch(api + path)).status).toBe(404);
    expect(readdirSync(join(dataDir, "photos"))).toEqual([second.split("/")[4]!]);
    expect((await fetch(api + "/photos/../links.db")).status).toBe(404);

    const removed = await call("/api/me/photo", { method: "DELETE", token });
    expect(removed.status).toBe(200);
    expect(removed.data.user.avatar).toBeNull();
    expect(await avatarIn()).toEqual({ me: null, state: null });
    expect((await fetch(new URL(second).pathname.replace(/^/, api))).status).toBe(404);
    expect(readdirSync(join(dataDir, "photos"))).toEqual([]);
    // Signing in again doesn't bring the WorkOS picture back over their choice.
    expect((await signIn("good")).data.user.avatar).toBeNull();
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
    db.run("INSERT INTO group_members (group_id, user_id, joined_at) VALUES (1, ?, 1)", [id]); // as v8 put legacy people
    try {
      expect((await call("/api/blocks", { token: bea.token, body: { user_id: id } })).data).toEqual({ blocked: [id] });
      expect((await call(`/api/blocks/${encodeURIComponent(id)}`, { method: "DELETE", token: bea.token })).data).toEqual({ blocked: [] });
    } finally {
      db.run("DELETE FROM blocks WHERE blocked = ?", [id]);
      db.run("DELETE FROM group_members WHERE user_id = ?", [id]);
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
    expect(res.data).toContain("People only lists people you share a chat with.");
    expect(res.data).toContain("Anyone with a link's share URL can see its title, thumbnail and original URL.");
    expect(res.data).toContain("Notes, who sent it, comments, reactions and activity stay private to the chat.");
    expect(res.data).toContain("Your name and photo can still appear on links in a chat you've left");
    expect(res.data).toContain('<a href="mailto:support@tpcomm.co">support@tpcomm.co</a>');
    expect(res.data).toContain("Delete Account");
    expect(res.data).toContain("newest 14 days");
    expect(res.data).toContain("Grafana Cloud");
    expect(res.data).toContain("push token");
    expect(res.data).toContain("a link to the sender's profile photo for a new link (anyone holding that link can open the photo)");
  });

  test("/version says which commit is running, without signing in", async () => {
    const res = await call("/version");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");
    expect(res.data).toEqual({ commit: "dev" });
  });
});

describe("wrapped", () => {
  test("requires authentication and validates integer ranges", async () => {
    expect((await call("/api/wrapped?start=1&end=2")).status).toBe(401);
    const token = mint("wrapped-validation@test.com", "Viewer");
    for (const query of ["", "start=1", "start=x&end=2", "start=1.5&end=2", "start=2&end=2", "start=3&end=2", `start=0&end=${367 * 86400}`]) {
      expect((await call(`/api/wrapped?${query}`, { token })).status).toBe(400);
    }
  });

  test("accepts a local leap year that gained an hour in Almaty", async () => {
    const token = mint("wrapped-leap-year@test.com", "Viewer");
    const start = Date.parse("2024-01-01T00:00:00+06:00") / 1000;
    const end = Date.parse("2025-01-01T00:00:00+05:00") / 1000;
    const wrapped = await call(`/api/wrapped?start=${start}&end=${end}`, { token });
    expect(wrapped.status).toBe(200);
    expect(wrapped.data).toMatchObject({ start, end });
  });

  test("breaks tied sender counts in JavaScript display-name order", async () => {
    const viewer = mint("wrapped-tie-viewer@test.com", "Viewer");
    const emoji = mint("wrapped-tie-emoji@test.com", "😀 Amy");
    const fullwidth = mint("wrapped-tie-fullwidth@test.com", "Ｚoe");
    const emojiId = (await call("/api/state", { token: emoji })).data.me;
    const fullwidthId = (await call("/api/state", { token: fullwidth })).data.me;
    const chat = await call("/api/groups", { token: viewer, body: { members: [emojiId, fullwidthId] } });
    expect(chat.status).toBe(201);
    const groupId = chat.data.group.id;
    const start = Math.floor(Date.now() / 1000);
    for (const [token, name] of [[emoji, "emoji"], [fullwidth, "fullwidth"]]) {
      const link = await call("/api/links", { token, body: { group_id: groupId, url: `${origin}/plain?wrapped-tie=${name}` } });
      expect(link.status).toBe(201);
    }
    const wrapped = await call(`/api/wrapped?start=${start}&end=${start + 3600}&group_id=${groupId}`, { token: viewer });
    expect(wrapped.data.top_sender).toEqual({ id: emojiId, name: "😀 Amy", count: 1 });
  });

  test("aggregates visible shares, ranges and chat filters with deterministic ties", async () => {
    const db = new Database(join(dataDir, "links.db"));
    const viewer = mint("wrapped-viewer@test.com", "Viewer");
    const amy = mint("wrapped-amy@test.com", "Amy"), zoe = mint("wrapped-zoe@test.com", "Zoe");
    const id = async (token: string) => (await call("/api/state", { token })).data.me;
    const [meId, amyId, zoeId] = await Promise.all([id(viewer), id(amy), id(zoe)]);
    const chat = (await call("/api/groups", { token: viewer, body: { members: [amyId, zoeId] } })).data.group.id;
    const other = (await call("/api/groups", { token: viewer, body: { members: [amyId] } })).data.group.id;
    const secret = (await call("/api/groups", { token: amy, body: { members: [zoeId] } })).data.group.id;
    const add = async (token: string, group: number, n: number, at: number, platform = "youtube") => {
      const link = (await call("/api/links", { token, body: { group_id: group, url: `${origin}/plain?wrapped=${n}` } })).data.link;
      db.run("UPDATE links SET added_at = ?, platform = ? WHERE id = ?", [at, platform, link.id]);
      return link.id;
    };
    const a = await add(amy, chat, 1, 100);
    const z = await add(zoe, chat, 2, 120, "instagram");
    const own = await add(viewer, chat, 3, 130);
    await add(amy, other, 1, 140);
    await add(amy, chat, 4, 99);
    await add(zoe, chat, 5, 200);
    await add(amy, secret, 6, 150);
    await call(`/api/links/${a}/seen`, { token: viewer, body: { seen: true } });
    await call(`/api/links/${a}/react`, { token: viewer, body: { emoji: "❤️" } });
    await call(`/api/links/${z}/react`, { token: viewer, body: { emoji: "😮" } });
    await call(`/api/links/${own}/react`, { token: amy, body: { emoji: "👎" } });
    const get = async (extra = "") => (await call(`/api/wrapped?start=100&end=200${extra}`, { token: viewer })).data;
    expect(await get()).toMatchObject({ received: 3, sent: 1, watched: 1,
      top_sender: { id: amyId, name: "Amy", count: 2 }, top_platform: { platform: "youtube", count: 2 },
      most_reacted: { id: z, sender_name: "Zoe", reactions: 1 } });
    expect(await get(`&group_id=${chat}`)).toMatchObject({ received: 2, sent: 1, top_sender: { id: amyId }, top_platform: { platform: "instagram" } });
    expect((await call(`/api/wrapped?start=100&end=200&group_id=${secret}`, { token: viewer })).status).toBe(404);
    expect((await call("/api/wrapped?start=0&end=1", { token: viewer })).data).toEqual({ start: 0, end: 1, received: 0, sent: 0, watched: 0, top_sender: null, top_platform: null, most_reacted: null });
    db.run("INSERT INTO blocks (blocker, blocked, created_at) VALUES (?, ?, 0)", [meId, amyId]);
    await call(`/api/links/${own}/react`, { token: amy, body: { emoji: "🔥" } });
    expect(await get()).toMatchObject({ received: 1, watched: 0, top_sender: { id: zoeId } });
    expect((await get()).most_reacted).toMatchObject({ id: z, reactions: 1 });
    await call("/api/reports", { token: viewer, body: { link_id: z, reason: "offensive" } });
    expect(await get()).toMatchObject({ received: 0, sent: 1, top_sender: null, most_reacted: null });
    db.close();
    await idle();
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
    const [everyone] = data.groups;
    expect(everyone).toMatchObject({ default: true, direct: false, name: "", created_by: null });
    expect(everyone.members).toEqual(expect.arrayContaining([annId, boId, cyId, "user_01FRIEND"]));
    const peerChats = data.groups.filter((g: any) => g.direct);
    expect(peerChats).toHaveLength(everyone.members.filter((id: string) => id !== cyId && !id.startsWith("legacy:")).length);
    expect(peerChats.map((g: any) => g.members.find((id: string) => id !== cyId))).toContain("user_01FRIEND");
    expect(data.links.length).toBeGreaterThan(0);
    expect(data.links.every((l: any) => l.group_id === everyone.id)).toBe(true);
  });

  test("a private invite doesn't let someone add their friend to Everyone", async () => {
    const before = await state(ann);
    const everyone = before.groups.find((g: any) => g.default);
    const historicalLink = before.links.find((l: any) => l.group_id === everyone.id);
    // Older apps send the active inbox filter with a friend invite.
    const made = await call("/api/invites", { token: ann, body: { group_id: everyone.id } });
    expect(made.data.invite.group_id).toBeNull();
    const guest = await signIn("privateGuest", VERIFIER, made.data.invite.url.split("/invite/")[1]);
    expect(guest.status).toBe(200);
    const { token, user } = guest.data;
    const add = await call(`/api/groups/${everyone.id}/members`, { token: ann, body: { members: [user.id] } });
    expect(add.status).toBe(400);

    const after = await state(token);
    expect(after.users.map((u: any) => u.id).sort()).toEqual([annId, user.id].sort());
    expect(after.groups).toHaveLength(1);
    expect(after.groups[0]).toMatchObject({ default: false, direct: true });
    expect(after.links).toEqual([]);
    expect((await call(`/api/state?group_id=${everyone.id}`, { token })).status).toBe(404);
    expect((await call(`/api/links/${historicalLink.id}/comments`, { token })).status).toBe(404);
    expect((await state(ann)).groups.find((g: any) => g.default).members).toEqual(everyone.members);
  });

  test("old pending invitations to Everyone grant only a direct chat", async () => {
    const everyone = (await state(ann)).groups.find((g: any) => g.default);
    const db = new Database(join(dataDir, "links.db"));
    const tokens = ["b".repeat(43), "c".repeat(43)];
    for (const [index, token] of tokens.entries()) {
      db.run(`INSERT INTO invites (token_hash, invited_by, group_id, created_at, expires_at)
        VALUES (?, ?, ?, unixepoch(), unixepoch() + 86400)`,
        [new Bun.CryptoHasher("sha256").update(token).digest("hex"), [annId, boId][index]!, everyone.id]);
    }
    db.close();
    const guest = await signIn("oldInviteGuest", VERIFIER, tokens[0]);
    expect(guest.status).toBe(200);
    const { token, user } = guest.data;
    expect((await state(token)).groups).toHaveLength(1);
    const accepted = await call("/api/invites/accept", { token, body: { token: tokens[1] } });
    expect(accepted.status).toBe(200);
    expect(accepted.data.group).toMatchObject({ default: false, direct: true });
    const view = await state(token);
    expect(view.groups).toHaveLength(2);
    expect(view.users.map((u: any) => u.id).sort()).toEqual([annId, boId, user.id].sort());
    expect(view.links).toEqual([]);
  });

  test("mute settings are per member, expire, and validate without renaming the chat", async () => {
    const chat = (await call("/api/groups", { token: ann, body: { name: "Quiet", members: [boId] } })).data.group;
    const patch = (body: object) => call(`/api/groups/${chat.id}`, { method: "PATCH", token: ann, body });
    expect(chat).toMatchObject({ muted: false, muted_until: null });
    for (const body of [{}, { muted: 1 }, { muted: null }, { muted_until: "later" }, { muted_until: 0 }, { muted_until: -1 }]) {
      expect((await patch(body)).status).toBe(400);
    }
    const until = Date.now() / 1000 + 3600;
    expect((await patch({ muted: true, muted_until: until })).data.group).toMatchObject({ name: "Quiet", muted: true, muted_until: until });
    expect((await state(ann)).groups.find((g: any) => g.id === chat.id)).toMatchObject({ muted: true, muted_until: until });
    expect((await state(bo)).groups.find((g: any) => g.id === chat.id)).toMatchObject({ muted: false, muted_until: null });
    expect((await patch({ muted: false })).data.group).toMatchObject({ muted: false, muted_until: null });
    expect((await patch({ muted: true })).data.group).toMatchObject({ muted: true, muted_until: null });
    expect((await patch({ name: "Still quiet" })).data.group).toMatchObject({ name: "Still quiet", muted: true });
    expect((await patch({ muted_until: until })).data.group).toMatchObject({ muted: true, muted_until: until });
    const raw = new Database(join(dataDir, "links.db"));
    raw.run("UPDATE group_members SET muted_until = 1 WHERE group_id = ? AND user_id = ?", [chat.id, annId]);
    raw.close();
    expect((await state(ann)).groups.find((g: any) => g.id === chat.id)).toMatchObject({ muted: false, muted_until: null });
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

  test("favorites are private, idempotent, and removed on leaving or deleting the link", async () => {
    const chat = (await call("/api/groups", { token: ann, body: { members: [boId] } })).data.group;
    const link = (await call("/api/links", { token: ann, body: { url: `${origin}/plain?n=favorite`, group_id: chat.id } })).data.link;
    const path = `/api/links/${link.id}/favorite`;
    const favorite = (method: "PUT" | "DELETE", token: string) => call(path, { method, token });
    const inState = async (token: string) => (await state(token, `?group_id=${chat.id}`)).links.find((l: any) => l.id === link.id);
    expect((await call(path, { method: "PUT" })).status).toBe(401);
    for (const method of ["PUT", "DELETE"] as const) expect((await favorite(method, cy)).status).toBe(404);

    const first = await favorite("PUT", bo);
    expect(first.status).toBe(200);
    const at = first.data.link.favorited_at;
    expect(at).toBeNumber();
    expect(first.data.link.seen).toEqual({});
    expect(first.data.link.reactions).toEqual({});
    expect((await favorite("PUT", bo)).data.link.favorited_at).toBe(at);
    expect((await inState(bo)).favorited_at).toBe(at);
    expect(await inState(ann)).not.toHaveProperty("favorited_at");
    expect((await call(`/api/links/${link.id}`, { method: "PATCH", token: ann, body: { note: "Updated" } })).data.link)
      .not.toHaveProperty("favorited_at");

    expect((await favorite("PUT", ann)).data.link.favorited_at).toBeNumber();
    for (let i = 0; i < 2; i++) {
      const removed = await favorite("DELETE", bo);
      expect(removed.status).toBe(200);
      expect(removed.data.link).not.toHaveProperty("favorited_at");
    }
    expect((await inState(ann)).favorited_at).toBeNumber();

    expect((await favorite("PUT", bo)).status).toBe(200);
    expect((await call(`/api/groups/${chat.id}`, { method: "DELETE", token: bo })).status).toBe(200);
    expect((await favorite("PUT", bo)).status).toBe(404);
    await call(`/api/groups/${chat.id}/members`, { token: ann, body: { members: [boId] } });
    expect(await inState(bo)).not.toHaveProperty("favorited_at");
    expect((await inState(ann)).favorited_at).toBeNumber();
    await idle();
    expect((await call(`/api/links/${link.id}`, { method: "DELETE", token: ann })).status).toBe(200);
    expect((await favorite("DELETE", ann)).status).toBe(404);
    const db = new Database(join(dataDir, "links.db"), { readonly: true });
    try {
      expect(db.query("SELECT * FROM favorites WHERE link_id = ?").all(link.id)).toEqual([]);
    } finally { db.close(); }
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
    const comment = (await call(`/api/links/${link.id}/comments`, { token: bo, body: { body: "Before leaving" } })).data.comment;
    const inFlight = [
      slow("PATCH", `/api/groups/${chat.id}`, { name: "Mine now" }),
      slow("POST", `/api/groups/${chat.id}/members`, { members: [cyId] }),
      slow("PATCH", `/api/links/${link.id}`, { note: "late" }),
      slow("POST", `/api/links/${link.id}/seen`, { seen: true }),
      slow("POST", `/api/links/${link.id}/react`, { emoji: "🔥" }),
      slow("POST", `/api/links/${link.id}/comments`, { body: "Too late" }),
      slow("PATCH", `/api/comments/${comment.id}`, { body: "Also too late" }),
    ];
    await Bun.sleep(50);
    expect((await call(`/api/groups/${chat.id}`, { method: "DELETE", token: bo })).status).toBe(200);
    for (const r of inFlight) r.send();
    expect(await Promise.all(inFlight.map(async (r) => (await r.res).status))).toEqual(inFlight.map(() => 404));
    const after = await state(ann);
    expect(after.groups.find((g: any) => g.id === chat.id)).toMatchObject({ name: "Before", members: [annId] });
    expect(after.links.find((l: any) => l.id === link.id)).toMatchObject({ note: "", seen: {}, reactions: {} });
    expect((await call(`/api/links/${link.id}/comments`, { token: ann })).data.comments).toEqual([comment]);
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

  test("a group-scoped invite starts a direct chat; group access needs an explicit addition", async () => {
    const chat = (await call("/api/groups", { token: ann, body: { name: "Invited", members: [boId] } })).data.group;
    const sent = await call("/api/links", { token: bo, body: { url: `${origin}/plain?n=before-lee`, group_id: chat.id } });
    const made = await call("/api/invites", { token: ann, body: { group_id: chat.id } });
    expect(made.status).toBe(201);
    expect(made.data.invite.group_id).toBeNull();
    const lee = await signIn("lee", VERIFIER, made.data.invite.url.split("/invite/")[1]);
    expect(lee.status).toBe(200);

    const leeId = "user_01LEE";
    const privateView = await state(lee.data.token);
    expect(privateView.groups).toHaveLength(1);
    expect(privateView.groups[0]).toMatchObject({ direct: true });
    expect(privateView.users.map((u: any) => u.id).sort()).toEqual([annId, leeId].sort());
    expect(privateView.links).toEqual([]);
    expect((await call(`/api/groups/${chat.id}/members`, { token: ann, body: { members: [leeId] } })).status).toBe(200);

    // Adding Lee later grants the group and connects them to the other member, not to Everyone.
    const view = await state(lee.data.token);
    expect(view.groups.filter((g: any) => !g.direct).map((g: any) => g.id)).toEqual([chat.id]);
    const peerChats = view.groups.filter((g: any) => g.direct);
    expect(peerChats.map((g: any) => g.members.find((id: string) => id !== leeId)).sort()).toEqual([annId, boId].sort());
    expect(peerChats.every((g: any) => g.members.length === 2 && g.members.includes(leeId))).toBe(true);
    expect(view.users.map((u: any) => u.id).sort()).toEqual([annId, boId, leeId].sort());
    expect(view.links.map((l: any) => l.id)).toEqual([sent.data.link.id]);
    const cyView = await state(cy);
    expect(cyView.users.map((u: any) => u.id)).not.toContain("user_01LEE");
    expect(cyView.groups.find((g: any) => g.default).members).not.toContain("user_01LEE");

    // Someone Lee can't see can't be added to a chat or reported by Lee.
    expect((await call("/api/groups", { token: lee.data.token, body: { members: [cyId] } })).data.error)
      .toBe("Someone you picked isn't in Links anymore.");
    expect((await call("/api/reports", { token: lee.data.token, body: { user_id: cyId, reason: "spam" } })).status).toBe(404);
    expect((await call("/api/blocks", { token: lee.data.token, body: { user_id: cyId } })).status).toBe(404);
    expect((await state(lee.data.token)).users.map((u: any) => u.id)).not.toContain(cyId);
    // Legacy people's history is in the default chat, which Lee isn't in.
    expect((await call("/api/me", { token: lee.data.token })).data.claimable).toEqual([]);
    expect((await call("/api/me/claim", { token: lee.data.token, body: { id: "legacy:Sam" } })).status).toBe(400);

    // A third member of the named group can't see a direct link or join the direct chat.
    const boDirect = peerChats.find((g: any) => g.members.includes(boId));
    const privateLink = await call("/api/links", { token: lee.data.token, body: { url: `${origin}/plain?n=private-to-bo`, group_id: boDirect.id } });
    expect(privateLink.status).toBe(201);
    expect((await state(bo)).links.map((l: any) => l.id)).toContain(privateLink.data.link.id);
    expect((await state(ann)).links.map((l: any) => l.id)).not.toContain(privateLink.data.link.id);
    expect((await call(`/api/groups/${boDirect.id}/members`, { token: bo, body: { members: [annId] } })).status).toBe(400);
    expect((await call(`/api/groups/${boDirect.id}`, { token: bo, method: "PATCH", body: { name: "Group" } })).status).toBe(400);
    expect((await call(`/api/groups/${boDirect.id}`, { token: bo, method: "DELETE" })).status).toBe(400);

    // Leaving the group doesn't break the direct chat, but it can now be left independently.
    expect((await call(`/api/groups/${chat.id}`, { method: "DELETE", token: bo })).status).toBe(200);
    expect((await state(lee.data.token)).groups.find((g: any) => g.id === boDirect.id).members).toContain(boId);
    expect((await call(`/api/groups/${boDirect.id}`, { token: bo, method: "DELETE" })).status).toBe(200);
    expect((await state(lee.data.token)).users.map((u: any) => u.id)).toContain(boId);

    // Adding a person to a group creates a direct chat only for the newly connected pair.
    const bridge = (await call("/api/groups", { token: ann, body: { name: "Bridge", members: [leeId] } })).data.group;
    expect((await call(`/api/groups/${bridge.id}/members`, { token: ann, body: { members: [cyId] } })).status).toBe(200);
    const cyDirect = (await state(cy)).groups.filter((g: any) => g.direct && g.members.includes(leeId));
    expect(cyDirect).toHaveLength(1);
    expect((await state(lee.data.token)).groups.filter((g: any) => g.direct && g.members.includes(annId))).toHaveLength(1);
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

  test("a legacy pending ordinary-group invite also starts only a direct chat", async () => {
    const chat = (await call("/api/groups", { token: ann, body: { members: [boId] } })).data.group;
    const token = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
    const raw = new Database(join(dataDir, "links.db"));
    raw.run(`INSERT INTO invites (token_hash, invited_by, group_id, created_at, expires_at)
      VALUES (?, ?, ?, unixepoch(), unixepoch() + 86400)`,
      [new Bun.CryptoHasher("sha256").update(token).digest("hex"), annId, chat.id]);
    raw.close();
    const guest = await signIn("max", VERIFIER, token);
    expect(guest.status).toBe(200);
    const view = await state(guest.data.token);
    expect(view.groups).toHaveLength(1);
    expect(view.groups[0]).toMatchObject({ direct: true });
    expect(view.groups[0].members.sort()).toEqual([annId, guest.data.user.id].sort());
    expect(view.links).toEqual([]);
  });

  test("someone from before invites who wasn't let in joins only their friend's chat", async () => {
    const raw = new Database(join(dataDir, "links.db"));
    raw.run("INSERT INTO users (id, email, name, created_at, member) VALUES ('user_01STRANGER', 'stranger@evil.test', 'S', 1, 0)");
    raw.run("INSERT INTO group_members (group_id, user_id, joined_at) VALUES (1, 'user_01STRANGER', 1)"); // as v8 did
    raw.close();
    await call("/api/invites", { token: cy, body: { email: "stranger@evil.test" } });
    const them = await signIn("stranger");
    expect(them.status).toBe(200);
    const view = await state(them.data.token);
    expect(view.groups.map((g: any) => g.default)).toEqual([false]);
    expect(view.groups[0].members.sort()).toEqual([cyId, "user_01STRANGER"].sort());
  });

  test("a pre-v13 member can return to an existing direct chat without claiming an email invite", async () => {
    const old = mint("old-invite@groups.test", "Old member");
    const oldId = (await state(old)).me;
    const pair = (await state(ann)).groups.find((g: any) => g.direct && g.members.includes(oldId));
    const raw = new Database(join(dataDir, "links.db"));
    raw.run("UPDATE users SET email_verified = 0 WHERE id = ?", [oldId]);
    raw.close();
    const made = await call("/api/invites", { token: ann, body: { email: "old-invite@groups.test" } });
    const accepted = await call("/api/invites/accept", { token: old, body: { token: made.data.invite.url.split("/invite/")[1] } });
    expect(accepted.status).toBe(200);
    expect(accepted.data.group.id).toBe(pair.id);
    expect((await call("/api/invites", { token: ann })).data.invites.map((i: any) => i.id)).toContain(made.data.invite.id);
  });

  test("an email invite is not listed as pending when the verified recipient already has a direct chat", async () => {
    const pair = (await state(ann)).groups.find((g: any) => g.direct && g.members.includes(boId));
    const made = await call("/api/invites", { token: ann, body: { email: "bo@groups.test" } });
    const token = made.data.invite.url.split("/invite/")[1];
    expect((await call("/api/invites", { token: ann })).data.invites.map((i: any) => i.id)).not.toContain(made.data.invite.id);
    const page = await fetch(`${api}/invite/${token}`);
    expect(page.status).toBe(200);
    expect(await page.text()).toContain('>Open in Links</a>');
    const accepted = await call("/api/invites/accept", { token: bo, body: { token } });
    expect(accepted.status).toBe(200);
    expect(accepted.data.group.id).toBe(pair.id);
    expect((await call("/api/invites", { token: ann })).data.invites.map((i: any) => i.id)).not.toContain(made.data.invite.id);
    expect((await call("/api/invites/accept", { token: bo, body: { token } })).data.group.id).toBe(pair.id);
  });

  test("someone already in who accepts a legacy group invite connects only with the inviter", async () => {
    const tokenOf = (made: any) => made.data.invite.url.split("/invite/")[1];
    const accept = (token: string, invite: unknown) => call("/api/invites/accept", { token, body: { token: invite } });
    const chat = (await call("/api/groups", { token: ann, body: { name: "Join me", members: [boId] } })).data.group;
    const sent = await call("/api/links", { token: bo, body: { url: `${origin}/plain?n=before-accept`, group_id: chat.id } });
    const first = await call("/api/invites", { token: cy, body: {} });
    const existing = await signIn("existingGuest", VERIFIER, tokenOf(first));
    expect(existing.status).toBe(200);
    const existingId = existing.data.user.id;
    const legacy = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
    const db = new Database(join(dataDir, "links.db"));
    const inviteId = Number(db.run(`INSERT INTO invites (token_hash, invited_by, group_id, created_at, expires_at)
      VALUES (?, ?, ?, unixepoch(), unixepoch() + 86400)`,
      [new Bun.CryptoHasher("sha256").update(legacy).digest("hex"), annId, chat.id]).lastInsertRowid);
    db.close();

    expect((await call("/api/invites/accept", { body: { token: legacy } })).status).toBe(401);
    const joined = await accept(existing.data.token, legacy);
    expect(joined.status).toBe(200);
    expect(joined.data.group).toMatchObject({ direct: true });
    expect(joined.data.group.members.sort()).toEqual([annId, existingId].sort());
    const view = await state(existing.data.token);
    expect(view.groups.map((g: any) => g.id)).not.toContain(chat.id);
    expect(view.links.map((l: any) => l.id)).not.toContain(sent.data.link.id);
    // Used up, though opening it again still goes to the chat.
    expect((await call("/api/invites", { token: ann })).data.invites.map((i: any) => i.id)).not.toContain(inviteId);
    expect((await accept(existing.data.token, legacy)).data.group.id).toBe(joined.data.group.id);
    expect(await accept(bo, legacy)).toMatchObject({ status: 404, data: { error: "This invite doesn't work anymore." } });

    // Someone already in the chat goes to it, and the invite stays for whoever it was for.
    const another = await call("/api/invites", { token: ann, body: { group_id: chat.id } });
    expect((await accept(bo, tokenOf(another))).data.group).toMatchObject({ direct: true });
    expect((await call("/api/invites", { token: ann })).data.invites.map((i: any) => i.id)).toContain(another.data.invite.id);
    // So does its sender, with nothing to join.
    expect((await accept(ann, tokenOf(another))).data).toEqual({ group: null });

    expect((await accept(cy, "x".repeat(43))).status).toBe(404);
    expect((await accept(cy, "")).status).toBe(404);
    const forSomeoneElse = await call("/api/invites", { token: ann, body: { email: "someone@else.test" } });
    expect(await accept(cy, tokenOf(forSomeoneElse))).toMatchObject({ status: 403, data: { error: "This invite is for a different email address." } });
    const forCy = await call("/api/invites", { token: bo, body: { email: "CY@groups.test" } });
    expect((await accept(cy, tokenOf(forCy))).status).toBe(200);
  });

  test("an invite link opened by someone already in: their own, or an unverified email's", async () => {
    const tokenOf = (made: any) => made.data.invite.url.split("/invite/")[1];
    const accept = (token: string, invite: unknown) => call("/api/invites/accept", { token, body: { token: invite } });
    // Its sender, even one addressed to someone else, has nothing to join.
    const forSomeone = await call("/api/invites", { token: ann, body: { email: "someone@else.test" } });
    expect(await accept(ann, tokenOf(forSomeone))).toMatchObject({ status: 200, data: { group: null } });

    // An email-bound invite needs that email verified.
    const open = await call("/api/invites", { token: ann, body: {} });
    const unverified = await signIn("unverified", VERIFIER, tokenOf(open));
    expect(unverified.status).toBe(200);
    const forThem = await call("/api/invites", { token: bo, body: { email: "friend2@team.test" } });
    expect(await accept(unverified.data.token, tokenOf(forThem)))
      .toMatchObject({ status: 403, data: { error: "Verify your email address, then sign in again." } });
  });

  test("an invite to no chat takes someone already in to the chat of just the two of them", async () => {
    const tokenOf = (made: any) => made.data.invite.url.split("/invite/")[1];
    const dot = mint("dot@groups.test", "Dot");
    const dotId = (await state(dot)).me;
    const first = await call("/api/invites", { token: dot, body: {} });
    const pair = (await call("/api/invites/accept", { token: cy, body: { token: tokenOf(first) } })).data.group;
    expect(pair).toMatchObject({ default: false, name: "", created_by: dotId });
    expect(pair.members.sort()).toEqual([cyId, dotId].sort());
    // Not a second chat of the two of them.
    const second = await call("/api/invites", { token: dot, body: {} });
    expect((await call("/api/invites/accept", { token: cy, body: { token: tokenOf(second) } })).data.group.id).toBe(pair.id);
    const addressed = await call("/api/invites", { token: dot, body: { email: "cy@groups.test" } });
    expect((await call("/api/invites/accept", { token: cy, body: { token: tokenOf(addressed) } })).data.group.id).toBe(pair.id);
    expect((await call("/api/invites", { token: dot })).data.invites.map((i: any) => i.id)).not.toContain(addressed.data.invite.id);
    // Opened again, either goes back to that chat.
    expect((await call("/api/invites/accept", { token: cy, body: { token: tokenOf(first) } })).data.group.id).toBe(pair.id);
    expect((await state(cy)).groups.filter((g: any) => g.members.includes(dotId))).toHaveLength(2); // and the default chat
  });

  test("chat links can be fetched, reset and disabled without admitting new people", async () => {
    const chat = (await call("/api/groups", { token: ann, body: { name: "Private secret chat" } })).data.group;
    const path = `/api/groups/${chat.id}/link`;
    expect((await call(path, { token: ann })).data.link).toBeNull();
    for (const method of ["GET", "POST", "DELETE"]) {
      expect((await call(path, { token: bo, method })).status).toBe(404);
      const home = (await state(ann)).groups.find((g: any) => g.default);
      expect((await call(`/api/groups/${home.id}/link`, { token: ann, method })).status).toBe(400);
    }
    const made = await call(path, { token: ann, method: "POST" });
    expect(made.status).toBe(201);
    expect(made.data.link.created_by).toBe(annId);
    expect((await call(path, { token: ann })).data.link).toEqual(made.data.link);
    expect((await call(path, { token: ann, method: "POST" })).data.link).toEqual(made.data.link);
    expect((await call(path, { token: ann, body: { reset: false } })).data.link).toEqual(made.data.link);
    expect((await call(path, { token: ann, body: { reset: "true" } })).status).toBe(400);
    const token = made.data.link.url.split("/invite/")[1];
    expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const page = await fetch(`${api}/invite/${token}`);
    expect(page.status).toBe(200);
    const html = await page.text();
    expect(html).toContain("invited you to a chat on Links");
    expect(html).toContain("personal invite");
    expect(html).not.toContain("Private secret chat");
    const denied = await signIn("chatGuest", VERIFIER, token);
    expect(denied.status).toBe(403);
    expect(denied.data.error).toContain("already on Links");
    expect((await signIn("chatGuest")).status).toBe(403);
    const accept = (value: string) => call("/api/invites/accept", { token: bo, body: { token: value } });
    expect((await accept(token)).data.group.id).toBe(chat.id);
    expect((await accept(token)).data.group.id).toBe(chat.id);
    expect((await call(path, { token: bo })).data.link).toEqual(made.data.link);
    const signed = await signIn("good", VERIFIER, token);
    expect(signed.status).toBe(200);
    expect(signed.data.group_id).toBe(chat.id);
    const reset = await call(path, { token: bo, body: { reset: true } });
    expect(reset.data.link.url).not.toBe(made.data.link.url);
    expect((await accept(token)).status).toBe(404);
    expect((await call(path, { token: bo, method: "DELETE" })).data.link).toBeNull();
    expect((await call(path, { token: ann })).data.link).toBeNull();
    expect((await accept(reset.data.link.url.split("/invite/")[1])).status).toBe(404);
  });

  test("chat links enforce the same member cap as adding people", async () => {
    const chat = (await call("/api/groups", { token: ann, body: { name: "Full" } })).data.group;
    const db = new Database(join(dataDir, "links.db"));
    const { MAX_GROUP_MEMBERS } = await import("../src/accounts.ts");
    for (let i = 1; i < MAX_GROUP_MEMBERS; i++) {
      const id = `open-cap-${i}`;
      db.run("INSERT INTO users (id, name, created_at, member) VALUES (?, 'Cap', 1, 1)", [id]);
      db.run("INSERT INTO group_members (group_id, user_id, joined_at) VALUES (?, ?, 1)", [chat.id, id]);
    }
    db.close();
    const made = await call(`/api/groups/${chat.id}/link`, { token: ann, method: "POST" });
    const token = made.data.link.url.split("/invite/")[1];
    const accept = (who: string) => call("/api/invites/accept", { token: who, body: { token } });
    expect((await accept(bo)).status).toBe(400);
    expect((await accept(ann)).data.group.id).toBe(chat.id);
    const signed = await signIn("good", VERIFIER, token);
    expect(signed.status).toBe(200);
    expect(signed.data.group_id).toBeNull();
    expect(signed.data.token).toBeString();
    expect((await state(signed.data.token)).groups.map((g: any) => g.id)).not.toContain(chat.id);
    expect((await accept(signed.data.token)).status).toBe(400);
  });

  test("signing in with an invite takes first-time and returning users only to the inviter's direct chat", async () => {
    const tokenOf = (made: any) => made.data.invite.url.split("/invite/")[1];
    expect((await signIn("good")).data.group_id).toBeNull();
    const chat = (await call("/api/groups", { token: ann, body: { name: "Riley's" } })).data.group;
    const made = await call("/api/invites", { token: ann, body: { group_id: chat.id } });
    const riley = await signIn("good", VERIFIER, tokenOf(made));
    expect(riley.status).toBe(200);
    const pair = (await state(riley.data.token)).groups.find((g: any) => g.id === riley.data.group_id);
    expect(pair).toMatchObject({ direct: true });
    expect(pair.members.sort()).toEqual([annId, riley.data.user.id].sort());
    // A link that doesn't work doesn't stop them signing in.
    const again = await signIn("good", VERIFIER, "y".repeat(43));
    expect(again.status).toBe(200);
    expect(again.data.group_id).toBeNull();

    // Someone new also lands in their own direct chat, even if the caller sends a group ID.
    const forNeo = await call("/api/invites", { token: ann, body: { group_id: chat.id } });
    const neo = await signIn("neo", VERIFIER, tokenOf(forNeo));
    expect(neo.status).toBe(200);
    const [neoPair] = (await state(neo.data.token)).groups;
    expect(neoPair).toMatchObject({ id: neo.data.group_id, direct: true });
    expect(neoPair.members.sort()).toEqual([annId, neo.data.user.id].sort());
  });

  test("an app from before groups sends to the default chat, or the only chat left", async () => {
    const dee = mint("dee@groups.test", "Dee");
    const everyone = (await state(dee)).groups[0];
    const chat = (await call("/api/groups", { token: dee, body: { name: "Just me" } })).data.group;
    expect(chat.members).toEqual([(await state(dee)).me]);
    await call(`/api/groups/${everyone.id}`, { method: "DELETE", token: dee });
    for (const direct of (await state(dee)).groups.filter((g: any) => g.direct)) {
      await call(`/api/groups/${direct.id}`, { method: "DELETE", token: dee });
    }
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

  test.each(["/g/x", `/g/${"a".repeat(64)}`])("%p is a placeholder page", async (path) => {
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
    const { app, server } = startServer({ ...baseConfig, appStoreId: "6700000000", dataDir: dir });
    try {
      const html = await (await fetch(server.url.origin + "/g/tok_1")).text();
      expect(html).toContain('<meta name="apple-itunes-app" content="app-id=6700000000, app-argument=https://links.example.com/g/tok_1">');
      expect(html).toContain("https://apps.apple.com/app/id6700000000");
      const session = app.accounts.mintSession("banner@example.com", "Private Sender");
      const added = await fetch(server.url.origin + "/api/links", {
        method: "POST", headers: { Authorization: `Bearer ${session}`, "Content-Type": "application/json" },
        body: JSON.stringify({ url: `${origin}/plain?banner=1` }),
      });
      const { link } = await added.json() as any;
      await app.idle();
      for (const platform of ["web", "unknown"]) {
        app.db.run("UPDATE links SET platform = ?, title = NULL WHERE id = ?", [platform, link.id]);
        const webPage = await (await fetch(server.url.origin + `/l/${link.token}`)).text();
        expect(webPage).toContain("A link shared on Links");
        expect(webPage).toContain(">Open the link</a>");
        expect(webPage).not.toContain("Watch on");
      }
      app.db.run("UPDATE links SET platform = 'tiktok', title = NULL WHERE id = ?", [link.id]);
      const page = await (await fetch(server.url.origin + `/l/${link.token}`)).text();
      expect(page).toContain(`app-id=6700000000, app-argument=${link.share_url}`);
      expect(page).toContain("A TikTok shared on Links");
      expect(page).toContain("Watch on TikTok");
      expect(page).not.toContain("Private Sender");
      expect(page).not.toContain("apps.apple.com");
      for (const [platform, title] of [["instagram", "An Instagram shared on Links"], ["x", "An X shared on Links"], ["youtube", "A YouTube shared on Links"]]) {
        app.db.run("UPDATE links SET platform = ?, title = NULL WHERE id = ?", [platform, link.id]);
        expect(await (await fetch(server.url.origin + `/l/${link.token}`)).text()).toContain(`<title>${title}</title>`);
      }
    } finally {
      server.stop(true);
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("deleting an account", () => {
  test("keeps a shared report photo until its last reporter deletes their account", async () => {
    const subject = mint("photo-subject@test.com", "Subject");
    const first = mint("photo-first@test.com", "First");
    const second = mint("photo-second@test.com", "Second");
    const photo = await fetch(api + "/api/me/photo", { method: "PUT", body: PNG, headers: { Authorization: `Bearer ${subject}` } });
    const user = ((await photo.json()) as any).user;
    const copy = join(dataDir, "report-photos", new URL(user.avatar).pathname.split("/")[2]!);
    for (const token of [first, second]) {
      expect((await call("/api/reports", { token, body: { user_id: user.id, reason: "spam" } })).status).toBe(201);
    }
    expect(existsSync(copy)).toBe(true);
    expect((await call("/api/me", { method: "DELETE", token: first })).status).toBe(200);
    expect(existsSync(copy)).toBe(true);
    expect((await call("/api/me", { method: "DELETE", token: second })).status).toBe(200);
    expect(existsSync(copy)).toBe(false);
    expect((await call("/api/me", { method: "DELETE", token: subject })).status).toBe(200);
  });

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
    const photo = await fetch(api + "/api/me/photo", { method: "PUT", body: PNG, headers: { Authorization: `Bearer ${token}` } });
    const photoPath = new URL(((await photo.json()) as any).user.avatar).pathname;
    // A report on Jane keeps its own copy of her photo, which outlives the photo itself.
    expect((await call("/api/reports", { token: friendToken, body: { user_id: janeId, reason: "offensive" } })).status).toBe(201);
    const reportCopy = join(dataDir, "report-photos", photoPath.split("/")[2]!);
    expect(existsSync(reportCopy)).toBe(true);
    // Reporting her again after she changes it keeps the first report, so it makes no second copy.
    await fetch(api + "/api/me/photo", { method: "PUT", body: PNG, headers: { Authorization: `Bearer ${token}` } });
    expect((await call("/api/reports", { token: friendToken, body: { user_id: janeId, reason: "spam" } })).status).toBe(201);
    expect(readdirSync(join(dataDir, "report-photos"))).toEqual([photoPath.split("/")[2]!]);

    expect((await call("/api/me", { method: "DELETE", token })).data).toEqual({ ok: true });
    expect((await fetch(api + photoPath)).status).toBe(404);
    expect(existsSync(join(dataDir, photoPath))).toBe(false);
    expect(existsSync(reportCopy)).toBe(false);

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

describe("comment threads", () => {
  let ann: string, bo: string, cy: string, annId: string, boId: string;
  let sequence = 0;
  const state = async (token: string) => (await call("/api/state", { token })).data;
  const send = async (group_id?: number) => (await call("/api/links", {
    token: ann, body: { url: `${origin}/plain?comments=${++sequence}`, group_id },
  })).data.link;
  const post = (id: number, token: string, body: unknown = "A reply") => call(`/api/links/${id}/comments`, { token, body: { body } });
  const thread = (id: number, token: string) => call(`/api/links/${id}/comments`, { token });
  const summary = async (id: number, token: string) => (await state(token)).links.find((l: any) => l.id === id);

  beforeAll(async () => {
    ann = mint("ann@comments.test", "Comment Ann");
    bo = mint("bo@comments.test", "Comment Bo");
    cy = mint("cy@comments.test", "Comment Cy");
    annId = (await state(ann)).me;
    boId = (await state(bo)).me;
  });

  test("chat members read, post, edit and delete their own comments; summaries stay current", async () => {
    const link = await send();
    expect(link).toMatchObject({ comment_count: 0, last_comment: null });
    expect((await thread(link.id, bo)).data).toEqual({ comments: [] });
    const made = await post(link.id, bo, "  First reply  ");
    expect(made.status).toBe(201);
    const first = made.data.comment;
    expect(first).toEqual({ id: expect.any(Number), link_id: link.id, person: boId, body: "First reply", created_at: expect.any(Number), edited_at: null });
    expect((await thread(link.id, ann)).data.comments).toEqual([first]);
    expect(await summary(link.id, ann)).toMatchObject({ comment_count: 1, last_comment: { person: boId, snippet: "First reply", at: first.created_at } });
    for (const method of ["PATCH", "DELETE"]) {
      expect((await call(`/api/comments/${first.id}`, { token: ann, method, ...(method === "PATCH" ? { body: { body: "Not mine" } } : {}) })).status).toBe(403);
    }
    const edit = await call(`/api/comments/${first.id}`, { token: bo, method: "PATCH", body: { body: "Updated" } });
    expect(edit.data.comment).toMatchObject({ ...first, body: "Updated", edited_at: expect.any(Number) });
    const second = (await post(link.id, ann, "Second reply")).data.comment;
    expect((await thread(link.id, bo)).data.comments.map((c: any) => c.id)).toEqual([first.id, second.id]);
    expect(await summary(link.id, bo)).toMatchObject({ comment_count: 2, last_comment: { person: annId, snippet: "Second reply", at: second.created_at } });
    expect((await call(`/api/comments/${second.id}`, { token: ann, method: "DELETE" })).data).toEqual({ ok: true });
    expect(await summary(link.id, ann)).toMatchObject({ comment_count: 1, last_comment: { person: boId, snippet: "Updated", at: first.created_at } });
    expect((await call(`/api/comments/${first.id}`, { token: bo, method: "DELETE" })).status).toBe(200);
    expect(await summary(link.id, ann)).toMatchObject({ comment_count: 0, last_comment: null });
  });

  test("commenting marks the link seen for the commenter", async () => {
    const link = await send();
    expect((await summary(link.id, ann)).seen).toEqual({});
    const comment = (await post(link.id, bo, "Saw it")).data.comment;
    expect((await summary(link.id, ann)).seen).toEqual({ [boId]: comment.created_at });
    // A later comment keeps the first seen time, and unmarking still works.
    await post(link.id, bo, "Again");
    expect((await summary(link.id, bo)).seen).toEqual({ [boId]: comment.created_at });
    expect(Object.keys((await call(`/api/links/${link.id}/seen`, { token: bo, body: { seen: false } })).data.link.seen)).toEqual([]);
  });

  test("comments require a session, a visible link and current chat membership", async () => {
    const group = (await call("/api/groups", { token: ann, body: { members: [boId] } })).data.group;
    const link = await send(group.id);
    const comment = (await post(link.id, bo)).data.comment;
    expect((await thread(link.id, "")).status).toBe(401);
    expect((await post(link.id, "")).status).toBe(401);
    expect((await thread(link.id, cy)).status).toBe(404);
    expect((await post(link.id, cy)).status).toBe(404);
    expect((await summary(link.id, cy))).toBeUndefined();
    expect((await call(`/api/comments/${comment.id}`, { token: cy, method: "DELETE" })).status).toBe(404);
    await call(`/api/groups/${group.id}`, { token: bo, method: "DELETE" });
    expect((await thread(link.id, bo)).status).toBe(404);
    expect((await call(`/api/comments/${comment.id}`, { token: bo, method: "PATCH", body: { body: "Left" } })).status).toBe(404);
    expect((await call(`/api/comments/${comment.id}`, { token: bo, method: "DELETE" })).status).toBe(404);
    expect((await state(ann)).users.map((u: any) => u.id)).toContain(boId);
    expect((await thread(link.id, ann)).data.comments).toHaveLength(1);
    await call("/api/blocks", { token: cy, body: { user_id: annId } });
    const publicLink = await send();
    expect((await thread(publicLink.id, cy)).status).toBe(404);
    await call(`/api/blocks/${annId}`, { token: cy, method: "DELETE" });
  });

  test("empty or non-text comments are refused, long text is clipped by Unicode character and screened", async () => {
    const link = await send();
    for (const body of ["", " \n ", null, 123, {}, []]) expect((await post(link.id, bo, body)).status).toBe(400);
    const first = (await post(link.id, bo, "😀".repeat(1001))).data.comment;
    expect([...first.body]).toHaveLength(1000);
    expect([...(await summary(link.id, ann)).last_comment.snippet]).toHaveLength(120);
    expect((await post(link.id, bo, "a zonk")).data.error).toContain("comment has a word");
    expect((await call(`/api/comments/${first.id}`, { token: bo, method: "PATCH", body: { body: "zonk" } })).status).toBe(400);
    expect((await thread(link.id, ann)).data.comments[0].body).toBe(first.body);
    for (const id of ["not-an-id", "99999999999999999999"]) {
      expect((await thread(id as any, ann)).status).toBe(404);
      expect((await call(`/api/comments/${id}`, { token: ann, method: "DELETE" })).status).toBe(404);
    }
  });

  test("blocking and reporting hide comments and activity only for the reader", async () => {
    const link = await send();
    const first = (await post(link.id, ann, "Earlier")).data.comment;
    const second = (await post(link.id, bo, "Hidden reply")).data.comment;
    await call("/api/blocks", { token: cy, body: { user_id: boId } });
    expect((await thread(link.id, cy)).data.comments).toEqual([first]);
    expect(await summary(link.id, cy)).toMatchObject({ comment_count: 1, last_comment: { person: annId, snippet: "Earlier", at: first.created_at } });
    expect(await summary(link.id, ann)).toMatchObject({ comment_count: 2 });
    await call(`/api/blocks/${boId}`, { token: cy, method: "DELETE" });
    expect((await thread(link.id, cy)).data.comments).toHaveLength(2);
    expect((await call("/api/reports", { token: cy, body: { comment_id: second.id, reason: "offensive" } })).status).toBe(201);
    expect((await call("/api/reports", { token: cy, body: { comment_id: second.id, reason: "offensive" } })).status).toBe(201);
    expect((await thread(link.id, cy)).data.comments).toEqual([first]);
    expect(await summary(link.id, cy)).toMatchObject({ comment_count: 1, last_comment: { snippet: "Earlier" } });
    expect(await summary(link.id, bo)).toMatchObject({ comment_count: 2 });
    expect((await call("/api/reports", { token: bo, body: { comment_id: second.id, reason: "spam" } })).status).toBe(400);
    await call("/api/reports", { token: cy, body: { link_id: link.id, reason: "spam" } });
    expect((await thread(link.id, cy)).status).toBe(404);
  });

  test("summaries respect chat filters, match link mutation responses and break timestamp ties by ID", async () => {
    const group = (await call("/api/groups", { token: ann, body: { members: [boId] } })).data.group;
    const link = await send(group.id);
    const other = await send();
    const first = (await post(link.id, ann, "First")).data.comment;
    const second = (await post(link.id, bo, "Second")).data.comment;
    await post(other.id, ann, "Other chat");
    const db = openDatabase(dataDir);
    db.run("UPDATE comments SET created_at = ? WHERE id IN (?, ?)", [first.created_at, first.id, second.id]);
    db.close();
    const filtered = (await call(`/api/state?group_id=${group.id}`, { token: ann })).data;
    expect(filtered.links.map((l: any) => l.id)).toEqual([link.id]);
    const want = { comment_count: 2, last_comment: { person: boId, snippet: "Second", at: first.created_at } };
    expect(filtered.links[0]).toMatchObject(want);
    expect((await call(`/api/links/${link.id}/seen`, { token: ann, body: { seen: true } })).data.link).toMatchObject(want);
    await call("/api/blocks", { token: ann, body: { user_id: boId } });
    expect((await call(`/api/links/${link.id}/seen`, { token: ann, body: { seen: true } })).data.link).toMatchObject({
      comment_count: 1, last_comment: { person: annId, snippet: "First", at: first.created_at },
    });
    await call(`/api/blocks/${boId}`, { token: ann, method: "DELETE" });
  });

  test("deleting a link cascades comments and never reuses comment IDs", async () => {
    const link = await send();
    const first = (await post(link.id, bo)).data.comment;
    await call(`/api/links/${link.id}`, { token: ann, method: "DELETE" });
    expect((await thread(link.id, bo)).status).toBe(404);
    expect((await call(`/api/comments/${first.id}`, { token: bo, method: "DELETE" })).status).toBe(404);
    const db = openDatabase(dataDir);
    expect(db.query("SELECT * FROM comments WHERE link_id = ?").all(link.id)).toEqual([]);
    db.close();
    const next = await send();
    expect((await post(next.id, bo)).data.comment.id).toBeGreaterThan(first.id);
  });
});
