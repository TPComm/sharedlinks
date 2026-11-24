import type { Database } from "bun:sqlite";
import { randomBytes } from "node:crypto";
import { copyFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Config } from "./config.ts";
import { defaultGroup, deleteEmptyGroups, directChat, ensureDirectChat, ensureDirectChatsFor, LEGACY, now, type InviteRow, type UserRow } from "./db.ts";
import { BadRequest, clip } from "./links.ts";
import { screener } from "./moderation.ts";
import { imageSize } from "./previews.ts";

export class AuthError extends Error {
  constructor(message: string, readonly status = 401) {
    super(message);
  }
}

/** `publicUrl` makes an uploaded photo's address; without one, only WorkOS pictures show. */
/** A report's own copy of a person's photo (its snapshot's `photo_copy`), relative to DATA_DIR. */
export const reportPhoto = (token: string) => join("report-photos", token);

export const publicUser = (u: UserRow, publicUrl = "") => ({ id: u.id, name: u.name, avatar: avatarOf(u, publicUrl) });

function avatarOf(u: UserRow, publicUrl: string): string | null {
  if (u.photo === null || u.photo === undefined) return u.avatar;
  return u.photo && publicUrl ? `${publicUrl}/photos/${u.photo}` : null;
}

/** The app sends a 512px JPEG; this leaves room for other clients without storing camera originals. */
export const MAX_PHOTO_BYTES = 2_000_000;
const MAX_PHOTO_SIDE = 4096;

/** Ends with JPEG's end-of-image marker or PNG's IEND chunk, so a cut-off upload isn't kept. */
function isComplete(b: Uint8Array): boolean {
  const end = (tail: number[]) => b.length > tail.length && tail.every((x, i) => b[b.length - tail.length + i] === x);
  return end([0xff, 0xd9]) || end([0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82]);
}

/** "image/jpeg" or "image/png" for a profile photo's bytes, else null. */
export function photoType(b: Uint8Array): string | null {
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "image/jpeg";
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return "image/png";
  return null;
}

export function cleanName(name: unknown): string {
  const cleaned = clip(name, 30);
  if (!cleaned) throw new BadRequest("Missing name.");
  return cleaned;
}

const sha256 = (s: string) => new Bun.CryptoHasher("sha256").update(s).digest("hex");

function randomToken(): string {
  return Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
}

/** How long an invite link works. */
export const INVITE_DAYS = 7;
/** Pending invites one person can have at a time. */
export const MAX_PENDING_INVITES = 20;
export const MAX_GROUP_MEMBERS = 50;
export const INVITE_TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;

/** What the app sees of an invite: never the token, which only the response that made it carries. */
export const publicInvite = (i: InviteRow) => ({
  id: i.id, email: i.email, group_id: null, created_at: i.created_at, expires_at: i.expires_at,
});

/** "jane.doe" -> "Jane Doe" */
function titleCase(s: string): string {
  return s.replace(/\S+/g, (w) => w[0]!.toUpperCase() + w.slice(1).toLowerCase());
}

export class Accounts {
  /** Refuses notes and names with a word on the moderation list. */
  readonly screen: ReturnType<typeof screener>;

  constructor(private db: Database, private config: Config) {
    this.screen = screener(config.dataDir);
  }

  /** In: let in by an invite, or signed up before invites (users.member). Checked at sign-in and on every request. */
  isMember(userId: string): boolean {
    return !!this.db.query("SELECT 1 FROM users WHERE id = ? AND member = 1").get(userId);
  }

  // -- invites (#5)

  /** `userId` null: an admin's invite from `links-server invite`, which no one's 20 count includes. */
  createInvite(userId: string | null, email: unknown): { invite: ReturnType<typeof publicInvite>; token: string } {
    let bound: string | null = null;
    if (email !== undefined && email !== null && String(email).trim() !== "") {
      bound = String(email).trim().toLowerCase();
      if (bound.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(bound)) throw new BadRequest("That doesn't look like an email address.");
    }
    const t = now();
    const pending = userId === null ? 0 : this.pendingInvites(userId).length;
    if (pending >= MAX_PENDING_INVITES) throw new BadRequest("You have a lot of invites waiting. Cancel some first.");
    const token = randomToken();
    const row = this.db.query(`INSERT INTO invites (token_hash, email, invited_by, created_at, expires_at)
        VALUES (?, ?, ?, ?, ?) RETURNING *`)
      .get(sha256(token), bound, userId, t, t + INVITE_DAYS * 86400) as InviteRow;
    return { invite: publicInvite(row), token };
  }

