import type { Database } from "bun:sqlite";
import { rmSync } from "node:fs";
import { join } from "node:path";
import type { Config } from "./config.ts";
import { LEGACY, now, type InviteRow, type UserRow } from "./db.ts";
import { BadRequest, clip } from "./links.ts";
import { screener } from "./moderation.ts";

export class AuthError extends Error {
  constructor(message: string, readonly status = 401) {
    super(message);
  }
}

export const publicUser = (u: UserRow) => ({ id: u.id, name: u.name, avatar: u.avatar });

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
export const INVITE_TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;

/** What the app sees of an invite: never the token, which only the response that made it carries. */
export const publicInvite = (i: InviteRow) => ({
  id: i.id, email: i.email, created_at: i.created_at, expires_at: i.expires_at,
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
    const pending = userId === null ? 0 : (this.db.query("SELECT COUNT(*) AS n FROM invites WHERE invited_by = ? AND used_at IS NULL AND expires_at > ?")
      .get(userId, t) as { n: number }).n;
    if (pending >= MAX_PENDING_INVITES) throw new BadRequest("You have a lot of invites waiting. Cancel some first.");
    const token = randomToken();
    const row = this.db.query(`INSERT INTO invites (token_hash, email, invited_by, created_at, expires_at)
        VALUES (?, ?, ?, ?, ?) RETURNING *`)
      .get(sha256(token), bound, userId, t, t + INVITE_DAYS * 86400) as InviteRow;
    return { invite: publicInvite(row), token };
  }

  /** Mine that nobody has used yet and that still work, newest first. */
  pendingInvites(userId: string) {
    return (this.db.query("SELECT * FROM invites WHERE invited_by = ? AND used_at IS NULL AND expires_at > ? ORDER BY created_at DESC, id DESC")
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
    const claimable = (this.db.query("SELECT * FROM users WHERE id LIKE ? ORDER BY created_at")
      .all(`${LEGACY}%`) as UserRow[]).map(publicUser);
    return { user: { ...publicUser(user), email: user.email }, claimable };
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
      const legacy = this.db.query("SELECT name FROM users WHERE id = ? AND id LIKE ?")
        .get(legacyId, `${LEGACY}%`) as { name: string } | null;
      if (!legacy) throw new BadRequest("That person was already claimed.");
      this.db.run("UPDATE links SET added_by = ? WHERE added_by = ?", [userId, legacyId]);
      for (const table of ["seen", "reactions"]) {
        this.db.run(`UPDATE OR IGNORE ${table} SET person = ? WHERE person = ?`, [userId, legacyId]);
        this.db.run(`DELETE FROM ${table} WHERE person = ?`, [legacyId]);
      }
      for (const [table, col] of [["blocks", "blocker"], ["blocks", "blocked"], ["reports", "reporter"], ["reports", "user_id"]]) {
        this.db.run(`UPDATE OR IGNORE ${table} SET ${col} = ? WHERE ${col} = ?`, [userId, legacyId]);
      }
      this.db.run("UPDATE users SET name = ? WHERE id = ?", [legacy.name, userId]);
      this.db.run("DELETE FROM users WHERE id = ?", [legacyId]);
    })();
  }

  /**
   * Delete an account (App Store guideline 5.1.1(v)), in one transaction: the user, their sessions,
   * their seen marks and reactions, and the links they sent with their notes (for everyone, so
   * others' marks and reactions on them go too), then those links' thumbnails. Then the WorkOS user
   * goes too, if the server has an API key to do that with.
   */
  async deleteUser(userId: string): Promise<{ links: number; workos: "deleted" | "skipped" | "failed" }> {
    const sent = this.db.transaction(() => {
      const ids = this.db.query("DELETE FROM links WHERE added_by = ? RETURNING id").all(userId) as { id: number }[];
      this.db.run("DELETE FROM seen WHERE person = ?", [userId]);
      this.db.run("DELETE FROM reactions WHERE person = ?", [userId]);
      this.db.run("DELETE FROM users WHERE id = ?", [userId]); // sessions cascade
      return ids;
    })();
    for (const { id } of sent) rmSync(join(this.config.dataDir, "thumbs", String(id)), { force: true });
    return { links: sent.length, workos: await this.deleteWorkOSUser(userId) };
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
    this.db.transaction(() => {
      if (this.isMember(user.id)) {
        this.upsertUser(user.id, email, name, avatar);
        return;
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
      this.db.run("UPDATE users SET member = 1 WHERE id = ?", [user.id]);
      this.db.run("UPDATE invites SET used_by = ?, used_at = ? WHERE id = ?", [user.id, now(), invite.id]);
      console.log(`invite ${invite.id} from ${invite.invited_by ?? "admin"} used by ${user.id}`);
    }).immediate();
    return { token: this.newSession(user.id), ...this.mePayload(user.id) };
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
    this.db.run("UPDATE users SET member = 1 WHERE id = ?", [id]); // the admin minting it vouches for them
    return this.newSession(id);
  }
}

/** Sign in with Apple's Hide My Email addresses, which never match an email anyone was invited with. */
function appleRelay(email: string): boolean {
  return /@(privaterelay\.appleid\.com|private\.icloud\.com)$/i.test(email);
}
