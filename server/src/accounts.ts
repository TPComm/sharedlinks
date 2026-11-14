import type { Database } from "bun:sqlite";
import { rmSync } from "node:fs";
import { join } from "node:path";
import type { Config } from "./config.ts";
import { LEGACY, now, type UserRow } from "./db.ts";
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

  emailAllowed(email: string | null | undefined): boolean {
    const list = this.config.allowedEmails;
    if (!list.length) return true;
    const e = (email ?? "").toLowerCase();
    return list.some((a) => e === a || (a.startsWith("@") && e.endsWith(a)));
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
      "SELECT s.user_id, s.last_used, u.email FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash = ?",
    ).get(digest) as { user_id: string; last_used: number; email: string | null } | null;
    if (!row) return null;
    const t = now();
    if (t - row.last_used > this.config.sessionDays * 86400) {
      this.db.run("DELETE FROM sessions WHERE token_hash = ?", [digest]);
      return null;
    }
    if (!this.emailAllowed(row.email)) return null;
    if (t - row.last_used > 3600) this.db.run("UPDATE sessions SET last_used = ? WHERE token_hash = ?", [t, digest]);
    return row.user_id;
  }

  /** How a session is stored (its token's hash), for rows that belong to it, like device tokens. */
  sessionHash(token: string): string {
    return sha256(token);
  }

  /** Sessions used within SESSION_DAYS, of people still on the guest list: the ones pushes go to. */
  isLive(lastUsed: number, email: string | null): boolean {
    return now() - lastUsed <= this.config.sessionDays * 86400 && this.emailAllowed(email);
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
  async signIn(code: string, codeVerifier: string, userAgent: string) {
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
    if (!this.emailAllowed(email)) throw new AuthError(`${email} isn't on the guest list for this Links.`, 403);
    if (this.config.allowedEmails.length && !user.email_verified) {
      throw new AuthError("Verify your email address, then sign in again.", 403);
    }
    // A WorkOS name with a listed word doesn't stop the sign-in: the next name in line is used.
    const name = [user.first_name, titleCase((email.split("@")[0] ?? "").replace(/\./g, " "))]
      .find((n) => n && this.allowsName(n)) ?? "Someone";
    this.upsertUser(user.id, email, name, user.profile_picture_url || null);
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
    return this.newSession(id);
  }
}