  /** Mine that still need someone to join, newest first. */
  pendingInvites(userId: string) {
    return (this.db.query(`SELECT i.* FROM invites i WHERE i.invited_by = ? AND i.used_at IS NULL AND i.expires_at > ?
        AND NOT EXISTS (SELECT 1 FROM users u JOIN group_members m ON m.user_id = u.id
          JOIN groups g ON g.id = m.group_id AND g.is_direct = 1
          JOIN group_members f ON f.group_id = g.id AND f.user_id = i.invited_by
          WHERE u.email = i.email COLLATE NOCASE AND u.email_verified = 1 AND u.member = 1
            AND u.id != i.invited_by)
        ORDER BY i.created_at DESC, i.id DESC`)
      .all(userId, now()) as InviteRow[]).map(publicInvite);
  }

  /** Revoked links stop working at once. Only whoever sent an invite can take it back. */
  revokeInvite(userId: string, id: number): boolean {
    return this.db.run("DELETE FROM invites WHERE id = ? AND invited_by = ? AND used_at IS NULL", [id, userId]).changes > 0;
  }

  /**
   * A link's invite if it still works (unused, not expired, not revoked), for the /invite page. Never
   * uses it up. `inviter` is null for an admin's invite.
   */
  pendingInvite(token: string): (InviteRow & { inviter: string | null }) | null {
    if (!INVITE_TOKEN_RE.test(token)) return null;
    return this.db.query(`SELECT i.*, u.name AS inviter FROM invites i LEFT JOIN users u ON u.id = i.invited_by
        WHERE i.token_hash = ? AND i.used_at IS NULL AND i.expires_at > ?`)
      .get(sha256(token), now()) as (InviteRow & { inviter: string | null }) | null;
  }

  openInvite(token: string) {
    if (!INVITE_TOKEN_RE.test(token)) return null;
    return this.db.query(`SELECT i.*, u.name AS inviter FROM chat_invite_links i
      LEFT JOIN users u ON u.id = i.created_by WHERE i.token = ?`).get(token) as
      { group_id: number; created_by: string | null; inviter: string | null } | null;
  }

  chatLink(groupId: number) {
    const row = this.db.query("SELECT * FROM chat_invite_links WHERE group_id = ?").get(groupId) as
      { token: string; created_at: number; created_by: string | null } | null;
    return row ? { url: `${this.config.publicUrl}/invite/${row.token}`, created_at: row.created_at, created_by: row.created_by } : null;
  }

  resetChatLink(groupId: number, userId: string) {
    this.db.run(`INSERT INTO chat_invite_links (group_id, token, created_by, created_at) VALUES (?, ?, ?, ?)
      ON CONFLICT(group_id) DO UPDATE SET token = excluded.token, created_by = excluded.created_by, created_at = excluded.created_at`,
      [groupId, randomToken(), userId, now()]);
    return this.chatLink(groupId);
  }

  addGroupMembers(groupId: number, ids: string[]) {
    const have = (this.db.query("SELECT user_id FROM group_members WHERE group_id = ?").all(groupId) as { user_id: string }[])
      .map((m) => m.user_id);
    const added = [...new Set(ids)].filter((id) => !have.includes(id));
    if (added.length && have.length + added.length > MAX_GROUP_MEMBERS) {
      throw new BadRequest(`A chat can have up to ${MAX_GROUP_MEMBERS} people.`);
    }
    for (const user of added) {
      this.db.run("INSERT INTO group_members (group_id, user_id, joined_at) VALUES (?, ?, ?)", [groupId, user, now()]);
    }
    for (const user of added) ensureDirectChatsFor(this.db, user, groupId);
    return added;
  }

