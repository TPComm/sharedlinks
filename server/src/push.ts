/**
 * Push notifications through APNs: token-based (.p8) auth over one HTTP/2 connection per host.
 * https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns
 *
 * Sends never block an API response; each is handed to `track` so tests can await them.
 */
import type { Database } from "bun:sqlite";
import { readFileSync } from "node:fs";
import http2 from "node:http2";
import type { Accounts } from "./accounts.ts";
import type { ApnsEnv, Config } from "./config.ts";
import { now } from "./db.ts";
import { clip, clipText } from "./links.ts";

/** Same nouns as `Platform.noun` in ios/LinksKit/Sources/LinksKit/Models.swift, mid-sentence. */
const NOUNS: Record<string, string> = {
  tiktok: "TikTok", instagram: "Instagram post", youtube: "YouTube video", x: "post on X",
  reddit: "Reddit post", facebook: "Facebook post", web: "link",
};
const article = (noun: string) => (/^[aeiou]/i.test(noun) ? "an" : "a");
const nounOf = (platform: string) => NOUNS[platform] ?? NOUNS.web!;

/** `ShareSuggestions.conversationID`, so the app's notifications group with its share suggestions. */
const THREAD_ID = "links-inbox";
const MAX_PAYLOAD = 4096;
/** Provider tokens must be refreshed every 20–60 minutes. */
const JWT_TTL_S = 50 * 60;
const IDLE_PING_MS = 60 * 60 * 1000;
const REQUEST_TIMEOUT_MS = 15_000;

export type PushType = "alert" | "badge";

export interface Device { token: string; env: ApnsEnv; updated_at: number; user_id: string }

export interface PushOptions {
  /** How long badge updates for one person wait for more changes before one push goes out. */
  badgeDelayMs?: number;
  /** Wait before retrying a 429. */
  retryDelayMs?: number;
}

export const pushEnabled = (c: Config) => !!(c.apnsTeamId && c.apnsTopic && c.apnsKey);

const b64url = (data: string | ArrayBuffer) =>
  Buffer.from(typeof data === "string" ? Buffer.from(data) : new Uint8Array(data)).toString("base64url");

export function pemToDer(pem: string): Uint8Array<ArrayBuffer> {
  const der = Buffer.from(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, ""), "base64");
  return new Uint8Array(der).slice();
}

/** Measure as APNs does: UTF-8 bytes of the JSON body. */
const size = (payload: unknown) => Buffer.byteLength(JSON.stringify(payload));

export class Pusher {
  readonly enabled: boolean;
  private signingKey: Promise<CryptoKey> | null = null;
  private jwt: { jwt: string; iat: number } | null = null;
  private conns = new Map<string, { session: http2.ClientHttp2Session; lastUsed: number; timer: Timer }>();
  private badgeTimers = new Map<string, { timer: Timer; done: () => void }>();
  private badgeDelayMs: number;
  private retryDelayMs: number;

  constructor(
    private db: Database,
    private config: Config,
    private accounts: Accounts,
    private track: (task: Promise<void>) => void,
    opts: PushOptions = {},
  ) {
    this.enabled = pushEnabled(config);
    this.badgeDelayMs = opts.badgeDelayMs ?? 2000;
    this.retryDelayMs = opts.retryDelayMs ?? 1000;
  }

  // MARK: Events

  /** A new link: alert everyone who can see it except its sender. Skipped if it's gone by now. */
  async newLink(linkId: number) {
    const link = this.db.query(
      "SELECT l.title, l.note, l.platform, l.added_by, u.name FROM links l JOIN users u ON u.id = l.added_by WHERE l.id = ?",
    ).get(linkId) as { title: string | null; note: string; platform: string; added_by: string; name: string } | null;
    if (!link) return;
    const recipients = this.db.query(
      `SELECT DISTINCT d.user_id FROM device_tokens d WHERE d.user_id != ?1
         AND NOT EXISTS (SELECT 1 FROM blocks WHERE blocker = d.user_id AND blocked = ?1)
         AND NOT EXISTS (SELECT 1 FROM reports WHERE reporter = d.user_id AND link_id = ?2)`,
    ).all(link.added_by, linkId) as { user_id: string }[];
    const noun = nounOf(link.platform);
    const lead = `sent ${article(noun)} ${noun}`;
    await Promise.all(recipients.map(({ user_id }) => this.toPerson(user_id, "alert", (badge) => this.fit({
      aps: {
        alert: { title: link.name, body: [lead, link.title, link.note] as const },
        badge, sound: "default", "thread-id": THREAD_ID, category: "NEW_LINK", "mutable-content": 1,
      },
      link_id: linkId, sender_id: link.added_by,
    }))));
  }

