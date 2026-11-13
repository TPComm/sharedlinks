/**
 * End to end: the compiled `links-server` (what deploy.sh ships) as a real process, driven over
 * HTTP and its CLI. Offline: WorkOS is a stub in this process that checks PKCE like the real one,
 * and the binary's outbound HTTP goes to a local trap (see startEgressTrap).
 *
 *   bun run test:e2e                                           build for this machine, then test it
 *   LINKS_BINARY=dist/links-server-linux-x64 bun run test:e2e  test an existing build (CI does)
 */
import { Database } from "bun:sqlite";
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import {
  killAll, locateBinary, pkce, request, runProcess, s256, startEgressTrap, startServer, until, withLogs, type Server,
} from "./harness.ts";

const CLIENT_ID = "client_E2E";
const PUBLIC_URL = "https://links.e2e.test";
const TIKTOK = "https://www.tiktok.com/@/video/7506136711311772958";
const TOKEN = /^[A-Za-z0-9_-]{43}$/;

const tmp = mkdtempSync(join(tmpdir(), "links-e2e-"));
const cwd = join(tmp, "cwd"); // every process starts here, so nothing relative lands in the repo
mkdirSync(cwd);
let binary: string;
const egress = startEgressTrap();

/** Who AuthKit signs in, picked with ?e2e_user= on its hosted page (standing in for a password). */
const PEOPLE: Record<string, object> = {
  alice: { id: "user_01ALICE", email: "alice@example.com", email_verified: true, first_name: "Alice", profile_picture_url: "https://example.com/alice.png" },
  bob: { id: "user_01BOB", email: "bob.smith@team.test", email_verified: true, first_name: "", profile_picture_url: null },
  stranger: { id: "user_01STRANGER", email: "stranger@evil.test", email_verified: true },
  unverified: { id: "user_01UNVERIFIED", email: "new@team.test", email_verified: false },
};
const grants = new Map<string, { user: object; challenge: string }>();
const exchanges: Record<string, string>[] = [];

/** A stand-in for api.workos.com: the hosted sign-in page and the code exchange. */
const workos = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  routes: {
    "/user_management/authorize": {
      GET: (req) => {
        const q = new URL(req.url).searchParams;
        const user = PEOPLE[q.get("e2e_user") ?? ""];
        if (!user || q.get("client_id") !== CLIENT_ID || q.get("code_challenge_method") !== "S256" || !q.get("redirect_uri")) {
          return Response.json({ error: "invalid_request" }, { status: 400 });
        }
        const code = crypto.randomUUID();
        grants.set(code, { user, challenge: q.get("code_challenge") ?? "" });
        const back = new URL(q.get("redirect_uri")!);
        back.searchParams.set("code", code);
        back.searchParams.set("state", q.get("state") ?? "");
        return Response.redirect(back.href, 302);
      },
    },
    "/user_management/authenticate": {
      POST: async (req) => {
        const body = (await req.json()) as Record<string, string>;
        exchanges.push(body);
        const grant = grants.get(body.code ?? "");
        grants.delete(body.code ?? ""); // single use
        if (!grant || body.client_id !== CLIENT_ID) {
          return Response.json({ error: "invalid_grant", error_description: "Invalid authorization code." }, { status: 400 });
        }
        if (s256(body.code_verifier ?? "") !== grant.challenge) {
          return Response.json({ error: "invalid_grant", error_description: "Invalid code verifier." }, { status: 400 });
        }
        return Response.json({ user: grant.user, access_token: "jwt", refresh_token: "refresh" });
      },
    },
  },
});

/** A page with a preview. The binary must never fetch it: 127.0.0.1 is a private address. */
const originHits: string[] = [];
const fakeOrigin = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  fetch(req) {
    originHits.push(new URL(req.url).pathname);
    return new Response(`<html><head><meta property="og:title" content="Fetched"><meta property="og:image" content="/t.png"></head></html>`,
      { headers: { "Content-Type": "text/html" } });
  },
});
const origin = `http://127.0.0.1:${fakeOrigin.port}`;