  /**
   * The invite that lets this person in, if any: the link's token (bound to their email, if it names
   * one), or else one sent to their email. An email only counts once WorkOS has verified it.
   */
  private findInvite(token: string, email: string, verified: boolean): InviteRow | null {
    const t = now();
    if (token && INVITE_TOKEN_RE.test(token)) {
      const row = this.db.query("SELECT * FROM invites WHERE token_hash = ? AND used_at IS NULL AND expires_at > ?")
        .get(sha256(token), t) as InviteRow | null;
      // Hide My Email: the link was sent to them, but Apple signs them in with a relay address.
      if (row && (!row.email || (verified && (row.email.toLowerCase() === email.toLowerCase() || appleRelay(email))))) return row;
    }
    if (!email || !verified) return null;
    return this.db.query("SELECT * FROM invites WHERE email = ? COLLATE NOCASE AND used_at IS NULL AND expires_at > ? ORDER BY created_at LIMIT 1")
      .get(email, t) as InviteRow | null;
  }

  mePayload(userId: string) {
    const user = this.db.query("SELECT * FROM users WHERE id = ?").get(userId) as UserRow;
    return {
      user: { ...publicUser(user, this.config.publicUrl), email: user.email },
      claimable: this.claimable(user).map((u) => publicUser(u, this.config.publicUrl)),
      notifications: { watched: !!user.push_watched, reactions: !!user.push_reactions },
    };
  }

  /** `{watched?, reactions?}`: which pushes about the links they sent this person gets. */
  setNotifications(userId: string, settings: unknown) {
    if (!settings || typeof settings !== "object" || Array.isArray(settings)) throw new BadRequest("notifications must be an object.");
    const { watched, reactions } = settings as Record<string, unknown>;
    for (const v of [watched, reactions]) {
      if (v !== undefined && typeof v !== "boolean") throw new BadRequest("Notification settings are true or false.");
    }
    if (watched !== undefined) this.db.run("UPDATE users SET push_watched = ? WHERE id = ?", [watched ? 1 : 0, userId]);
    if (reactions !== undefined) this.db.run("UPDATE users SET push_reactions = ? WHERE id = ?", [reactions ? 1 : 0, userId]);
  }

  /**
   * The legacy people this account may be: those an admin let it claim (`links-server claim`). A
   * typed name proves nothing, since anyone can rename themselves to it. Their history is in the
   * default chat, so only its members get any.
   */
  private claimable(user: UserRow): UserRow[] {
    if (!this.inDefault(user.id)) return [];
    return this.db.query("SELECT * FROM users WHERE id LIKE ? AND claimable_by = ? ORDER BY created_at")
      .all(`${LEGACY}%`, user.id) as UserRow[];
  }

  /** Unclaimed legacy people, with how many links each sent and the email of whoever may claim them. */
  legacyPeople(): (UserRow & { links: number; claimer: string | null })[] {
    return this.db.query(`SELECT u.*, (SELECT COUNT(*) FROM links l WHERE l.added_by = u.id) AS links,
          (SELECT c.email FROM users c WHERE c.id = u.claimable_by) AS claimer
        FROM users u WHERE u.id LIKE ? ORDER BY u.created_at`).all(`${LEGACY}%`) as (UserRow & { links: number; claimer: string | null })[];
  }

  /**
   * Let the account with this email claim the legacy person with this name (any case), replacing any
   * earlier approval; the app then offers "Claim Earlier Links…". For the admin, who checks first.
   */
  approveClaim(email: string, name: string): { user: UserRow; legacy: UserRow } {
    const users = this.usersWithEmail(email);
    if (users.length !== 1) throw new BadRequest(users.length ? `more than one account has the email ${email}` : `no account with the email ${email}`);
    const user = users[0]!;
    if (!this.inDefault(user.id)) throw new BadRequest(`${user.name} isn't in the default chat, where legacy history is`);
    const matches = this.legacyPeople().filter((p) => p.name.trim().toLowerCase() === name.trim().toLowerCase());
    const legacy = matches.find((p) => p.name === name.trim()) ?? (matches.length === 1 ? matches[0] : undefined);
    if (!legacy) throw new BadRequest(matches.length ? `more than one legacy person is called ${name}; give the exact name` : `no unclaimed legacy person called ${name}`);
    this.db.run("UPDATE users SET claimable_by = ? WHERE id = ?", [user.id, legacy.id]);
    return { user, legacy: { ...legacy, claimable_by: user.id } };
  }