  /** Someone reacted: a passive alert (no sound, screen stays off) for the link's sender. */
  async reaction(linkId: number, reactor: string, emoji: string) {
    const link = this.db.query("SELECT title, platform, added_by FROM links WHERE id = ?")
      .get(linkId) as { title: string | null; platform: string; added_by: string } | null;
    if (!link || link.added_by === reactor) return;
    if (this.db.query("SELECT 1 FROM blocks WHERE blocker = ? AND blocked = ?").get(link.added_by, reactor)) return;
    const name = (this.db.query("SELECT name FROM users WHERE id = ?").get(reactor) as { name: string } | null)?.name;
    if (!name) return;
    const noun = nounOf(link.platform);
    await this.toPerson(link.added_by, "alert", (badge) => this.fit({
      aps: {
        alert: { title: name, body: [`reacted ${emoji} to your ${noun}`, link.title, ""] as const },
        badge, "thread-id": THREAD_ID, "interruption-level": "passive",
      },
      link_id: linkId, sender_id: reactor,
    }));
  }

  /** People who'd have this link in To Watch: call before deleting it, then `badges()` them. */
  unwatchedBy(linkId: number): string[] {
    return (this.db.query(
      `SELECT u.id FROM users u JOIN links l ON l.id = ?1 WHERE u.id != l.added_by
         AND NOT EXISTS (SELECT 1 FROM seen WHERE link_id = l.id AND person = u.id)
         AND NOT EXISTS (SELECT 1 FROM reports WHERE reporter = u.id AND link_id = l.id)
         AND NOT EXISTS (SELECT 1 FROM blocks WHERE blocker = u.id AND blocked = l.added_by)`,
    ).all(linkId) as { id: string }[]).map((r) => r.id);
  }

  /** People with a link `sender` sent in their To Watch (deleting the account deletes its links). */
  unwatchedFrom(sender: string): string[] {
    return (this.db.query(
      `SELECT DISTINCT u.id FROM users u JOIN links l ON l.added_by = ?1 WHERE u.id != ?1
         AND NOT EXISTS (SELECT 1 FROM seen WHERE link_id = l.id AND person = u.id)
         AND NOT EXISTS (SELECT 1 FROM reports WHERE reporter = u.id AND link_id = l.id)
         AND NOT EXISTS (SELECT 1 FROM blocks WHERE blocker = u.id AND blocked = ?1)`,
    ).all(sender) as { id: string }[]).map((r) => r.id);
  }

  /**
   * Badge-only pushes, coalesced per person: changes within `badgeDelayMs` send one push with the
   * count at the end. Goes to all their devices, the one that made the change too.
   */
  badges(people: Iterable<string>) {
    if (!this.enabled) return;
    for (const person of people) {
      if (this.badgeTimers.has(person)) continue;
      let done!: () => void;
      const task = new Promise<void>((resolve) => { done = resolve; });
      const timer = setTimeout(() => {
        this.badgeTimers.delete(person);
        this.toPerson(person, "badge", (badge) => ({ aps: { badge } })).catch((e) => console.error(`push: ${e}`)).finally(done);
      }, this.badgeDelayMs);
      this.badgeTimers.set(person, { timer, done });
      this.track(task);
    }
  }

  /** Same as the app's To Watch: visible links from other people that they haven't watched. */
  toWatch(person: string): number {
    return (this.db.query(
      `SELECT COUNT(*) AS n FROM links WHERE added_by != ?1
         AND NOT EXISTS (SELECT 1 FROM seen WHERE link_id = links.id AND person = ?1)
         AND NOT EXISTS (SELECT 1 FROM reports WHERE reporter = ?1 AND link_id = links.id)
         AND NOT EXISTS (SELECT 1 FROM blocks WHERE blocker = ?1 AND blocked = links.added_by)`,
    ).get(person) as { n: number }).n;
  }

