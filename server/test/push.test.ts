import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import http2 from "node:http2";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../src/app.ts";
import { configFromEnv } from "../src/config.ts";

const VERIFIER = "v".repeat(43);
const dataDir = mkdtempSync(join(tmpdir(), "links-push-"));
const LONG_TITLE = "🐱".repeat(300);

const users: Record<string, object> = {
  sam: { id: "user_01SAM", email: "sam@team.test", email_verified: true, first_name: "Sam" },
  alex: { id: "user_01ALEX", email: "alex@team.test", email_verified: true, first_name: "Alex" },
  kim: { id: "user_01KIM", email: "kim@team.test", email_verified: true, first_name: "Kim" },
  gone: { id: "user_01GONE", email: "gone@other.test", email_verified: true, first_name: "Gone" },
};
const fakeWorkOS = Bun.serve({
  port: 0,
  routes: {
    "/user_management/authenticate": {
      POST: async (req) => {
        const body = await req.json() as Record<string, any>;
        return Response.json({ user: users[body.code], access_token: "jwt", refresh_token: "r" });
      },
    },
  },
});
const fakeOrigin = Bun.serve({
  port: 0,
  routes: {
    "/video": new Response(`<html><head><meta property="og:title" content="Cats &amp; Dogs"></head></html>`, { headers: { "Content-Type": "text/html" } }),
    "/long": new Response(`<html><head><title>${LONG_TITLE}</title></head></html>`, { headers: { "Content-Type": "text/html" } }),
    "/slow": async () => { await Bun.sleep(1500); return new Response("<title>Too late</title>", { headers: { "Content-Type": "text/html" } }); },
  },
});

interface Sent { env: string; token: string; headers: http2.IncomingHttpHeaders; body: any; jwt: string }
/** Answers per token, in order, then 200. */
const replies = new Map<string, { status: number; body?: object }[]>();
let sent: Sent[] = [];
function fakeApns(env: string) {
  const server = http2.createServer();
  server.on("stream", (stream: http2.ServerHttp2Stream, headers) => {
    let data = "";
    stream.setEncoding("utf8");
    stream.on("data", (c) => { data += c; });
    stream.on("end", () => {
      const token = String(headers[":path"]).replace("/3/device/", "");
      sent.push({ env, token, headers, body: JSON.parse(data), jwt: String(headers.authorization).replace("bearer ", "") });
      const queue = [replies.get(`${env}:${token}`), replies.get(token)].find((q) => q?.length);
      const reply = queue?.shift() ?? { status: 200 };
      stream.respond({ ":status": reply.status, "apns-id": crypto.randomUUID() });
      stream.end(reply.body ? JSON.stringify(reply.body) : undefined);
    });
  });
  return new Promise<{ server: http2.Http2Server; url: string }>((resolve) =>
    server.listen(0, "127.0.0.1", () => resolve({ server, url: `http://127.0.0.1:${(server.address() as any).port}` })));
}

let api: string;
let app: ReturnType<typeof startServer>["app"];
let stop: () => void;
let publicKey: CryptoKey;
let apnsServers: http2.Http2Server[] = [];
const allowedEmails = ["@team.test", "gone@other.test"];