  /** Create the account on first sign-in. Afterwards, keep the name they chose. */
  upsertUser(id: string, email: string, name: string, avatar: string | null) {
    const exists = this.db.query("SELECT 1 FROM users WHERE id = ?").get(id);
    if (exists) {
      this.db.run("UPDATE users SET email = ?, avatar = COALESCE(?, avatar) WHERE id = ?", [email, avatar, id]);
    } else {
      this.db.run("INSERT INTO users (id, email, name, avatar, created_at) VALUES (?, ?, ?, ?, ?)",
        [id, email, cleanName(name), avatar, now()]);
    }
  }

  /** Not at sign-in (upsertUser): a WorkOS name on the list falls back to one from the email. */
  rename(userId: string, name: unknown) {
    const cleaned = cleanName(name);
    this.screen(cleaned, "name");
    this.db.run("UPDATE users SET name = ? WHERE id = ?", [cleaned, userId]);
  }

  private allowsName(name: string): boolean {
    try {
      this.screen(cleanName(name), "name");
      return true;
    } catch {
      return false;
    }
  }

  newSession(userId: string): string {
    const token = randomToken();
    const t = now();
    this.db.run("INSERT INTO sessions (token_hash, user_id, created_at, last_used) VALUES (?, ?, ?, ?)",
      [sha256(token), userId, t, t]);
    return token;
  }

  /** The signed-in user's id for a bearer token, or null. Sliding expiry. */
  sessionUser(token: string | null): string | null {
    if (!token) return null;
    const digest = sha256(token);
    const row = this.db.query(
      "SELECT s.user_id, s.last_used, u.member FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash = ?",
    ).get(digest) as { user_id: string; last_used: number; member: number } | null;
    if (!row) return null;
    const t = now();
    if (t - row.last_used > this.config.sessionDays * 86400) {
      this.db.run("DELETE FROM sessions WHERE token_hash = ?", [digest]);
      return null;
    }
    if (!row.member) return null; // no way to read anything without being let in
    if (t - row.last_used > 3600) this.db.run("UPDATE sessions SET last_used = ? WHERE token_hash = ?", [t, digest]);
    return row.user_id;
  }

  /** How a session is stored (its token's hash), for rows that belong to it, like device tokens. */
  sessionHash(token: string): string {
    return sha256(token);
  }

  /** Sessions used within SESSION_DAYS: with membership, the ones pushes go to. */
  isLive(lastUsed: number): boolean {
    return now() - lastUsed <= this.config.sessionDays * 86400;
  }

  endSession(token: string) {
    this.db.run("DELETE FROM sessions WHERE token_hash = ?", [sha256(token)]);
  }