function env(overrides: Record<string, string | undefined> = {}) {
  return {
    PATH: process.env.PATH,
    HOST: "127.0.0.1",
    PORT: "0",
    PUBLIC_URL: `${PUBLIC_URL}/`, // the trailing slash is trimmed
    WORKOS_CLIENT_ID: CLIENT_ID,
    WORKOS_API: workos.url.href,
    ALLOWED_EMAILS: " alice@example.com , @team.test",
    ...egress.env,
    ...overrides,
  };
}

const cli = (dataDir: string, ...args: string[]) =>
  runProcess(`links-server ${args.join(" ")}`, [binary, ...args], { cwd, env: env({ DATA_DIR: dataDir }) });

/** test() whose failure message carries every process's output. */
const e2e = (name: string, fn: () => unknown, timeoutMs = 30_000) =>
  test(name, () => withLogs(fn, () => (egress.attempts.length ? `--- egress attempts ---\n${egress.attempts.join("\n")}` : "")), timeoutMs);

/** Output arrives through a pipe, so wait for it rather than read it once. */
const printed = (server: Server, stream: "stdout" | "stderr", text: string) =>
  until(`${server.name} to print ${JSON.stringify(text)}`, () => server[stream].includes(text), 5000, server);

const linkIn = (state: any, id: number) => state.links.find((l: any) => l.id === id);

beforeAll(async () => {
  binary = await locateBinary(tmp);
}, 180_000);

afterAll(() => {
  killAll();
  workos.stop(true);
  fakeOrigin.stop(true);
  egress.stop();
  rmSync(tmp, { recursive: true, force: true });
});