  /** Devices of live sessions (used within SESSION_DAYS) whose owner is still a member. */
  devices(person: string): Device[] {
    const rows = this.db.query(
      `SELECT d.token, d.env, d.updated_at, d.user_id, s.last_used FROM device_tokens d
         JOIN sessions s ON s.token_hash = d.session_hash JOIN users u ON u.id = d.user_id
         WHERE d.user_id = ? AND d.kind = 'app' AND u.member = 1`,
    ).all(person) as (Device & { last_used: number })[];
    return rows.filter((r) => this.accounts.isLive(r.last_used))
      .map(({ token, env, updated_at, user_id }) => ({ token, env, updated_at, user_id }));
  }

  private async toPerson(person: string, type: PushType, payload: (badge: number) => unknown) {
    if (!this.enabled) return;
    const devices = this.devices(person);
    if (!devices.length) return;
    const body = JSON.stringify(payload(this.toWatch(person)));
    await Promise.all(devices.map((d) => this.send(d, type, body).catch((e) => console.error(`push ${d.token.slice(0, 8)}…: ${e}`))));
  }

  /**
   * Fill in the alert body ("sent a TikTok: Title", then the note on its own line), clipping the
   * title to 150 characters and the note to 200, then further until the payload fits in 4 KB.
   */
  private fit(payload: { aps: { alert: { title: string; body: readonly [string, string | null, string] } } & Record<string, unknown> } & Record<string, unknown>) {
    const [lead, title, note] = payload.aps.alert.body;
    let titleMax = 150, noteMax = 200;
    for (;;) {
      const t = clip(title ?? "", titleMax), n = clipText(note, noteMax);
      const body = (t ? `${lead}: ${t}` : lead) + (n ? `\n${n}` : "");
      const out = { ...payload, aps: { ...payload.aps, alert: { title: clip(payload.aps.alert.title, 100), body } } };
      if (size(out) <= MAX_PAYLOAD || (!t && !n)) return out;
      if (noteMax > 0) noteMax = noteMax > 20 ? Math.floor(noteMax / 2) : 0;
      else titleMax = titleMax > 20 ? Math.floor(titleMax / 2) : 0;
    }
  }

  // MARK: Sending

  /** One notification to one device, handling APNs' answer. */
  async send(device: Device, type: PushType, body: string) {
    let env = device.env;
    let retried = { env: false, jwt: false, rate: false };
    for (let attempt = 0; ; attempt++) {
      if (attempt && !this.stillRegistered(device)) return;
      const res = await this.request(env, device.token, type, body);
      if (res.status === 200) {
        if (env !== device.env) {
          this.db.run("UPDATE device_tokens SET env = ? WHERE token = ? AND updated_at = ?", [env, device.token, device.updated_at]);
        }
        return;
      }
      const reason = res.reason;
      const short = `${device.token.slice(0, 8)}…`;
      if (res.status === 410 || reason === "ExpiredToken") {
        // Unless the app registered it again after APNs found it invalid.
        const at = (res.timestamp ?? Date.now()) / 1000;
        this.db.run("DELETE FROM device_tokens WHERE token = ? AND updated_at <= ?", [device.token, at]);
        return;
      }
      if (reason === "BadDeviceToken") {
        const other: ApnsEnv = env === "production" ? "sandbox" : "production";
        if (!retried.env) { retried.env = true; env = other; continue; }
        this.forget(device, `push ${short}: BadDeviceToken`);
        return;
      }
      if (reason === "DeviceTokenNotForTopic") { this.forget(device, `push ${short}: DeviceTokenNotForTopic (is APNS_TOPIC the app's bundle id?)`); return; }
      if (reason === "ExpiredProviderToken" && !retried.jwt) { retried.jwt = true; this.jwt = null; continue; }
      if (res.status === 429 && !retried.rate) { retried.rate = true; await Bun.sleep(this.retryDelayMs); continue; }
      console.error(`push ${short}: APNs ${env} said ${res.status} ${reason ?? ""}`.trim());
      return;
    }
  }

  /** Not signed out, taken over by another account or registered again since this send began. */
  private stillRegistered(device: Device) {
    return !!this.db.query("SELECT 1 FROM device_tokens WHERE token = ? AND user_id = ? AND updated_at = ?")
      .get(device.token, device.user_id, device.updated_at);
  }

  private forget(device: Device, message: string) {
    console.warn(`${message}; forgetting the token`);
    this.db.run("DELETE FROM device_tokens WHERE token = ? AND updated_at = ?", [device.token, device.updated_at]);
  }