  /**
   * "That was me": move a pre-sign-in person's links, seen marks, reactions, and the blocks and
   * reports on them onto this account. A block of themselves fails the CHECK, so it's skipped and
   * cascades away with the legacy row.
   */
  claimLegacy(userId: string, legacyId: string) {
    this.db.transaction(() => {
      const me = this.db.query("SELECT * FROM users WHERE id = ?").get(userId) as UserRow;
      const legacy = this.claimable(me).find((p) => p.id === legacyId);
      if (!legacy) throw new BadRequest("That person was already claimed.");
      this.db.run("UPDATE links SET added_by = ? WHERE added_by = ?", [userId, legacyId]);
      this.db.run("UPDATE comments SET person = ? WHERE person = ?", [userId, legacyId]);
      this.db.run("UPDATE OR IGNORE group_members SET user_id = ? WHERE user_id = ?", [userId, legacyId]);
      for (const table of ["seen", "reactions"]) {
        this.db.run(`UPDATE OR IGNORE ${table} SET person = ? WHERE person = ?`, [userId, legacyId]);
        this.db.run(`DELETE FROM ${table} WHERE person = ?`, [legacyId]);
      }
      for (const [table, col] of [["blocks", "blocker"], ["blocks", "blocked"], ["reports", "reporter"], ["reports", "user_id"]]) {
        this.db.run(`UPDATE OR IGNORE ${table} SET ${col} = ? WHERE ${col} = ?`, [userId, legacyId]);
      }
      this.db.run("UPDATE users SET name = ? WHERE id = ?", [legacy.name, userId]);
      this.db.run("DELETE FROM users WHERE id = ?", [legacyId]);
      ensureDirectChatsFor(this.db, userId);
    })();
  }

  /**
   * Replace this person's photo with `bytes` (a JPEG or PNG), stored under `photos/` by a new random
   * token, so the address changes with every upload and phones never show a cached old one.
   * `write` runs the database change (the caller's asUser, so a deleted account gets no photo).
   */
  setPhoto(userId: string, bytes: Uint8Array, write: <T>(change: () => T) => T = (change) => change()) {
    if (bytes.length > MAX_PHOTO_BYTES) throw new BadRequest("That photo is too big.");
    const size = photoType(bytes) && isComplete(bytes) ? imageSize(bytes) : null;
    if (!size) throw new BadRequest("That isn't a JPEG or PNG photo.");
    if (size.width > MAX_PHOTO_SIDE || size.height > MAX_PHOTO_SIDE) throw new BadRequest("That photo is too big.");
    const token = randomBytes(24).toString("base64url");
    const path = this.photoPath(token);
    writeFileSync(`${path}.part`, bytes);
    renameSync(`${path}.part`, path);
    let old: string | null;
    try {
      old = write(() => this.swapPhoto(userId, token));
    } catch (e) {
      rmSync(path, { force: true });
      throw e;
    }
    this.removePhotoFile(old);
  }

  /** Back to initials: "" also hides the WorkOS picture, which the next sign-in would bring back. */
  removePhoto(userId: string, write: <T>(change: () => T) => T = (change) => change()) {
    this.removePhotoFile(write(() => this.swapPhoto(userId, "")));
  }

  /** The current photo's token, for GET /photos/:token; null once it's replaced, removed or its account deleted. */
  photoOwner(token: string): string | null {
    if (!token) return null;
    return (this.db.query("SELECT id FROM users WHERE photo = ?").get(token) as { id: string } | null)?.id ?? null;
  }

  /** Copies a reported person's photo to `reportPhoto(token)` for a saved report, which keeps it after they change it. */
  keepPhotoForReport(token: string): boolean {
    try {
      copyFileSync(this.photoPath(token), join(this.config.dataDir, reportPhoto(token)));
      return true;
    } catch {
      return false;
    }
  }

  photoPath(token: string) {
    return join(this.config.dataDir, "photos", token);
  }

  private swapPhoto(userId: string, photo: string): string | null {
    const old = this.db.query("SELECT photo FROM users WHERE id = ?").get(userId) as { photo: string | null } | null;
    this.db.run("UPDATE users SET photo = ? WHERE id = ?", [photo, userId]);
    return old?.photo ?? null;
  }

  private removePhotoFile(token: string | null) {
    if (token) rmSync(this.photoPath(token), { force: true });
  }

