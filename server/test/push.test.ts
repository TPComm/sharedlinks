import { afterAll, beforeAll, beforeEach, describe, expect, spyOn, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import http2 from "node:http2";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../src/app.ts";
import { configFromEnv } from "../src/config.ts";
import { Pusher } from "../src/push.ts";
import { seedEveryoneMember } from "./unit/helpers.ts";

const VERIFIER = "v".repeat(43);
const dataDir = mkdtempSync(join(tmpdir(), "links-push-"));
const LONG_TITLE = "🐱".repeat(300);

const users: Record<string, object> = {
  sam: { id: "user_01SAM", email: "sam@team.test", email_verified: true, first_name: "Sam", profile_picture_url: "https://photos.test/sam.png" },
  alex: { id: "user_01ALEX", email: "alex@team.test", email_verified: true, first_name: "Alex" },
  kim: { id: "user_01KIM", email: "kim@team.test", email_verified: true, first_name: "Kim" },
  carol: { id: "user_01CAROL", email: "carol@team.test", email_verified: true, first_name: "Carol" },
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
// A 1×1 PNG.
const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64");
const fakeOrigin = Bun.serve({
  port: 0,
  routes: {
    "/pic": new Response(`<html><head><meta property="og:title" content="Pic"><meta property="og:image" content="/thumb.png"></head></html>`, { headers: { "Content-Type": "text/html" } }),
    "/thumb.png": new Response(PNG, { headers: { "Content-Type": "image/png" } }),
    "/video": new Response(`<html><head><meta property="og:title" content="Cats &amp; Dogs"></head></html>`, { headers: { "Content-Type": "text/html" } }),
    "/long": new Response(`<html><head><title>${LONG_TITLE}</title></head></html>`, { headers: { "Content-Type": "text/html" } }),
    "/slow": async () => { await Bun.sleep(1500); return new Response("<title>Too late</title>", { headers: { "Content-Type": "text/html" } }); },
  },
});

interface Sent { env: string; token: string; headers: http2.IncomingHttpHeaders; body: any; jwt: string }
/** Answers per token, in order, then 200. */
const replies = new Map<string, { status: number; body?: object; before?: () => void; goaway?: boolean }[]>();
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
      reply.before?.();
      if (reply.goaway) stream.session?.goaway(0, stream.id);
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
    allowPrivateNetwork: true, logRequests: false, previewBackfillMs: 0,
  };
  const started = startServer(config, { badgeDelayMs: 50, activityDelayMs: 300, retryDelayMs: 10, previewWaitMs: 1000 });
  app = started.app;
  api = started.server.url.origin;
  stop = () => { app.push.close(); started.server.stop(true); };
  for (const u of Object.values(users) as { email: string }[]) app.accounts.createInvite(null, u.email);
  [sam, alex, kim, gone] = await Promise.all(["sam", "alex", "kim", "gone"].map(signIn)) as [string, string, string, string];
  for (const id of ["user_01SAM", "user_01ALEX", "user_01KIM", "user_01GONE"]) seedEveryoneMember(app.db, id);
  const kimOld = await signIn("kim");
  for (const [t, d] of [[sam, SAM], [alex, ALEX], [kim, KIM], [gone, GONE], [kimOld, KIM_OLD]] as const) {
    expect((await register(t, d)).data).toEqual({ ok: true, push: true });
  }
  // Kim's older session hasn't been used for longer than SESSION_DAYS.
  app.db.run("UPDATE sessions SET last_used = 0 WHERE token_hash = ?", [app.accounts.sessionHash(kimOld)]);
  // Gone was let out after signing in.
  app.db.run("UPDATE users SET member = 0 WHERE id = 'user_01GONE'");
});

afterAll(() => {
  stop();
  for (const s of apnsServers) s.close();
  fakeWorkOS.stop(true);
  fakeOrigin.stop(true);
  rmSync(dataDir, { recursive: true, force: true });
});