describe("a day with Links", () => {
  const dataDir = join(tmp, "journey");
  let server: Server;
  const alice = { token: "", id: "" };
  const bob = { token: "", id: "" };
  let shared = 0;
  let tiktok = 0;
  const call = (path: string, opts?: Parameters<typeof request>[2]) => request(server.url, path, opts);

  beforeAll(() => withLogs(async () => {
    server = await startServer("links-server", binary, { cwd, env: env({ DATA_DIR: dataDir }) });
  }), 30_000);

  afterAll(async () => {
    if (server?.running) await server.stop();
  });

  /** The app's sign-in: /auth/authorize -> AuthKit -> /auth/callback -> sharedlinks:// (code, verifier). */
  async function authorize(person: string) {
    const { verifier, challenge } = pkce();
    const state = crypto.randomUUID();
    const start = await call(`/auth/authorize?${new URLSearchParams({ code_challenge: challenge, state, screen_hint: "sign-in" })}`);
    expect(start.status, start.text).toBe(302);
    const authkit = new URL(start.headers.get("location")!);
    const params = Object.fromEntries(authkit.searchParams);
    // AuthKit's hosted page signs the person in and sends the browser to redirect_uri.
    authkit.searchParams.set("e2e_user", person);
    const hosted = await fetch(authkit, { redirect: "manual" });
    expect(hosted.status).toBe(302);
    const callback = new URL(hosted.headers.get("location")!);
    expect(callback.origin + callback.pathname).toBe(`${PUBLIC_URL}/auth/callback`);
    // In production Caddy serves PUBLIC_URL and proxies to the binary.
    const bounce = await call(callback.pathname + callback.search);
    expect(bounce.status, bounce.text).toBe(302);
    expect(bounce.headers.get("location")).toBe(`sharedlinks://auth/callback${callback.search}`);
    expect(callback.searchParams.get("state")).toBe(state);
    return { endpoint: authkit.origin + authkit.pathname, params, state, challenge, verifier, code: callback.searchParams.get("code")! };
  }

  const exchange = (code: string, verifier: string) =>
    call("/api/auth/token", { body: { code, code_verifier: verifier }, headers: { "User-Agent": "Links/1.0 (e2e)" } });

  async function signIn(person: string) {
    const { code, verifier } = await authorize(person);
    const res = await exchange(code, verifier);
    expect(res.status, res.text).toBe(200);
    return res.data;
  }

  e2e("starts, says where it is and answers health checks", async () => {
    expect(server.stdout).toContain(`Links API running on ${server.url}/ (sign-in redirect: ${PUBLIC_URL}/auth/callback)`);
    expect(server.stderr).not.toContain("warning:");
    const health = await call("/healthz");
    expect([health.status, health.text]).toEqual([200, "ok\n"]);
    const home = await call("/");
    expect(home.status).toBe(200);
    expect(home.headers.get("content-type")).toBe("text/plain; charset=utf-8");
    expect(home.text).toContain("Links API");
    expect(await call("/nope")).toMatchObject({ status: 404, data: { error: "Not found" } });
  });

  e2e("needs a session for everything but signing in", async () => {
    const routes = [
      ["GET", "/api/state"], ["GET", "/api/me"], ["PATCH", "/api/me"], ["POST", "/api/me/claim"],
      ["POST", "/api/links"], ["PATCH", "/api/links/1"], ["DELETE", "/api/links/1"], ["POST", "/api/links/1/seen"],
      ["POST", "/api/links/1/react"], ["GET", "/thumbs/1"], ["POST", "/api/auth/logout"],
    ] as const;
    for (const [method, path] of routes) {
      for (const token of [undefined, "not-a-session"]) {
        const res = await call(path, { method, token, body: method === "GET" ? undefined : {} });
        expect(res, `${method} ${path} (${token ?? "no token"})`).toMatchObject({ status: 401, data: { error: "Sign in to continue." } });
      }
    }
  });

  e2e("signs people in with AuthKit and PKCE", async () => {
    const a = await authorize("alice");
    expect(a.endpoint).toBe(`${workos.url.origin}/user_management/authorize`);
    expect(a.params).toEqual({
      client_id: CLIENT_ID, response_type: "code", provider: "authkit", redirect_uri: `${PUBLIC_URL}/auth/callback`,
      code_challenge: a.challenge, code_challenge_method: "S256", state: a.state, screen_hint: "sign-in",
    });
    const res = await exchange(a.code, a.verifier);
    expect(res.status, res.text).toBe(200);
    expect(res.data.token).toMatch(TOKEN);
    expect(res.data.user).toEqual({ id: "user_01ALICE", name: "Alice", avatar: "https://example.com/alice.png", email: "alice@example.com" });
    expect(res.data.claimable).toEqual([]);
    // PKCE without a client secret: the verifier goes to WorkOS, and nothing else secret.
    expect(exchanges.at(-1)).toEqual({
      client_id: CLIENT_ID, grant_type: "authorization_code", code: a.code, code_verifier: a.verifier, user_agent: "Links/1.0 (e2e)",
    });
    Object.assign(alice, { token: res.data.token, id: res.data.user.id });

    // On the guest list by domain (@team.test). No first name, so the name comes from the email.
    const b = await signIn("bob");
    expect(b.user).toEqual({ id: "user_01BOB", name: "Bob Smith", avatar: null, email: "bob.smith@team.test" });
    Object.assign(bob, { token: b.token, id: b.user.id });
  });

  e2e("turns away strangers, unverified emails and a wrong PKCE verifier", async () => {
    const stranger = await authorize("stranger");
    expect(await exchange(stranger.code, stranger.verifier))
      .toMatchObject({ status: 403, data: { error: "stranger@evil.test isn't on the guest list for this Links." } });
    const unverified = await authorize("unverified");
    expect(await exchange(unverified.code, unverified.verifier))
      .toMatchObject({ status: 403, data: { error: "Verify your email address, then sign in again." } });
    // 400, not 401: the app reads 401 as "your session ended" and would hide the message.
    const wrong = await authorize("alice");
    expect(await exchange(wrong.code, pkce().verifier)).toMatchObject({ status: 400, data: { error: "Invalid code verifier." } });
    expect(await exchange(wrong.code, wrong.verifier)).toMatchObject({ status: 400, data: { error: "Invalid authorization code." } });
    expect(await exchange("", "")).toMatchObject({ status: 400, data: { error: "Missing authorization code." } });
    expect(await call("/auth/authorize?code_challenge=short&state=x")).toMatchObject({ status: 400, data: { error: "Bad sign-in request." } });
    const { data } = await call("/api/state", { token: alice.token });
    expect(data.users.map((u: any) => u.id).sort()).toEqual([alice.id, bob.id].sort());
  });

  e2e("reads and renames the signed-in person", async () => {
    expect((await call("/api/me", { token: bob.token })).data)
      .toEqual({ user: { id: bob.id, name: "Bob Smith", avatar: null, email: "bob.smith@team.test" }, claimable: [] });
    expect((await call("/api/me", { method: "PATCH", token: alice.token, body: { name: "  Ally   A  " } })).data.user.name).toBe("Ally A");
    expect((await call("/api/me", { token: alice.token })).data.user.name).toBe("Ally A");
    expect(await call("/api/me", { method: "PATCH", token: alice.token, body: { name: "   " } }))
      .toMatchObject({ status: 400, data: { error: "Missing name." } });
  });

  e2e("shares a link: unseen by the other person, then seen, reacted to and noted", async () => {
    const add = await call("/api/links", { token: alice.token, body: { text: `lol look ${origin}/video?utm_source=share&id=7 !!`, note: "  for you  " } });
    expect(add.status, add.text).toBe(201);
    expect(add.data).toMatchObject({
      duplicate: false,
      link: { url: `${origin}/video?id=7`, platform: "web", note: "for you", added_by: alice.id, seen: {}, reactions: {} },
    });
    shared = add.data.link.id;

    const inbox = (await call("/api/state", { token: bob.token })).data;
    expect(inbox.me).toBe(bob.id);
    expect(inbox.users).toEqual([
      { id: alice.id, name: "Ally A", avatar: "https://example.com/alice.png" },
      { id: bob.id, name: "Bob Smith", avatar: null },
    ]);
    expect(linkIn(inbox, shared)).toMatchObject({ added_by: alice.id, seen: {}, reactions: {} });

    const seen = (await call(`/api/links/${shared}/seen`, { token: bob.token, body: {} })).data.link.seen;
    expect(Object.keys(seen)).toEqual([bob.id]);
    expect(Math.abs(seen[bob.id] - Date.now() / 1000)).toBeLessThan(60);
    const react = (emoji: string) => call(`/api/links/${shared}/react`, { token: bob.token, body: { emoji } });
    expect((await react("🔥")).data.link.reactions).toEqual({ [bob.id]: "🔥" });
    expect((await react("💩")).data.link.reactions).toEqual({}); // not one of the six: clears it
    expect((await react("😂")).data.link.reactions).toEqual({ [bob.id]: "😂" });

    const mine = linkIn((await call("/api/state", { token: alice.token })).data, shared);
    expect(Object.keys(mine.seen)).toEqual([bob.id]);
    expect(mine.reactions).toEqual({ [bob.id]: "😂" });

    const note = "watch till the end\n(trust me)";
    expect((await call(`/api/links/${shared}`, { method: "PATCH", token: alice.token, body: { note } })).data.link.note).toBe(note);
    expect(linkIn((await call("/api/state", { token: bob.token })).data, shared).note).toBe(note);
  });

  e2e("spots the same link spelled differently, TikTok tracking included", async () => {
    const again = await call("/api/links", { token: bob.token, body: { url: `${origin}/video/?id=7&fbclid=abc` } });
    expect(again.status, again.text).toBe(200);
    expect(again.data).toMatchObject({ duplicate: true, link: { id: shared } });

    const first = await call("/api/links", {
      token: alice.token, body: { url: "https://www.tiktok.com/@someone/video/7506136711311772958?_r=1&_t=ZS-92jrA0wKM6y&is_from_webapp=1" },
    });
    expect(first.status, first.text).toBe(201);
    expect(first.data.link).toMatchObject({ url: TIKTOK, platform: "tiktok" });
    tiktok = first.data.link.id;
    const second = await call("/api/links", { token: bob.token, body: { text: "😂 https://m.tiktok.com/v/7506136711311772958.html?u_code=x" } });
    expect(second.status, second.text).toBe(200);
    expect(second.data).toMatchObject({ duplicate: true, link: { id: tiktok, url: TIKTOK } });

    expect(await call("/api/links", { token: bob.token, body: { text: "no link here" } }))
      .toMatchObject({ status: 400, data: { error: "That doesn't look like a link." } });
    const urls = (await call("/api/state", { token: bob.token })).data.links.map((l: any) => l.url);
    expect(urls.sort()).toEqual([`${origin}/video?id=7`, TIKTOK].sort());
  });

  e2e("won't fetch a preview from a private address (the SSRF guard)", async () => {
    const link = await until("the preview attempt to finish", async () => {
      const l = linkIn((await call("/api/state", { token: alice.token })).data, shared);
      return l.meta !== "pending" && l;
    }, 10_000, server);
    expect(link).toMatchObject({ meta: "failed", title: null, author: null, thumb: null });
    expect(originHits).toEqual([]);
    await printed(server, "stderr", `preview failed for ${origin}/video?id=7: `);
    await printed(server, "stderr", "Refusing to fetch private address for 127.0.0.1");
    for (const path of [`/thumbs/${shared}`, "/thumbs/999999", "/thumbs/abc"]) {
      expect(await call(path, { token: alice.token }), path).toMatchObject({ status: 404 });
    }
  });

  e2e("logs one line per request, except inbox polling", async () => {
    await printed(server, "stdout", "POST /api/links 201\n");
    await printed(server, "stdout", "POST /api/auth/token 403\n");
    expect(server.stdout).not.toContain("/api/state");
  });

  e2e("refuses request bodies over 64 KB", async () => {
    const res = await call("/api/links", { token: alice.token, body: JSON.stringify({ text: "x".repeat(70_000) }) });
    expect(res.status).toBe(413);
  });

  e2e("deletes a link for everyone, and never reuses its id", async () => {
    expect((await call(`/api/links/${shared}`, { method: "DELETE", token: alice.token })).data).toEqual({ ok: true });
    expect(linkIn((await call("/api/state", { token: bob.token })).data, shared)).toBeUndefined();
    expect(await call(`/api/links/${shared}/seen`, { token: bob.token, body: {} }))
      .toMatchObject({ status: 404, data: { error: "That link was deleted." } });
    expect((await call(`/api/links/${shared}`, { method: "DELETE", token: alice.token })).status).toBe(404);
    const back = await call("/api/links", { token: bob.token, body: { url: `${origin}/video?id=7` } });
    expect(back.status, back.text).toBe(201);
    expect(back.data.link.id).toBeGreaterThan(shared);
  });

  e2e("logs out one session and leaves the others", async () => {
    const second = await signIn("alice");
    expect(second.user.name).toBe("Ally A"); // signing in again keeps the name they chose
    expect((await call("/api/auth/logout", { method: "POST", token: second.token })).data).toEqual({ ok: true });
    expect((await call("/api/me", { token: second.token })).status).toBe(401);
    expect((await call("/api/me", { token: alice.token })).status).toBe(200);
  });

  e2e("mint-session prints a token the running server accepts", async () => {
    const existing = await cli(dataDir, "mint-session", "alice@example.com");
    expect(existing.code, existing.logs()).toBe(0);
    expect(existing.stdout.trim()).toMatch(TOKEN);
    expect((await call("/api/me", { token: existing.stdout.trim() })).data.user).toMatchObject({ id: alice.id, name: "Ally A" });

    const carol = await cli(dataDir, "mint-session", "carol@team.test", "Carol", "Jones");
    expect(carol.code, carol.logs()).toBe(0);
    const me = (await call("/api/me", { token: carol.stdout.trim() })).data.user;
    expect(me).toMatchObject({ name: "Carol Jones", email: "carol@team.test" });
    expect(me.id).toMatch(/^local_[0-9a-f]{16}$/);

    // Not a way around the guest list: that's checked on every request.
    const mallory = await cli(dataDir, "mint-session", "mallory@evil.test");
    expect(mallory.code, mallory.logs()).toBe(0);
    expect((await call("/api/me", { token: mallory.stdout.trim() })).status).toBe(401);
  });

  e2e("delete-user deletes an account the running server knows; its links stay, from no one", async () => {
    const carol = (await cli(dataDir, "mint-session", "carol@team.test")).stdout.trim();
    const id = (await call("/api/me", { token: carol })).data.user.id;
    const sent = await call("/api/links", { token: carol, body: { url: `${origin}/from-carol` } });
    expect(sent.status, sent.text).toBe(201);

    const run = await cli(dataDir, "delete-user", "Carol@Team.test");
    expect(run.code, run.logs()).toBe(0);
    // No WORKOS_API_KEY here, and a local_ id isn't a WorkOS user anyway.
    expect(run.stdout).toBe(`deleted Carol Jones (${id}); 1 sent link kept as "Deleted user"; WorkOS user: skipped\n`);
    expect((await call("/api/me", { token: carol })).status).toBe(401);
    const state = (await call("/api/state", { token: alice.token })).data;
    expect(linkIn(state, sent.data.link.id).added_by).toBe("deleted");
    expect(state.users.map((u: any) => u.id)).not.toContain(id);

    const again = await cli(dataDir, "delete-user", "carol@team.test");
    expect([again.code, again.stdout, again.stderr]).toEqual([1, "", "no account with the email carol@team.test\n"]);
  });

  e2e("exits 1 with a message for mint-session without an email, or an unknown command", async () => {
    const usage = await cli(dataDir, "mint-session");
    expect([usage.code, usage.stdout, usage.stderr]).toEqual([1, "", "usage: links-server mint-session <email> [name]\n"]);
    for (const args of [["delete-user"], ["delete-user", "a@example.com", "b@example.com"]]) {
      const run = await cli(dataDir, ...args);
      expect([run.code, run.stdout, run.stderr]).toEqual([1, "", "usage: links-server delete-user <email>\n"]);
    }
    const unknown = await cli(dataDir, "frobnicate");
    expect([unknown.code, unknown.stdout, unknown.stderr]).toEqual([1, "", "unknown command: frobnicate\n"]);
  });

  e2e("backup snapshots the live database and keeps the newest 14", async () => {
    const dir = join(tmp, "backups");
    mkdirSync(dir);
    const old = Array.from({ length: 16 }, (_, i) => `links-2000-01-${String(i + 1).padStart(2, "0")}.db`);
    for (const name of [...old, "links-latest.db", "notes.txt"]) writeFileSync(join(dir, name), "old");
    const days = [new Date().toISOString().slice(0, 10)];
    const run = await cli(dataDir, "backup", dir);
    days.push(new Date().toISOString().slice(0, 10)); // in case it ran across midnight UTC
    expect(run.code, run.logs()).toBe(0);
    const file = run.stdout.match(/^backed up to (.+)\n$/)?.[1] ?? "";
    expect(days.map((d) => join(dir, `links-${d}.db`))).toContain(file);
    // The three oldest dated snapshots go; anything else in the folder stays.
    expect(readdirSync(dir).sort()).toEqual([...old.slice(3), basename(file), "links-latest.db", "notes.txt"]);

    const live = (await call("/api/state", { token: alice.token })).data;
    const snapshot = new Database(file, { readonly: true });
    try {
      expect(snapshot.query("PRAGMA integrity_check").get()).toEqual({ integrity_check: "ok" });
      expect(snapshot.query("PRAGMA user_version").get()).toEqual({ user_version: 4 });
      expect(snapshot.query("SELECT id, url FROM links ORDER BY id").all())
        .toEqual(live.links.map((l: any) => ({ id: l.id, url: l.url })).sort((a: any, b: any) => a.id - b.id));
      expect(snapshot.query("SELECT name FROM users WHERE id = ?").get(alice.id)).toEqual({ name: "Ally A" });
    } finally {
      snapshot.close();
    }

    // Without a folder: DATA_DIR/backups.
    const fallback = await cli(dataDir, "backup");
    expect(fallback.code, fallback.logs()).toBe(0);
    expect(readdirSync(join(dataDir, "backups"))).toEqual([expect.stringMatching(/^links-\d{4}-\d{2}-\d{2}\.db$/)]);
  });

  e2e("exits 0 promptly on SIGTERM, and keeps everything across a restart", async () => {
    await call(`/api/links/${tiktok}/seen`, { token: bob.token, body: {} });
    await call(`/api/links/${tiktok}/react`, { token: bob.token, body: { emoji: "❤️" } });
    const before = (await call("/api/state", { token: bob.token })).data;
    expect(linkIn(before, tiktok).reactions).toEqual({ [bob.id]: "❤️" });

    const { code, ms } = await server.stop("SIGTERM");
    expect(code).toBe(0);
    expect(ms).toBeLessThan(3000);
    server = await startServer("links-server (restarted)", binary, { cwd, env: env({ DATA_DIR: dataDir }) });

    // Same sessions, people, links, notes, receipts and reactions. (Previews may have moved on.)
    const after = (await call("/api/state", { token: bob.token })).data;
    const kept = (state: any) => state.links
      .map((l: any) => ({ id: l.id, url: l.url, note: l.note, added_by: l.added_by, seen: l.seen, reactions: l.reactions }))
      .sort((a: any, b: any) => a.id - b.id);
    expect(kept(after)).toEqual(kept(before));
    expect(after.users).toEqual(before.users);
    expect((await call("/api/me", { token: alice.token })).data.user.name).toBe("Ally A");
  });
});