  /**
   * Delete an account (App Store guideline 5.1.1(v)), in one transaction: the user, their sessions,
   * their seen marks and reactions, and the links they sent with their notes (for everyone, so
   * others' marks and reactions on them go too), then those links' thumbnails. Then the WorkOS user
   * goes too, if the server has an API key to do that with.
   */
  async deleteUser(userId: string): Promise<{ links: number; workos: "deleted" | "skipped" | "failed" }> {
    const sent = this.db.transaction(() => {
      const photo = (this.db.query("SELECT photo FROM users WHERE id = ?").get(userId) as { photo: string | null } | null)?.photo ?? null;
      const copies = this.db.query("SELECT DISTINCT json_extract(snapshot, '$.photo_copy') AS copy FROM reports WHERE (user_id = ? OR reporter = ?) AND json_extract(snapshot, '$.photo_copy') IS NOT NULL")
        .all(userId, userId) as { copy: string }[];
      const ids = this.db.query("DELETE FROM links WHERE added_by = ? RETURNING id").all(userId) as { id: number }[];
      this.db.run("DELETE FROM seen WHERE person = ?", [userId]);
      this.db.run("DELETE FROM reactions WHERE person = ?", [userId]);
      this.db.run("DELETE FROM users WHERE id = ?", [userId]); // sessions and memberships cascade
      return { ids, orphaned: deleteEmptyGroups(this.db), photo, copies };
    })();
    this.removePhotoFile(sent.photo);
    this.db.transaction(() => {
      for (const { copy } of sent.copies) {
        if (!this.db.query("SELECT 1 FROM reports WHERE json_extract(snapshot, '$.photo_copy') = ?").get(copy)) {
          rmSync(join(this.config.dataDir, copy), { force: true });
        }
      }
    }).immediate();
    for (const id of [...sent.ids.map((r) => r.id), ...sent.orphaned]) {
      rmSync(join(this.config.dataDir, "thumbs", String(id)), { force: true });
    }
    return { links: sent.ids.length, workos: await this.deleteWorkOSUser(userId) };
  }

  /** Best effort: the Links account is already gone, so a failure here is only logged. */
  private async deleteWorkOSUser(userId: string): Promise<"deleted" | "skipped" | "failed"> {
    // Only WorkOS ids: not mint-session's local_ people or legacy ones.
    if (!this.config.workosApiKey || !userId.startsWith("user_")) return "skipped";
    try {
      const res = await fetch(`${this.config.workosApi}/user_management/users/${encodeURIComponent(userId)}`, {
        method: "DELETE",
        headers: { Authorization: `Bearer ${this.config.workosApiKey}`, "User-Agent": "SharedLinks/2.0" },
        signal: AbortSignal.timeout(10_000),
      });
      if (res.ok || res.status === 404) return "deleted"; // 404: already gone
      console.error(`WorkOS delete user ${userId} failed (${res.status}): ${(await res.text()).slice(0, 500)}`);
    } catch (e) {
      console.error(`WorkOS delete user ${userId} failed: ${e}`);
    }
    return "failed";
  }

  // -- WorkOS AuthKit

  authorizeUrl(challenge: string, state: string, screenHint?: string | null): string {
    if (!this.config.workosClientId) throw new AuthError("Sign-in isn't set up on the server (WORKOS_CLIENT_ID).", 503);
    if (!/^[A-Za-z0-9_-]{43,128}$/.test(challenge) || state.length > 200) throw new BadRequest("Bad sign-in request.");
    const params = new URLSearchParams({
      client_id: this.config.workosClientId,
      response_type: "code",
      provider: "authkit",
      redirect_uri: `${this.config.publicUrl}/auth/callback`,
      code_challenge: challenge,
      code_challenge_method: "S256",
      state,
    });
    if (screenHint === "sign-in" || screenHint === "sign-up") params.set("screen_hint", screenHint);
    return `${this.config.workosApi}/user_management/authorize?${params}`;
  }