beforeEach(async () => { await settle(); sent = []; replies.clear(); });

describe("provider tokens", () => {
  const pusher = () => new Pusher(app.db, configFromEnv({
    APNS_TEAM_ID: "TEAM123456", APNS_TOPIC: "com.tpcomm.links", APNS_KEY_ID: "KEY1234567",
    APNS_KEY_FILE: join(dataDir, "key.p8"),
  }), app.accounts, () => {});

  test("concurrent callers share one mint until the cached token expires", async () => {
    const push = pusher();
    const sign = spyOn(crypto.subtle, "sign");
    const clock = spyOn(Date, "now").mockReturnValue(Date.now());
    try {
      const mint = () => Promise.all(Array.from({ length: 10 }, () => push.providerToken()));
      const first = await mint();
      expect(new Set(first).size).toBe(1);
      expect(sign).toHaveBeenCalledTimes(1);
      expect(await push.providerToken()).toBe(first[0]!);
      expect(sign).toHaveBeenCalledTimes(1);
      clock.mockReturnValue(Date.now() + 51 * 60 * 1000);
      const refreshed = await mint();
      expect(new Set(refreshed).size).toBe(1);
      expect(refreshed[0]).not.toBe(first[0]);
      expect(sign).toHaveBeenCalledTimes(2);
    } finally {
      clock.mockRestore();
      sign.mockRestore();
      push.close();
    }
  });

  test("a failed mint rejects its callers and lets the next call retry", async () => {
    const push = pusher();
    const failure = new Error("sign failed");
    const sign = spyOn(crypto.subtle, "sign").mockRejectedValueOnce(failure);
    try {
      const results = await Promise.allSettled(Array.from({ length: 10 }, () => push.providerToken()));
      expect(results).toEqual(Array.from({ length: 10 }, () => ({ status: "rejected", reason: failure })));
      expect(sign).toHaveBeenCalledTimes(1);
      const jwt = await push.providerToken();
      expect(jwt.split(".")).toHaveLength(3);
      expect(await push.providerToken()).toBe(jwt);
      expect(sign).toHaveBeenCalledTimes(2);
    } finally {
      sign.mockRestore();
      push.close();
    }
  });
});

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
    // Not Sam (the sender), not Kim's expired session, not Gone (no longer a member).
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
        group_id: 1, link_id: data.link.id, sender_id: "user_01SAM",
        sender_name: "Sam", sender_avatar: "https://photos.test/sam.png",
      });
    }
    // A duplicate sends nothing.
    sent = [];
    await call("/api/links", { token: alex, body: { url: `${fakeOrigin.url.origin}/video?n=1` } });
    await settle();
    expect(sent).toEqual([]);
  });

  test("a new link's push carries its thumbnail path for the app to fetch with its own session", async () => {
    const { data } = await call("/api/links", { token: alex, body: { url: `${fakeOrigin.url.origin}/pic` } });
    await settle();
    expect(data.link.thumb).toBeNull(); // the preview lands after the response
    const link = (await call("/api/state", { token: sam })).data.links.find((l: any) => l.id === data.link.id);
    expect(link.thumb).toMatch(/^\/thumbs\/\d+/);
    expect(sent.map((s) => s.token).sort()).toEqual([SAM, KIM]);
    for (const s of sent) {
      expect(s.body).toMatchObject({ link_id: data.link.id, sender_name: "Alex", thumb: link.thumb });
      // Alex has no photo, and the default chat has no name to show.
      expect(s.body.sender_avatar).toBeUndefined();
      expect(s.body.chat).toBeUndefined();
    }
    const thumb = await fetch(api + link.thumb, { headers: { Authorization: `Bearer ${sam}` } });
    expect(thumb.status).toBe(200);
    expect(Buffer.from(await thumb.arrayBuffer())).toEqual(PNG);
  });

  test("a sender photo URL too long for the 4 KB push is left out rather than losing the alert", async () => {
    app.db.run("UPDATE users SET avatar = ? WHERE id = 'user_01SAM'", [`https://photos.test/${"x".repeat(4000)}.png`]);
    try {
      await call("/api/links", { token: sam, body: { url: `${fakeOrigin.url.origin}/plain?n=longphoto` } });
      await settle();
      expect(sent.length).toBeGreaterThan(0);
      for (const s of sent) {
        expect(s.body.sender_name).toBe("Sam");
        expect(s.body.sender_avatar).toBeUndefined();
      }
    } finally {
      app.db.run("UPDATE users SET avatar = ? WHERE id = 'user_01SAM'", ["https://photos.test/sam.png"]);
    }
  });

  test("a new link's push shows the photo the sender uploaded, or none once they removed it", async () => {
    try {
      app.db.run("UPDATE users SET photo = 'tok123' WHERE id = 'user_01SAM'");
      await call("/api/links", { token: sam, body: { url: `${fakeOrigin.url.origin}/plain?n=uploaded` } });
      await settle();
      expect(sent.length).toBeGreaterThan(0);
      for (const s of sent) expect(s.body.sender_avatar).toBe("http://localhost:8000/photos/tok123");
      sent = [];
      app.db.run("UPDATE users SET photo = '' WHERE id = 'user_01SAM'");
      await call("/api/links", { token: sam, body: { url: `${fakeOrigin.url.origin}/plain?n=removed` } });
      await settle();
      expect(sent.length).toBeGreaterThan(0);
      for (const s of sent) expect(s.body.sender_avatar).toBeUndefined();
    } finally {
      app.db.run("UPDATE users SET photo = NULL WHERE id = 'user_01SAM'");
    }
  });

  test("a link in a chat alerts only its members, threaded by chat and titled with its name", async () => {
    const alexId = (await call("/api/state", { token: alex })).data.me;
    const chat = (await call("/api/groups", { token: sam, body: { name: "Movie night", members: [alexId] } })).data.group;
    await call("/api/links", { token: sam, body: { url: `${fakeOrigin.url.origin}/plain?n=chat`, group_id: chat.id } });
    await settle();
    expect(sent.map((s) => s.token)).toEqual([ALEX]);
    expect(sent[0]!.body).toMatchObject({
      aps: { alert: { title: "Sam in Movie night" }, "thread-id": `links-group-${chat.id}` }, group_id: chat.id,
      sender_name: "Sam", chat: "Movie night",
    });
    // Kim isn't in it, so Kim's badge doesn't count it; Alex's does.
    const db = app.db;
    const unseen = (id: string) => (db.query("SELECT COUNT(*) AS n FROM links WHERE added_by != ?1 AND NOT EXISTS (SELECT 1 FROM seen WHERE link_id = links.id AND person = ?1) AND group_id != ?2").get(id, chat.id) as { n: number }).n;
    expect(app.push.toWatch("user_01KIM")).toBe(unseen("user_01KIM"));
    expect(app.push.toWatch(alexId)).toBe(unseen(alexId) + 1);
    sent = [];
    await call(`/api/groups/${chat.id}`, { method: "DELETE", token: alex });
    await call(`/api/groups/${chat.id}`, { method: "DELETE", token: sam });
    await settle();
  });

  test("muted chat members get badges, not alerts; expired mutes resume alerts", async () => {
    const chat = (await call("/api/groups", { token: sam, body: { members: ["user_01ALEX", "user_01KIM"] } })).data.group;
    await call(`/api/groups/${chat.id}`, { method: "PATCH", token: alex, body: { muted: true } });
    const before = app.push.toWatch("user_01ALEX");
    await call("/api/links", { token: sam, body: { url: `${fakeOrigin.url.origin}/video?n=muted`, group_id: chat.id } });
    await settle();
    expect(sent.filter((s) => s.token === ALEX).map((s) => s.body)).toEqual([{ aps: { badge: before + 1 } }]);
    expect(sent.filter((s) => s.token === KIM).every((s) => !!s.body.aps.alert)).toBe(true);
    expect(sent.filter((s) => s.token === KIM)).toHaveLength(1);
    app.db.run("UPDATE group_members SET muted_until = 1 WHERE group_id = ? AND user_id = ?", [chat.id, "user_01ALEX"]);
    sent = [];
    await call("/api/links", { token: sam, body: { url: `${fakeOrigin.url.origin}/video?n=expired-mute`, group_id: chat.id } });
    await settle();
    expect(sent.filter((s) => s.token === ALEX)).toHaveLength(1);
    expect(sent.find((s) => s.token === ALEX)!.body.aps.alert).toBeDefined();
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

  const toSam = () => sent.filter((s) => s.token === SAM && s.body.aps.alert); // not Sam's own badge updates
  const samsLink = async (n: string) => {
    const { data } = await call("/api/links", { token: sam, body: { url: `${fakeOrigin.url.origin}/video?n=${n}` } });
    await settle();
    sent = [];
    return data.link.id as number;
  };
  const watch = (id: number, token: string, seen = true) => call(`/api/links/${id}/seen`, { token, body: { seen } });
  const react = (id: number, token: string, emoji: string | null) => call(`/api/links/${id}/react`, { token, body: { emoji } });
  const setNotifications = (token: string, notifications: object) => call("/api/me", { method: "PATCH", token, body: { notifications } });

  test("watching a link is a passive alert for its sender, once; watching your own sends nothing", async () => {
    const id = await samsLink("watch");
    await watch(id, alex);
    await watch(id, alex); // already watched: no second push
    await watch(id, sam);
    await settle();
    expect(toSam().length).toBe(1);
    expect(toSam()[0]!.body.aps).toMatchObject({ alert: { title: "Alex", body: "saw your link: Cats & Dogs" }, "interruption-level": "passive" });
    expect(toSam()[0]!.body.aps.sound).toBeUndefined();
  });

  test("watching and reacting in quick succession, in either order, is one push saying both", async () => {
    for (const [first, second] of [[watch, react], [react, watch]] as const) {
      const id = await samsLink(`both-${first === watch ? "w" : "r"}`);
      await (first === watch ? watch(id, alex) : react(id, alex, "🔥"));
      await (second === watch ? watch(id, alex) : react(id, alex, "🔥"));
      await settle();
      expect(toSam().map((s) => s.body.aps.alert.body)).toEqual(["saw and reacted 🔥 to your link: Cats & Dogs"]);
    }
  });

  test("a reaction to a link they'd watched before goes out at once", async () => {
    const id = await samsLink("rewatch");
    await watch(id, alex);
    await settle();
    sent = [];
    await react(id, alex, "😂");
    await settle();
    expect(toSam().map((s) => s.body.aps.alert.body)).toEqual(["reacted 😂 to your link: Cats & Dogs"]);
  });

  test("unwatching or taking the reaction back before it goes out drops that part", async () => {
    const id = await samsLink("undo");
    await watch(id, alex);
    await watch(id, alex, false);
    await settle();
    expect(toSam()).toEqual([]);
    await react(id, alex, "😂");
    await react(id, alex, null);
    await settle();
    expect(toSam()).toEqual([]);
  });

  test("each kind can be turned off, and the other then goes out without waiting", async () => {
    expect((await setNotifications(sam, { watched: false })).data.notifications).toEqual({ watched: false, reactions: true });
    let id = await samsLink("no-watched");
    await watch(id, alex);
    await settle();
    expect(toSam()).toEqual([]);
    await react(id, alex, "🔥");
    await settle();
    expect(toSam().map((s) => s.body.aps.alert.body)).toEqual(["reacted 🔥 to your link: Cats & Dogs"]);

    expect((await setNotifications(sam, { watched: true, reactions: false })).data.notifications).toEqual({ watched: true, reactions: false });
    id = await samsLink("no-reactions");
    await react(id, alex, "🔥");
    await watch(id, alex);
    await settle();
    expect(toSam().map((s) => s.body.aps.alert.body)).toEqual(["saw your link: Cats & Dogs"]);

    // Turned off while one waits: it doesn't go out.
    await setNotifications(sam, { reactions: true });
    id = await samsLink("off-while-waiting");
    await watch(id, alex);
    await setNotifications(sam, { watched: false });
    await settle();
    expect(toSam()).toEqual([]);
    await setNotifications(sam, { watched: true });
  });

  test("muting suppresses watched and reacted alerts, including activity already waiting", async () => {
    const id = await samsLink("muted-activity");
    const groupId = (app.db.query("SELECT group_id FROM links WHERE id = ?").get(id) as { group_id: number }).group_id;
    const mute = (muted: boolean) => call(`/api/groups/${groupId}`, { method: "PATCH", token: sam, body: { muted } });
    await watch(id, alex);
    await mute(true);
    await settle();
    expect(toSam()).toEqual([]);
    await react(id, alex, "🔥");
    await watch(id, kim);
    await settle();
    expect(toSam()).toEqual([]);
    app.db.run("UPDATE group_members SET muted_until = 1 WHERE group_id = ? AND user_id = ?", [groupId, "user_01SAM"]);
    await react(id, kim, "🔥");
    await settle();
    expect(toSam().map((s) => s.body.aps.alert.body)).toEqual(["reacted 🔥 to your link: Cats & Dogs"]);
    await mute(false);
  });

  test("shutting down sends the pushes still waiting instead of dropping them", async () => {
    const id = await samsLink("shutdown");
    await watch(id, alex);
    expect(toSam()).toEqual([]);
    await app.drain(200); // less than activityDelayMs: only sending it now gets it out in time
    expect(toSam().map((s) => s.body.aps.alert.body)).toEqual(["saw your link: Cats & Dogs"]);
  });

  test("watching and unwatching sends one coalesced badge-only push to your devices", async () => {
    const state = (await call("/api/state", { token: kim })).data;
    const unwatched = state.links.filter((l: any) => !l.seen["user_01KIM"] && l.added_by !== "user_01KIM");
    expect(unwatched.length).toBeGreaterThan(1);
    await call(`/api/links/${unwatched[0].id}/seen`, { token: kim, body: { seen: true } });
    await call(`/api/links/${unwatched[1].id}/seen`, { token: kim, body: { seen: true } });
    await settle();
    sent = sent.filter((s) => s.token === KIM); // their senders hear Kim watched them
    expect(sent.length).toBe(1);
    expect(sent[0]!.token).toBe(KIM);
    expect(sent[0]!.headers["apns-priority"]).toBe("5");
    expect(sent[0]!.headers["apns-expiration"]).toBe("0");
    expect(sent[0]!.headers["apns-push-type"]).toBe("alert");
    expect(sent[0]!.body).toEqual({ aps: { badge: unwatched.length - 2 } });
  });

  test("new comments alert other members; edits, deletes and reports stay silent", async () => {
    const { data } = await call("/api/links", { token: sam, body: { url: `${fakeOrigin.url.origin}/video?n=comments` } });
    const id = data.link.id;
    await settle();
    sent = [];
    const before = app.push.toWatch("user_01ALEX");
    const quiet = async () => {
      await settle();
      expect(sent).toEqual([]);
      expect(app.push.toWatch("user_01ALEX")).toBe(before);
    };
    const made = await call(`/api/links/${id}/comments`, { token: sam, body: { body: "A reply" } });
    expect(made.status).toBe(201);
    const comment = made.data.comment.id;
    await settle();
    expect(sent.map((s) => s.token).sort()).toEqual([ALEX, KIM].sort());
    expect(sent[0]!.body).toMatchObject({
      aps: { alert: { title: "Sam", body: "commented\nA reply" }, "thread-id": "links-inbox", sound: "default" },
      link_id: id, group_id: data.link.group_id, comment_id: comment,
    });
    expect(sent.find((s) => s.token === ALEX)!.body.aps.badge).toBe(before);
    sent = [];
    await quiet();
    expect((await call(`/api/comments/${comment}`, { method: "PATCH", token: sam, body: { body: "Edited reply" } })).status).toBe(200);
    await quiet();
    for (let i = 0; i < 2; i++) {
      expect((await call("/api/reports", { token: alex, body: { comment_id: comment, reason: "spam" } })).status).toBe(201);
      await quiet();
    }
    expect((await call(`/api/links/${id}/comments`, { token: alex })).data.comments).toEqual([]);
    expect((await call(`/api/comments/${comment}`, { method: "DELETE", token: sam })).status).toBe(200);
    await quiet();
    expect((await call("/api/reports", { token: alex, body: { user_id: "user_01SAM", reason: "spam" } })).status).toBe(201);
    await quiet();
  });

  test("comment recipients respect chat membership, blocks, reports and mute", async () => {
    const chat = (await call("/api/groups", { token: sam, body: { name: "Replies", members: ["user_01ALEX", "user_01KIM"] } })).data.group;
    const link = (await call("/api/links", { token: sam, body: { url: `${fakeOrigin.url.origin}/video?n=comment-filters`, group_id: chat.id } })).data.link;
    await settle();
    const reply = async () => {
      sent = [];
      expect((await call(`/api/links/${link.id}/comments`, { token: alex, body: { body: "Hello" } })).status).toBe(201);
      await settle();
      return sent.filter((s) => s.body.aps.alert).map((s) => s.token).sort();
    };
    const before = app.push.toWatch("user_01ALEX");
    expect(await reply()).toEqual([SAM, KIM].sort());
    // Commenting took it out of Alex's To Watch, so Alex's badge drops; later replies leave it.
    expect(sent.filter((s) => s.token === ALEX).map((s) => s.body)).toEqual([{ aps: { badge: before - 1 } }]);
    sent = sent.filter((s) => s.token !== ALEX);
    expect(sent[0]!.body.aps["thread-id"]).toBe(`links-group-${chat.id}`);
    expect(sent[0]!.body.aps.alert.title).toBe("Alex in Replies");
    await call(`/api/groups/${chat.id}`, { token: kim, method: "PATCH", body: { muted: true } });
    expect(await reply()).toEqual([SAM]);
    await call(`/api/groups/${chat.id}`, { token: kim, method: "PATCH", body: { muted: false } });
    for (const blocked of ["user_01SAM", "user_01ALEX"]) {
      await call("/api/blocks", { token: kim, body: { user_id: blocked } });
      await settle();
      expect(await reply()).toEqual([SAM]);
      await call(`/api/blocks/${blocked}`, { token: kim, method: "DELETE" });
      await settle();
    }
    await call("/api/reports", { token: kim, body: { link_id: link.id, reason: "spam" } });
    await settle();
    expect(await reply()).toEqual([SAM]);
    await call(`/api/groups/${chat.id}`, { token: sam, method: "DELETE" });
    await settle();
    expect(await reply()).toEqual([]);
    await app.push.newComment(Number.MAX_SAFE_INTEGER);
    expect(sent).toEqual([]);
  });

  test("comment previews clip Unicode and rejected comments send nothing", async () => {
    const link = (await call("/api/links", { token: sam, body: { url: `${fakeOrigin.url.origin}/video?n=unicode-comments` } })).data.link;
    await settle();
    sent = [];
    for (const body of ["", 123, null]) {
      expect((await call(`/api/links/${link.id}/comments`, { token: alex, body: { body } })).status).toBe(400);
    }
    await settle();
    expect(sent).toEqual([]);
    const made = await call(`/api/links/${link.id}/comments`, { token: alex, body: { body: "😀".repeat(1000) } });
    expect(made.status).toBe(201);
    await settle();
    sent = sent.filter((s) => s.body.aps.alert);
    expect(sent.map((s) => s.token).sort()).toEqual([SAM, KIM].sort());
    for (const s of sent) {
      expect(Buffer.byteLength(JSON.stringify(s.body))).toBeLessThanOrEqual(4096);
      expect(s.body.aps.alert.body).toBe(`commented\n${"😀".repeat(200)}`);
      expect(s.body.comment_id).toBe(made.data.comment.id);
    }
  });

  test("reporting a link still updates only the reporter's badge, once", async () => {
    const { data } = await call("/api/links", { token: sam, body: { url: `${fakeOrigin.url.origin}/video?n=report-badge` } });
    await settle();
    sent = [];
    const before = app.push.toWatch("user_01ALEX");
    const report = () => call("/api/reports", { token: alex, body: { link_id: data.link.id, reason: "spam" } });
    expect((await report()).status).toBe(201);
    await settle();
    expect(app.push.toWatch("user_01ALEX")).toBe(before - 1);
    expect(sent.map((s) => [s.token, s.body])).toEqual([[ALEX, { aps: { badge: before - 1 } }]]);
    sent = [];
    expect((await report()).status).toBe(201);
    await settle();
    expect(sent).toEqual([]);
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

  test("deleting an account updates the badges of people who hadn't watched its links", async () => {
    const carol = await signIn("carol");
    seedEveryoneMember(app.db, "user_01CAROL");
    const { data } = await call("/api/links", { token: carol, body: { url: `${fakeOrigin.url.origin}/video?n=acct` } });
    await call(`/api/links/${data.link.id}/seen`, { token: kim, body: { seen: true } });
    await settle();
    sent = [];
    expect((await call("/api/me", { method: "DELETE", token: carol })).status).toBe(200);
    await settle();
    expect(sent.map((s) => [s.token, Object.keys(s.body.aps)]).sort()).toEqual([[ALEX, ["badge"]], [SAM, ["badge"]]].sort());
  });

  test("claiming a pre-sign-in person updates your badge", async () => {
    app.db.run("INSERT INTO users (id, name, created_at) VALUES ('legacy:Kim', 'Kim', 1)");
    app.accounts.approveClaim("kim@team.test", "Kim");
    app.db.run("INSERT INTO links (group_id, url, platform, added_by, added_at) VALUES (1, 'https://a.test/kim', 'web', 'legacy:Kim', 1)");
    expect((await call("/api/me/claim", { token: kim, body: { id: "legacy:Kim" } })).status).toBe(200);
    await settle();
    expect(sent.find((s) => s.token === KIM)?.body).toEqual({ aps: { badge: expect.any(Number) } });
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

  test("a GOAWAY lets the push in flight finish, and the next one opens a new connection", async () => {
    replies.set(ALEX, [{ status: 410, body: { reason: "Unregistered", timestamp: Date.now() + 1000 }, goaway: true }]);
    await badge("user_01ALEX");
    expect(tokens().some((t) => t.token === ALEX)).toBe(false);
    await register(alex, ALEX);
    await badge("user_01ALEX");
    expect(sent.length).toBe(2);
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

  test("a retry stops once the token was signed out or taken over", async () => {
    replies.set(ALEX, [{ status: 429, body: { reason: "TooManyRequests" },
                         before: () => app.db.run("DELETE FROM device_tokens WHERE token = ?", [ALEX]) }]);
    await badge("user_01ALEX");
    expect(sent.length).toBe(1);
    await register(alex, ALEX);

    sent = [];
    replies.set(ALEX, [{ status: 403, body: { reason: "ExpiredProviderToken" },
                         before: () => app.db.run("UPDATE device_tokens SET user_id = 'user_01SAM', updated_at = updated_at + 1 WHERE token = ?", [ALEX]) }]);
    await badge("user_01ALEX");
    expect(sent.length).toBe(1);
    await register(alex, ALEX);
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