async function call(path: string, opts: { method?: string; token?: string; body?: unknown } = {}) {
  const res = await fetch(api + path, {
    method: opts.method ?? (opts.body ? "POST" : "GET"),
    headers: { ...(opts.token ? { Authorization: `Bearer ${opts.token}` } : {}), "Content-Type": "application/json" },
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  return { status: res.status, data: await res.json() as any };
}
const signIn = async (code: string) => (await call("/api/auth/token", { body: { code, code_verifier: VERIFIER } })).data.token as string;
const hex = (n: number) => n.toString(16).padStart(2, "0").repeat(32);
const register = (token: string, device: string, env = "production") => call("/api/devices", { token, body: { token: device, env } });
const tokens = () => app.db.query("SELECT token, user_id, env FROM device_tokens ORDER BY token").all() as { token: string; user_id: string; env: string }[];
const settle = async () => { await app.idle(); };

let sam: string, alex: string, kim: string, gone: string;
const [SAM, ALEX, KIM, GONE, KIM_OLD] = [hex(1), hex(2), hex(3), hex(4), hex(5)];

beforeAll(async () => {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  publicKey = pair.publicKey;
  const der = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
  const keyFile = join(dataDir, "key.p8");
  writeFileSync(keyFile, `-----BEGIN PRIVATE KEY-----\n${der.match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----\n`);
  const [prod, sandbox] = await Promise.all([fakeApns("production"), fakeApns("sandbox")]);
  apnsServers = [prod.server, sandbox.server];
  const config = {
    ...configFromEnv({ APNS_TEAM_ID: "TEAM123456", APNS_TOPIC: "com.tpcomm.links", APNS_KEY_ID: "KEY1234567", APNS_KEY_FILE: keyFile,
                       APNS_HOST: prod.url, APNS_SANDBOX_HOST: sandbox.url }),
    port: 0, hostname: "127.0.0.1", dataDir, workosClientId: "client_TEST", workosApi: fakeWorkOS.url.origin,
    allowedEmails, allowPrivateNetwork: true, logRequests: false, previewBackfillMs: 0,
  };
  const started = startServer(config, { badgeDelayMs: 50, retryDelayMs: 10, previewWaitMs: 1000 });
  app = started.app;
  api = started.server.url.origin;
  stop = () => { app.push.close(); started.server.stop(true); };
  [sam, alex, kim, gone] = await Promise.all(["sam", "alex", "kim", "gone"].map(signIn)) as [string, string, string, string];
  const kimOld = await signIn("kim");
  for (const [t, d] of [[sam, SAM], [alex, ALEX], [kim, KIM], [gone, GONE], [kimOld, KIM_OLD]] as const) {
    expect((await register(t, d)).data).toEqual({ ok: true, push: true });
  }
  // Kim's older session hasn't been used for longer than SESSION_DAYS.
  app.db.run("UPDATE sessions SET last_used = 0 WHERE token_hash = ?", [app.accounts.sessionHash(kimOld)]);
  // Gone was taken off the guest list after signing in.
  allowedEmails.pop();
});

afterAll(() => {
  stop();
  for (const s of apnsServers) s.close();
  fakeWorkOS.stop(true);
  fakeOrigin.stop(true);
  rmSync(dataDir, { recursive: true, force: true });
});

beforeEach(async () => { await settle(); sent = []; replies.clear(); });

describe("device registration", () => {
  test("validates the token and environment", async () => {
    expect((await register(sam, "not hex")).status).toBe(400);
    expect((await register(sam, "abc")).status).toBe(400);
    expect((await register(sam, hex(9), "staging")).status).toBe(400);
    expect((await call("/api/devices", { body: { token: hex(9), env: "sandbox" } })).status).toBe(401);
    // Longer than 32 bytes is fine: Apple says not to assume a length.
    expect((await register(sam, hex(9) + "ab".repeat(40), "sandbox")).status).toBe(200);
    await call(`/api/devices/${hex(9)}${"ab".repeat(40)}`, { method: "DELETE", token: sam });
    expect(tokens().map((t) => t.token)).toEqual([SAM, ALEX, KIM, GONE, KIM_OLD]);
  });

  test("signing in as someone else on the same phone moves the token; DELETE only removes your own", async () => {
    const phone = hex(10);
    await register(sam, phone.toUpperCase());
    await register(alex, phone, "sandbox");
    expect(tokens().find((t) => t.token === phone)).toEqual({ token: phone, user_id: "user_01ALEX", env: "sandbox" });
    await call(`/api/devices/${phone}`, { method: "DELETE", token: sam });
    expect(tokens().some((t) => t.token === phone)).toBe(true);
    await call(`/api/devices/${phone}`, { method: "DELETE", token: alex });
    expect(tokens().some((t) => t.token === phone)).toBe(false);
  });
});

describe("pushes", () => {
  test("a new link alerts everyone else, with its title once the preview is in", async () => {
    const { data } = await call("/api/links", { token: sam, body: { url: `${fakeOrigin.url.origin}/video?n=1`, note: "look!" } });
    await settle();
    // Not Sam (the sender), not Kim's expired session, not Gone (off the guest list).
    expect(sent.map((s) => s.token).sort()).toEqual([ALEX, KIM]);
    for (const s of sent) {
      expect(s.headers["apns-push-type"]).toBe("alert");
      expect(s.headers["apns-priority"]).toBe("10");
      expect(s.headers["apns-topic"]).toBe("com.tpcomm.links");
      expect(s.headers["apns-expiration"]).toBeUndefined();
      expect(s.body).toEqual({
        aps: {
          alert: { title: "Sam", body: "sent a link: Cats & Dogs\nlook!" }, badge: 1, sound: "default",
          "thread-id": "links-inbox", category: "NEW_LINK", "mutable-content": 1,
        },
        link_id: data.link.id, sender_id: "user_01SAM",
      });
    }
    // A duplicate sends nothing.
    sent = [];
    await call("/api/links", { token: alex, body: { url: `${fakeOrigin.url.origin}/video?n=1` } });
    await settle();
    expect(sent).toEqual([]);
  });

  test("without a preview in time, the platform noun; nothing for a link deleted before it goes", async () => {
    await call("/api/links", { token: alex, body: { url: `${fakeOrigin.url.origin}/slow?n=1` } });
    await settle();
    expect(sent.map((s) => s.body.aps.alert.body)).toEqual(["sent a link", "sent a link"]);
    sent = [];
    const { data } = await call("/api/links", { token: alex, body: { url: `${fakeOrigin.url.origin}/slow?n=2` } });
    await call(`/api/links/${data.link.id}`, { method: "DELETE", token: alex });
    await settle();
    expect(sent.every((s) => !s.body.aps.alert)).toBe(true);
  }, 15_000);

  test("long titles and notes are clipped to fit in 4 KB", async () => {
    await call("/api/links", { token: sam, body: { url: `${fakeOrigin.url.origin}/long`, note: "📝".repeat(500) } });
    await settle();
    const { body } = sent[0]!;
    expect(Buffer.byteLength(JSON.stringify(body))).toBeLessThanOrEqual(4096);
    expect(body.aps.alert.body).toBe(`sent a link: ${"🐱".repeat(150)}\n${"📝".repeat(200)}`);
  });

  test("the provider token is ES256, signed by the key, and reused", async () => {
    await call("/api/links", { token: sam, body: { url: `${fakeOrigin.url.origin}/video?n=jwt` } });
    await settle();
    const jwts = new Set(sent.map((s) => s.jwt));
    expect(jwts.size).toBe(1);
    const [h, c, sig] = [...jwts][0]!.split(".");
    expect(JSON.parse(Buffer.from(h!, "base64url").toString())).toEqual({ alg: "ES256", kid: "KEY1234567" });
    const claims = JSON.parse(Buffer.from(c!, "base64url").toString());
    expect(claims.iss).toBe("TEAM123456");
    expect(Math.abs(claims.iat - Date.now() / 1000)).toBeLessThan(60 * 60);
    expect(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, Buffer.from(sig!, "base64url"),
      new TextEncoder().encode(`${h}.${c}`))).toBe(true);
  });

  test("a reaction is a passive alert for the sender; reacting to your own link sends nothing", async () => {
    const { data } = await call("/api/links", { token: sam, body: { url: `${fakeOrigin.url.origin}/video?n=react` } });
    await settle();
    sent = [];
    await call(`/api/links/${data.link.id}/react`, { token: alex, body: { emoji: "😂" } });
    await call(`/api/links/${data.link.id}/react`, { token: alex, body: { emoji: "😂" } }); // unchanged: no second push
    await call(`/api/links/${data.link.id}/react`, { token: sam, body: { emoji: "🔥" } });
    await settle();
    expect(sent.length).toBe(1);
    expect(sent[0]!.token).toBe(SAM);
    expect(sent[0]!.headers["apns-priority"]).toBe("10");
    expect(sent[0]!.body.aps).toMatchObject({ alert: { title: "Alex", body: "reacted 😂 to your link: Cats & Dogs" }, "interruption-level": "passive" });
    expect(sent[0]!.body.aps.sound).toBeUndefined();
  });

  test("watching and unwatching sends one coalesced badge-only push to your devices", async () => {
    const state = (await call("/api/state", { token: kim })).data;
    const unwatched = state.links.filter((l: any) => !l.seen["user_01KIM"] && l.added_by !== "user_01KIM");
    expect(unwatched.length).toBeGreaterThan(1);
    await call(`/api/links/${unwatched[0].id}/seen`, { token: kim, body: { seen: true } });
    await call(`/api/links/${unwatched[1].id}/seen`, { token: kim, body: { seen: true } });
    await settle();
    expect(sent.length).toBe(1);
    expect(sent[0]!.token).toBe(KIM);
    expect(sent[0]!.headers["apns-priority"]).toBe("5");
    expect(sent[0]!.headers["apns-expiration"]).toBe("0");
    expect(sent[0]!.headers["apns-push-type"]).toBe("alert");
    expect(sent[0]!.body).toEqual({ aps: { badge: unwatched.length - 2 } });
  });

  test("deleting a link updates the badges of people who hadn't watched it", async () => {
    const { data } = await call("/api/links", { token: sam, body: { url: `${fakeOrigin.url.origin}/video?n=del` } });
    await call(`/api/links/${data.link.id}/seen`, { token: kim, body: { seen: true } });
    await settle();
    sent = [];
    await call(`/api/links/${data.link.id}`, { method: "DELETE", token: sam });
    await settle();
    expect(sent.map((s) => [s.token, Object.keys(s.body.aps)])).toEqual([[ALEX, ["badge"]]]);
  });
});

describe("APNs answers", () => {
  const badge = async (person: string) => { app.push.badges([person]); await settle(); };

  test("410 deletes the token, unless it was registered again after APNs' timestamp", async () => {
    replies.set(ALEX, [{ status: 410, body: { reason: "Unregistered", timestamp: Date.now() - 60_000 } }]);
    await badge("user_01ALEX");
    expect(tokens().some((t) => t.token === ALEX)).toBe(true);
    replies.set(ALEX, [{ status: 410, body: { reason: "Unregistered", timestamp: Date.now() + 1000 } }]);
    await badge("user_01ALEX");
    expect(tokens().some((t) => t.token === ALEX)).toBe(false);
    await register(alex, ALEX);
  });

  test("BadDeviceToken tries the other environment once, and keeps the one that works", async () => {
    replies.set(`production:${ALEX}`, [{ status: 400, body: { reason: "BadDeviceToken" } }]);
    await badge("user_01ALEX");
    expect(sent.map((s) => s.env)).toEqual(["production", "sandbox"]);
    expect(tokens().find((t) => t.token === ALEX)!.env).toBe("sandbox");

    sent = [];
    replies.set(ALEX, [{ status: 400, body: { reason: "BadDeviceToken" } }, { status: 400, body: { reason: "BadDeviceToken" } }]);
    await badge("user_01ALEX");
    expect(sent.map((s) => s.env)).toEqual(["sandbox", "production"]);
    expect(tokens().some((t) => t.token === ALEX)).toBe(false);
    await register(alex, ALEX);
  });

  test("DeviceTokenNotForTopic deletes it", async () => {
    replies.set(ALEX, [{ status: 400, body: { reason: "DeviceTokenNotForTopic" } }]);
    await badge("user_01ALEX");
    expect(tokens().some((t) => t.token === ALEX)).toBe(false);
    await register(alex, ALEX);
  });

  test("ExpiredProviderToken re-signs and retries; 429 retries once; 5xx is dropped", async () => {
    replies.set(ALEX, [{ status: 403, body: { reason: "ExpiredProviderToken" } }]);
    await badge("user_01ALEX");
    expect(sent.length).toBe(2);
    expect(sent[0]!.jwt).not.toBe(sent[1]!.jwt);

    sent = [];
    replies.set(ALEX, [{ status: 429, body: { reason: "TooManyRequests" } }, { status: 429, body: { reason: "TooManyRequests" } }]);
    await badge("user_01ALEX");
    expect(sent.length).toBe(2);

    sent = [];
    replies.set(ALEX, [{ status: 503, body: { reason: "ServiceUnavailable" } }]);
    await badge("user_01ALEX");
    expect(sent.length).toBe(1);
    expect(tokens().some((t) => t.token === ALEX)).toBe(true);
  });

  test("signing out removes that session's tokens; deleting the account removes the rest", async () => {
    const otherPhone = await signIn("alex");
    await register(otherPhone, hex(11));
    await call("/api/auth/logout", { method: "POST", token: otherPhone });
    expect(tokens().some((t) => t.token === hex(11))).toBe(false);
    expect(tokens().some((t) => t.token === ALEX)).toBe(true);
    await call("/api/me", { method: "DELETE", token: alex });
    expect(tokens().some((t) => t.user_id === "user_01ALEX")).toBe(false);
  });
});