  /** Exchange an AuthKit authorization code (PKCE) for the WorkOS user, then start our own session. */
  async signIn(code: string, codeVerifier: string, userAgent: string, inviteToken = "") {
    if (!this.config.workosClientId) throw new AuthError("Sign-in isn't set up on the server (WORKOS_CLIENT_ID).", 503);
    if (!code || !codeVerifier) throw new AuthError("Missing authorization code.", 400);
    const body: Record<string, string> = {
      client_id: this.config.workosClientId,
      grant_type: "authorization_code",
      code,
      code_verifier: codeVerifier,
      user_agent: userAgent.slice(0, 300),
    };
    if (this.config.workosApiKey) body.client_secret = this.config.workosApiKey;
    const res = await fetch(`${this.config.workosApi}/user_management/authenticate`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json", "User-Agent": "SharedLinks/2.0" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(15_000),
    });
    const data = (await res.json().catch(() => ({}))) as Record<string, any>;
    if (!res.ok) {
      console.error(`WorkOS authenticate failed (${res.status}): ${JSON.stringify(data)}`);
      // 400, not 401: the client treats 401 as "your session ended" and would hide this message.
      throw new AuthError(data.error_description ?? data.message ?? "Sign-in failed. Try again.", 400);
    }
    const user = data.user as { id: string; email?: string; email_verified?: boolean; first_name?: string;
                                profile_picture_url?: string | null };
    const email = user.email ?? "";
    // A WorkOS name with a listed word doesn't stop the sign-in: the next name in line is used.
    const name = [user.first_name, titleCase((email.split("@")[0] ?? "").replace(/\./g, " "))]
      .find((n) => n && this.allowsName(n)) ?? "Someone";
    const avatar = user.profile_picture_url || null;
    // One transaction: two phones redeeming the same invite can't both get in on it.
    const groupId = this.db.transaction((): number | null => {
      if (this.isMember(user.id)) {
        this.upsertUser(user.id, email, name, avatar);
        this.db.run("UPDATE users SET email_verified = ? WHERE id = ?", [user.email_verified ? 1 : 0, user.id]);
        if (!inviteToken) return null;
        // Already in: the link still takes them to its chat, but a link that doesn't work stops no one signing in.
        try {
          return this.useInviteAsMember(user.id, inviteToken);
        } catch (e) {
          if (e instanceof AuthError || e instanceof BadRequest) return null;
          throw e;
        }
      }
      if (this.openInvite(inviteToken)) {
        throw new AuthError("Chat invite links only work for people already on Links for now. Ask a friend for a personal invite.", 403);
      }
      const invite = this.findInvite(inviteToken, email, !!user.email_verified);
      if (!invite) {
        if (!user.email_verified && email && this.findInvite(inviteToken, email, true)) {
          throw new AuthError("Verify your email address, then sign in again.", 403);
        }
        if (inviteToken && this.pendingInvite(inviteToken)?.email) {
          throw new AuthError("This invite is for a different email address. Sign in with the one it was sent to.", 403);
        }
        if (appleRelay(email)) {
          throw new AuthError("Links is invite-only, and you signed in with Hide My Email. If you're already in, sign in the way you did before; if not, tap a friend's invite link first.", 403);
        }
        throw new AuthError("Links is invite-only. Ask a friend who uses it to invite you, then tap their invite link.", 403);
      }
      this.upsertUser(user.id, email, name, avatar);
      this.db.run("UPDATE users SET email_verified = ? WHERE id = ?", [user.email_verified ? 1 : 0, user.id]);
      const group = this.admit(user.id, invite);
      this.useUp(invite, user.id, group);
      console.log(`invite ${invite.id} from ${invite.invited_by ?? "admin"} used by ${user.id}`);
      return group;
    }).immediate();
    // `group_id`: the chat an invite just took them to, for the app to open.
    return { token: this.newSession(user.id), ...this.mePayload(user.id), group_id: groupId };
  }

  /** An invite never gives access to a group; only the local mint-session command seeds Everyone. */
  private admit(userId: string, invite?: InviteRow): number | null {
    this.db.run("UPDATE users SET member = 1 WHERE id = ?", [userId]);
    // An account from before invites that wasn't let in was still put in the default chat by v8.
    this.db.run("DELETE FROM group_members WHERE user_id = ?", [userId]);
    if (invite) return invite.invited_by ? ensureDirectChat(this.db, invite.invited_by, userId) : null;
    const group = defaultGroup(this.db);
    this.db.run("INSERT OR IGNORE INTO group_members (group_id, user_id, joined_at) VALUES (?, ?, ?)", [group, userId, now()]);
    ensureDirectChatsFor(this.db, userId, group);
    return group;
  }

  /**
   * Someone already in opens a friend's invite link: connect the two people. An open invite stays
   * pending if they were already connected; a verified recipient uses up an email-bound invite.
   */
  joinWithInvite(userId: string, token: string): number | null {
    return this.db.transaction(() => this.useInviteAsMember(userId, token)).immediate();
  }

  private useInviteAsMember(userId: string, token: string): number | null {
    const open = this.openInvite(token);
    if (open) {
      this.addGroupMembers(open.group_id, [userId]);
      return open.group_id;
    }
    const row = INVITE_TOKEN_RE.test(token)
      ? this.db.query("SELECT * FROM invites WHERE token_hash = ?").get(sha256(token)) as InviteRow | null
      : null;
    if (row && row.used_by === userId) {
      // Opened again after it let them in: back to the chat it took them to, if they're still there.
      const went = row.group_id;
      return went !== null && this.inGroup(went, userId) ? went : null;
    }
    if (!row || row.used_at !== null || row.expires_at <= now()) throw new AuthError("This invite doesn't work anymore.", 404);
    if (!row.invited_by || row.invited_by === userId) return null;
    const me = this.db.query("SELECT email, email_verified FROM users WHERE id = ?").get(userId) as
      { email: string | null; email_verified: number } | null;
    const email = me?.email ?? "";
    const pair = directChat(this.db, row.invited_by, userId);
    if (row.email) {
      if (row.email.toLowerCase() !== email.toLowerCase() && !appleRelay(email)) {
        throw new AuthError("This invite is for a different email address.", 403);
      }
      if (!me?.email_verified) {
        if (pair !== null) return pair;
        throw new AuthError("Verify your email address, then sign in again.", 403);
      }
    }
    const direct = pair ?? ensureDirectChat(this.db, row.invited_by, userId);
    if (pair === null || row.email) this.useUp(row, userId, direct);
    return direct;
  }

  /** Marks it used, keeping the chat a friend's invite took them to, for when they open it again. */
  private useUp(invite: InviteRow, userId: string, group: number | null) {
    this.db.run("UPDATE invites SET used_by = ?, used_at = ?, group_id = ? WHERE id = ?",
      [userId, now(), group, invite.id]);
  }

  private inGroup(groupId: number, userId: string): boolean {
    return !!this.db.query("SELECT 1 FROM group_members WHERE group_id = ? AND user_id = ?").get(groupId, userId);
  }

  private inDefault(userId: string): boolean {
    return !!this.db.query("SELECT 1 FROM group_members WHERE group_id = ? AND user_id = ?").get(defaultGroup(this.db), userId);
  }

  /** Signed-in people (not legacy ones) with this email, for the admin commands. */
  usersWithEmail(email: string): UserRow[] {
    return this.db.query("SELECT * FROM users WHERE email = ? COLLATE NOCASE AND id NOT LIKE ? ORDER BY created_at")
      .all(email, `${LEGACY}%`) as UserRow[];
  }

  /** Admin escape hatch (and how to sign in a Simulator build without WorkOS). */
  mintSession(email: string, name?: string): string {
    const row = this.db.query("SELECT id FROM users WHERE email = ? COLLATE NOCASE AND id NOT LIKE ?")
      .get(email, `${LEGACY}%`) as { id: string } | null;
    const id = row?.id ?? `local_${Buffer.from(crypto.getRandomValues(new Uint8Array(8))).toString("hex")}`;
    this.upsertUser(id, email, name || titleCase(email.split("@")[0] ?? "Someone"), null);
    this.db.run("UPDATE users SET email_verified = 1 WHERE id = ?", [id]); // the admin minting it vouches for the email
    this.db.transaction(() => {
      if (!this.isMember(id)) this.admit(id); // and for them
    }).immediate();
    return this.newSession(id);
  }
}

/** Sign in with Apple's Hide My Email addresses, which never match an email anyone was invited with. */
function appleRelay(email: string): boolean {
  return /@(privaterelay\.appleid\.com|private\.icloud\.com)$/i.test(email);
}