  private async request(env: ApnsEnv, token: string, type: PushType, body: string) {
    const jwt = await this.providerToken();
    const session = this.connection(this.config.apnsHosts[env]);
    const headers: http2.OutgoingHttpHeaders = {
      ":method": "POST",
      ":path": `/3/device/${token}`,
      authorization: `bearer ${jwt}`,
      "apns-topic": this.config.apnsTopic,
      "apns-push-type": "alert",
      "apns-priority": type === "badge" ? "5" : "10",
      ...(type === "badge" ? { "apns-expiration": "0" } : {}),
      // Apple asks for these as never-indexed HPACK literals.
      [http2.sensitiveHeaders]: [":path", "authorization"],
    };
    return await new Promise<{ status: number; reason?: string; timestamp?: number }>((resolve, reject) => {
      const req = session.request(headers);
      let status = 0, data = "";
      req.setEncoding("utf8");
      const timer = setTimeout(() => { req.close(http2.constants.NGHTTP2_CANCEL); reject(new Error("APNs timed out")); }, REQUEST_TIMEOUT_MS);
      req.on("close", () => clearTimeout(timer));
      req.on("response", (h) => { status = Number(h[":status"]); });
      req.on("data", (chunk) => { data += chunk; });
      req.on("end", () => {
        let parsed: { reason?: string; timestamp?: number } = {};
        try { if (data) parsed = JSON.parse(data); } catch {}
        resolve({ status, reason: parsed.reason, timestamp: parsed.timestamp });
      });
      req.on("error", reject);
      req.end(body);
    });
  }

  /** One HTTP/2 connection per APNs host, reopened after an error or GOAWAY, pinged when idle. */
  private connection(host: string): http2.ClientHttp2Session {
    const existing = this.conns.get(host);
    if (existing && !existing.session.closed && !existing.session.destroyed) {
      existing.lastUsed = Date.now();
      return existing.session;
    }
    const session = http2.connect(host);
    const retire = () => {
      const c = this.conns.get(host);
      if (c?.session !== session) return;
      clearInterval(c.timer);
      this.conns.delete(host);
    };
    const drop = () => {
      retire();
      if (!session.destroyed) session.destroy();
    };
    session.on("error", (e) => { console.error(`push: ${host}: ${e}`); drop(); });
    // New sends open another connection; pushes already accepted on this one still finish.
    session.on("goaway", () => {
      retire();
      if (!session.closed) session.close();
    });
    session.on("close", drop);
    const timer = setInterval(() => {
      const c = this.conns.get(host);
      if (c && Date.now() - c.lastUsed >= IDLE_PING_MS) session.ping((err) => { if (err) drop(); });
    }, IDLE_PING_MS);
    timer.unref();
    session.unref();
    this.conns.set(host, { session, lastUsed: Date.now(), timer });
    return session;
  }

  /** The ES256 provider token, re-signed every 50 minutes. The same key and token work for both hosts. */
  async providerToken(): Promise<string> {
    const t = Math.floor(now());
    if (this.jwt && t - this.jwt.iat < JWT_TTL_S) return this.jwt.jwt;
    const key = this.config.apnsKey;
    if (!key) throw new Error("no APNs key");
    if (!this.signingKey) {
      const signingKey = crypto.subtle.importKey("pkcs8", pemToDer(readFileSync(key.keyFile, "utf8")),
        { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
      signingKey.catch(() => { if (this.signingKey === signingKey) this.signingKey = null; });
      this.signingKey = signingKey;
    }
    const input = `${b64url(JSON.stringify({ alg: "ES256", kid: key.keyId }))}.${b64url(JSON.stringify({ iss: this.config.apnsTeamId, iat: t }))}`;
    // WebCrypto's ECDSA signature is already the raw r||s that JWS wants.
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, await this.signingKey, new TextEncoder().encode(input));
    const jwt = `${input}.${b64url(sig)}`;
    this.jwt = { jwt, iat: t };
    return jwt;
  }

  close() {
    for (const { timer, done } of this.badgeTimers.values()) { clearTimeout(timer); done(); }
    this.badgeTimers.clear();
    for (const { session, timer } of this.conns.values()) { clearInterval(timer); session.close(); }
    this.conns.clear();
  }
}