describe("upgrading a database from the web-app days (v0)", () => {
  const dataDir = join(tmp, "v0");
  let server: Server;
  let token = "";
  const call = (path: string, opts?: Parameters<typeof request>[2]) => request(server.url, path, opts);

  beforeAll(() => withLogs(async () => {
    mkdirSync(dataDir);
    // People were typed names; the links table had no AUTOINCREMENT; one preview never finished.
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
      INSERT INTO links (url, platform, added_by, added_at) VALUES ('${origin}/pending', 'web', 'Alex', 7);
      INSERT INTO seen VALUES (1, 'Alex', 11);
      INSERT INTO reactions VALUES (1, 'Alex', '🔥');
    `);
    legacy.close();
    server = await startServer("links-server (v0 data)", binary, { cwd, env: env({ DATA_DIR: dataDir }) });
    const mint = await cli(dataDir, "mint-session", "alice@example.com");
    expect(mint.code, mint.logs()).toBe(0);
    token = mint.stdout.trim();
  }), 30_000);

  afterAll(async () => {
    if (server?.running) await server.stop();
  });

  e2e("migrates to user_version 4 and keeps the history under legacy people", async () => {
    const db = new Database(join(dataDir, "links.db"), { readonly: true });
    try {
      expect(db.query("PRAGMA user_version").get()).toEqual({ user_version: 4 });
      expect((db.query("SELECT sql FROM sqlite_master WHERE name = 'links'").get() as { sql: string }).sql).toContain("AUTOINCREMENT");
      expect(db.query("SELECT name FROM sqlite_master WHERE name = 'people'").get()).toBeNull();
    } finally {
      db.close();
    }
    const state = (await call("/api/state", { token })).data;
    expect(linkIn(state, 1)).toMatchObject({
      url: "https://www.youtube.com/watch?v=old", added_by: "legacy:Sam", seen: { "legacy:Alex": 11 }, reactions: { "legacy:Alex": "🔥" },
    });
    expect(linkIn(state, 2).url).toBe("https://de.wikipedia.org/wiki/M%C3%BCnchen");
    expect(linkIn(state, 3).url).toBe(TIKTOK);
    expect((await call("/api/me", { token })).data.claimable.map((u: any) => u.id)).toEqual(["legacy:Sam", "legacy:Alex"]);
  });

  e2e("finds old links when they're shared again, TikTok tracking included", async () => {
    const tiktok = await call("/api/links", { token, body: { url: "https://www.tiktok.com/@new_handle/video/7506136711311772958?_r=1&_t=ZS-abc" } });
    expect(tiktok.data).toMatchObject({ duplicate: true, link: { id: 3, title: "A TikTok" } });
    const munich = await call("/api/links", { token, body: { url: "https://de.wikipedia.org/wiki/München" } });
    expect(munich.data).toMatchObject({ duplicate: true, link: { id: 2 } });
  });

  e2e("retries a preview left pending at startup, behind the same SSRF guard", async () => {
    const link = await until("the pending preview to be retried", async () => {
      const l = linkIn((await call("/api/state", { token })).data, 4);
      return l.meta !== "pending" && l;
    }, 10_000, server);
    expect(link).toMatchObject({ url: `${origin}/pending`, meta: "failed", title: null });
    await printed(server, "stderr", `preview failed for ${origin}/pending`);
    expect(originHits).toEqual([]);
  });

  e2e("lets a signed-in person claim a legacy person's history", async () => {
    const claim = await call("/api/me/claim", { token, body: { id: "legacy:Sam" } });
    expect(claim.status, claim.text).toBe(200);
    expect(claim.data.user.name).toBe("Sam");
    expect(claim.data.claimable.map((u: any) => u.id)).toEqual(["legacy:Alex"]);
    const state = (await call("/api/state", { token })).data;
    expect(linkIn(state, 1).added_by).toBe(state.me);
  });

  e2e("exits 0 on SIGINT too", async () => {
    expect((await server.stop("SIGINT")).code).toBe(0);
  });
});

describe("a server that isn't set up yet", () => {
  e2e("warns about WORKOS_CLIENT_ID and ALLOWED_EMAILS, and ignores a stray .env", async () => {
    const dir = join(tmp, "unconfigured");
    mkdirSync(dir);
    // Built with --no-compile-autoload-dotenv: a .env in the working directory must not configure it.
    writeFileSync(join(dir, ".env"), "WORKOS_CLIENT_ID=client_FROM_DOTENV\nALLOWED_EMAILS=someone@example.com\n");
    const server = await startServer("links-server (unconfigured)", binary, {
      cwd: dir, env: env({ WORKOS_CLIENT_ID: undefined, ALLOWED_EMAILS: undefined, DATA_DIR: undefined }),
    });
    try {
      await printed(server, "stderr", "warning: WORKOS_CLIENT_ID isn't set, so nobody can sign in.\n");
      await printed(server, "stderr", "warning: ALLOWED_EMAILS isn't set, so anyone who can sign in to your AuthKit can see and add links.\n");
      const unavailable = { status: 503, data: { error: "Sign-in isn't set up on the server (WORKOS_CLIENT_ID)." } };
      expect(await request(server.url, `/auth/authorize?code_challenge=${pkce().challenge}&state=x`)).toMatchObject(unavailable);
      expect(await request(server.url, "/api/auth/token", { body: { code: "c", code_verifier: "v" } })).toMatchObject(unavailable);
      // Without DATA_DIR the database goes in ./data, relative to where it was started.
      expect(existsSync(join(dir, "data", "links.db"))).toBe(true);
    } finally {
      expect((await server.stop()).code).toBe(0);
    }
  });
});
