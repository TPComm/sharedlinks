import { Database } from "bun:sqlite";
import { randomBytes } from "node:crypto";
import { mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { normalize } from "./links.ts";

export const LEGACY = "legacy:"; // people from the pre-sign-in version, until someone claims them
/**
 * Who sent a link whose sender deleted their account back when Delete Account kept sent links (it
 * deletes them now). There's no users row for it, so no account, however it signs up again, can
 * ever own those links; the app shows them as from "Deleted user".
 */
export const DELETED_USER = "deleted";

export interface LinkRow {
  id: number;
  share_token: string;
  url: string;
  platform: string;
  title: string | null;
  author: string | null;
  thumb_type: string | null;
  description: string | null;
  site_name: string | null;
  thumb_w: number | null;
  thumb_h: number | null;
  /** The PREVIEW_VERSION (see previews.ts) its preview was last fetched with. */
  preview_v: number;
  /** Bumped each time the thumbnail file is replaced, so clients' caches (keyed by its URL) refetch it. */
  thumb_v: number;
  meta: "pending" | "done" | "failed";
  note: string;
  added_by: string;
  added_at: number;
  group_id: number;
}

export interface UserRow {
  id: string;
  email: string | null;
  name: string;
  avatar: string | null;
  created_at: number;
  /** 1 once they're in: an invite let them in, or they'd signed up before invites (see migrateToV7). */
  member: number;
  /** On a legacy person: the account `links-server claim` let claim them (see migrateToV10). */
  claimable_by: string | null;
  /** 1 (the default) to get a push when someone watches a link they sent (see migrateToV11). */
  push_watched: number;
  /** 1 (the default) to get a push when someone reacts to a link they sent. */
  push_reactions: number;
  /** 1 if WorkOS had verified `email` when they last signed in, or an admin vouched for it (see migrateToV13). */
  email_verified: number;
  /**
   * The photo they uploaded, as its file's token under `photos/` (see migrateToV17); "" once they
   * removed their photo; null to use `avatar`, the picture WorkOS has for them.
   */
  photo: string | null;
}

export interface CommentRow {
  id: number;
  link_id: number;
  person: string;
  body: string;
  created_at: number;
  edited_at: number | null;
}

export interface GroupRow {
  id: number;
  /** Empty: the app names it after its members. */
  name: string;
  created_by: string | null;
  created_at: number;
  /** 1 for the legacy chat everyone was in before groups (see migrateToV8). */
  is_default: number;
  /** 1 for a private chat between two people, with no group invites or additional members. */
  is_direct: number;
}

export interface InviteRow {
  id: number;
  token_hash: string;
  /** Lets this person in even without the token (they installed from the App Store first). */
  email: string | null;
  invited_by: string | null;
  created_at: number;
  expires_at: number;
  used_by: string | null;
  used_at: number | null;
  /**
   * The inviter's chat the new member joins; null: a new chat of just the two of them. Once a
   * friend's invite is used, the chat it took them to.
   */
  group_id: number | null;
}

/**
 * AUTOINCREMENT so a deleted link's id is never handed out again: clients cache thumbnails and
 * widgets act by id, and a late preview fetch for a deleted link must not land on a new one.
 */
function linksTable(name: string, ifNotExists = false) {
  return `CREATE TABLE ${ifNotExists ? "IF NOT EXISTS " : ""}${name} (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      url TEXT NOT NULL UNIQUE,
      platform TEXT NOT NULL,
      title TEXT,
      author TEXT,
      thumb_type TEXT,
      meta TEXT NOT NULL DEFAULT 'pending',
      note TEXT NOT NULL DEFAULT '',
      added_by TEXT NOT NULL,      -- users.id
      added_at REAL NOT NULL
    );`;
}

/** `legacyAllowedEmails`: the old ALLOWED_EMAILS guest list, read once by migrateToV7. */
export function openDatabase(dataDir: string, legacyAllowedEmails: string[] = []): Database {
  mkdirSync(join(dataDir, "thumbs"), { recursive: true });
  mkdirSync(join(dataDir, "photos"), { recursive: true });
  mkdirSync(join(dataDir, "report-photos"), { recursive: true });
  const db = new Database(join(dataDir, "links.db"), { create: true, strict: true });
  db.exec(`
    PRAGMA journal_mode = WAL;
    PRAGMA foreign_keys = ON;
    PRAGMA busy_timeout = 5000;
    ${linksTable("links", true)}
    CREATE TABLE IF NOT EXISTS seen (
      link_id INTEGER NOT NULL REFERENCES links(id) ON DELETE CASCADE,
      person TEXT NOT NULL,        -- users.id
      seen_at REAL NOT NULL,
      PRIMARY KEY (link_id, person)
    );
    CREATE TABLE IF NOT EXISTS reactions (
      link_id INTEGER NOT NULL REFERENCES links(id) ON DELETE CASCADE,
      person TEXT NOT NULL,        -- users.id
      emoji TEXT NOT NULL,
      PRIMARY KEY (link_id, person)
    );
    CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY,         -- WorkOS user id, or legacy:<name>
      email TEXT,
      name TEXT NOT NULL,
      avatar TEXT,
      created_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS sessions (
      token_hash TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      created_at REAL NOT NULL,
      last_used REAL NOT NULL
    );
    -- APNs device tokens. Each belongs to the session that registered it, so signing out (or the
    -- account being deleted) removes it.
    CREATE TABLE IF NOT EXISTS device_tokens (
      token TEXT PRIMARY KEY,            -- hex APNs device token
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      session_hash TEXT NOT NULL REFERENCES sessions(token_hash) ON DELETE CASCADE,
      env TEXT NOT NULL,                 -- 'sandbox' | 'production'
      kind TEXT NOT NULL DEFAULT 'app',  -- later 'widgets', for WidgetKit push
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS device_tokens_user ON device_tokens (user_id);
    CREATE INDEX IF NOT EXISTS device_tokens_session ON device_tokens (session_hash);
    CREATE TABLE IF NOT EXISTS reports (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      reporter TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      link_id INTEGER,             -- no foreign key: the report outlives the link (ids are never reused)
      comment_id INTEGER,          -- for comments (#6)
      user_id TEXT REFERENCES users(id) ON DELETE CASCADE,  -- a person (their name or photo)
      reason TEXT NOT NULL,        -- see REPORT_REASONS in moderation.ts
      details TEXT NOT NULL DEFAULT '',
      snapshot TEXT NOT NULL,      -- JSON copy of what was reported, as it was then
      created_at REAL NOT NULL,
      resolved_at REAL,
      resolution TEXT,
      CHECK ((link_id IS NOT NULL) + (comment_id IS NOT NULL) + (user_id IS NOT NULL) = 1)
    );
    -- NULLs are distinct in a UNIQUE, so one partial index per kind of target stops repeats.
    CREATE UNIQUE INDEX IF NOT EXISTS reports_link ON reports (reporter, link_id) WHERE link_id IS NOT NULL;
    CREATE UNIQUE INDEX IF NOT EXISTS reports_comment ON reports (reporter, comment_id) WHERE comment_id IS NOT NULL;
    CREATE UNIQUE INDEX IF NOT EXISTS reports_user ON reports (reporter, user_id) WHERE user_id IS NOT NULL;
    CREATE TABLE IF NOT EXISTS blocks (
      blocker TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      blocked TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      created_at REAL NOT NULL,
      PRIMARY KEY (blocker, blocked),
      CHECK (blocker <> blocked)
    );
  `);
  migrateFromNames(db);
  migrateToV2(db);
  migrateToV3(db);
  migrateToV4(db);
  migrateToV5(db);
  migrateToV6(db, dataDir);
  migrateToV7(db, legacyAllowedEmails);
  migrateToV8(db);
  migrateToV9(db);
  migrateToV10(db);
  migrateToV11(db);
  migrateToV12(db);
  migrateToV13(db);
  migrateToV14(db);
  migrateToV15(db);
  migrateToV16(db);
  migrateToV17(db);
  migrateToV18(db);
  db.transaction(() => {
    const update = db.query("UPDATE links SET share_token = ? WHERE id = ? AND share_token IS NULL");
    for (const row of db.query("SELECT id FROM links WHERE share_token IS NULL").all() as { id: number }[]) {
      update.run(randomBytes(24).toString("base64url"), row.id);
    }
  })();
  return db;
}

function migrateToV16(db: Database) {
  const { user_version } = db.query("PRAGMA user_version").get() as { user_version: number };
  if (user_version >= 16) return;
  db.transaction(() => {
    db.run("ALTER TABLE links ADD COLUMN share_token TEXT");
    db.run("CREATE UNIQUE INDEX links_share_token ON links(share_token)");
    const update = db.query("UPDATE links SET share_token = ? WHERE id = ?");
    for (const row of db.query("SELECT id FROM links").all() as { id: number }[]) {
      update.run(randomBytes(24).toString("base64url"), row.id);
    }
    db.run("PRAGMA user_version = 16");
  })();
}

function migrateToV17(db: Database) {
  const { user_version } = db.query("PRAGMA user_version").get() as { user_version: number };
  if (user_version >= 17) return;
  db.transaction(() => {
    const have = (db.query("PRAGMA table_info(users)").all() as { name: string }[]).map((c) => c.name);
    if (!have.includes("photo")) db.run("ALTER TABLE users ADD COLUMN photo TEXT");
    db.run("PRAGMA user_version = 17");
  })();
}

function migrateToV18(db: Database) {
  const { user_version } = db.query("PRAGMA user_version").get() as { user_version: number };
  if (user_version >= 18) return;
  db.transaction(() => {
    const have = (db.query("PRAGMA table_info(groups)").all() as { name: string }[]).map((c) => c.name);
    if (!have.includes("is_direct")) {
      db.run("ALTER TABLE groups ADD COLUMN is_direct INTEGER NOT NULL DEFAULT 0 CHECK (is_direct IN (0, 1))");
    }
    const at = now();
    // An old unnamed two-person chat could be a group someone still wants to add others to.
    // Keep the chat, links and invites intact instead of guessing which chats to make private.
    const pairs = db.query(`SELECT DISTINCT a.user_id AS a, b.user_id AS b FROM group_members a
      JOIN group_members b ON b.group_id = a.group_id AND a.user_id < b.user_id
      JOIN users ua ON ua.id = a.user_id JOIN users ub ON ub.id = b.user_id
      WHERE ua.member = 1 AND ub.member = 1 AND ua.id NOT LIKE ?1 AND ub.id NOT LIKE ?1
      ORDER BY a.user_id, b.user_id`).all(`${LEGACY}%`) as { a: string; b: string }[];
    for (const { a, b } of pairs) ensureDirectChat(db, a, b, at);
    // A rolled-back binary still must not expose existing private links to a new member.
    db.exec(`CREATE TRIGGER IF NOT EXISTS direct_members_fixed BEFORE INSERT ON group_members
      WHEN EXISTS (SELECT 1 FROM groups WHERE id = NEW.group_id AND is_direct = 1)
        AND NOT EXISTS (SELECT 1 FROM group_members WHERE group_id = NEW.group_id AND user_id = NEW.user_id)
      BEGIN SELECT RAISE(ABORT, 'Direct chats cannot add members'); END;`);
    db.run("PRAGMA user_version = 18");
  }).immediate();
}

/**
 * v0 (the web app) identified people by a typed name. Keep their history as legacy users
 * that a signed-in person can claim (see claimLegacy in accounts.ts).
 */
function migrateFromNames(db: Database) {
  const { user_version } = db.query("PRAGMA user_version").get() as { user_version: number };
  if (user_version >= 1) return;
  db.transaction(() => {
    const hasPeople = db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'people'").get();
    if (hasPeople) {
      const now = Date.now() / 1000;
      db.run("INSERT OR IGNORE INTO users (id, name, created_at) SELECT ? || name, name, created_at FROM people", [LEGACY]);
      for (const [table, col] of [["links", "added_by"], ["seen", "person"], ["reactions", "person"]] as const) {
        db.run(`INSERT OR IGNORE INTO users (id, name, created_at) SELECT DISTINCT ? || ${col}, ${col}, ? FROM ${table}`, [LEGACY, now]);
        db.run(`UPDATE ${table} SET ${col} = ? || ${col}`, [LEGACY]);
      }
      db.run("DROP TABLE people");
    }
    db.run("PRAGMA user_version = 1");
  })();
}

/**
 * v2: links ids come from AUTOINCREMENT (older tables could reuse the newest deleted id), and
 * stored URLs are re-spelled with today's normalize() so duplicate detection keeps matching links
 * saved by the Python server or before a canonicalisation fix.
 */
function migrateToV2(db: Database) {
  const { user_version } = db.query("PRAGMA user_version").get() as { user_version: number };
  if (user_version >= 2) return;
  const { sql } = db.query("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'links'").get() as { sql: string };
  if (!/AUTOINCREMENT/i.test(sql)) {
    // SQLite's documented table-rebuild procedure; foreign keys off so seen/reactions survive.
    db.exec("PRAGMA foreign_keys = OFF");
    try {
      db.transaction(() => {
        db.exec(linksTable("links_v2"));
        db.exec("INSERT INTO links_v2 (id, url, platform, title, author, thumb_type, meta, note, added_by, added_at) " +
                "SELECT id, url, platform, title, author, thumb_type, meta, note, added_by, added_at FROM links");
        db.exec("DROP TABLE links");
        db.exec("ALTER TABLE links_v2 RENAME TO links");
        const broken = db.query("PRAGMA foreign_key_check").all();
        if (broken.length) throw new Error(`foreign key check failed: ${JSON.stringify(broken)}`);
      })();
    } finally {
      db.exec("PRAGMA foreign_keys = ON");
    }
  }
  db.transaction(() => {
    respellLinks(db);
    db.run("PRAGMA user_version = 2");
  })();
}

/** v3: TikTok posts are spelled /@/video/<id> (see normalize), so stored links are re-spelled again. */
function migrateToV3(db: Database) {
  const { user_version } = db.query("PRAGMA user_version").get() as { user_version: number };
  if (user_version >= 3) return;
  db.transaction(() => {
    respellLinks(db);
    db.run("PRAGMA user_version = 3");
  })();
}

/** v4: X links drop their per-share ?t= token (see normalize), so stored links are re-spelled again. */
function migrateToV4(db: Database) {
  const { user_version } = db.query("PRAGMA user_version").get() as { user_version: number };
  if (user_version >= 4) return;
  db.transaction(() => {
    respellLinks(db);
    db.run("PRAGMA user_version = 4");
  })();
}

/** v5: rich previews keep the description, site name and thumbnail size (#8). */
function migrateToV5(db: Database) {
  const { user_version } = db.query("PRAGMA user_version").get() as { user_version: number };
  if (user_version >= 5) return;
  db.transaction(() => {
    const have = new Set((db.query("PRAGMA table_info(links)").all() as { name: string }[]).map((c) => c.name));
    for (const [name, type] of [["description", "TEXT"], ["site_name", "TEXT"], ["thumb_w", "INTEGER"],
                                ["thumb_h", "INTEGER"], ["preview_v", "INTEGER NOT NULL DEFAULT 0"],
                                ["thumb_v", "INTEGER NOT NULL DEFAULT 0"]]) {
      if (!have.has(name!)) db.run(`ALTER TABLE links ADD COLUMN ${name} ${type}`);
    }
    db.run("PRAGMA user_version = 5");
  })();
}

/**
 * v6: Instagram's login page used to pass for the post (fixed in #35), so a fetch could save its logo
 * as the thumbnail and "Instagram" as the @handle, over a reel's real ones during #31's backfill.
 * Drop both and let the backfill fetch those links again.
 */
function migrateToV6(db: Database, dataDir: string) {
  const { user_version } = db.query("PRAGMA user_version").get() as { user_version: number };
  if (user_version >= 6) return;
  const damaged = db.transaction(() => {
    const rows = db.query(`UPDATE links SET author = NULL, thumb_type = NULL, thumb_w = NULL, thumb_h = NULL,
        thumb_v = thumb_v + 1, preview_v = 0 WHERE platform = 'instagram' AND author = 'Instagram' RETURNING id`)
      .all() as { id: number }[];
    db.run("PRAGMA user_version = 6");
    return rows;
  })();
  for (const { id } of damaged) rmSync(join(dataDir, "thumbs", String(id)), { force: true });
}

/**
 * v7: in-app invites (#5), the only way in. Everyone who had already signed up becomes a member
 * (only those still on the old ALLOWED_EMAILS list, if it was set); after that a member is someone an
 * invite let in. Revoking an invite deletes it.
 */
function migrateToV7(db: Database, allowed: string[]) {
  const { user_version } = db.query("PRAGMA user_version").get() as { user_version: number };
  if (user_version >= 7) return;
  db.transaction(() => {
    const have = new Set((db.query("PRAGMA table_info(users)").all() as { name: string }[]).map((c) => c.name));
    if (!have.has("member")) db.run("ALTER TABLE users ADD COLUMN member INTEGER NOT NULL DEFAULT 0");
    const users = db.query("SELECT id, email FROM users WHERE id NOT LIKE ? AND id <> ?")
      .all(`${LEGACY}%`, DELETED_USER) as { id: string; email: string | null }[];
    for (const { id, email } of users) {
      if (onList(allowed, email)) db.run("UPDATE users SET member = 1 WHERE id = ?", [id]);
    }
    db.run(`CREATE TABLE IF NOT EXISTS invites (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      token_hash TEXT NOT NULL UNIQUE,   -- SHA-256 of the token in the link; the token itself isn't kept
      email TEXT COLLATE NOCASE,         -- optional: lets that (verified) email in without the link
      invited_by TEXT REFERENCES users(id) ON DELETE CASCADE,  -- NULL: made with links-server invite
      created_at REAL NOT NULL,
      expires_at REAL NOT NULL,
      used_by TEXT REFERENCES users(id) ON DELETE SET NULL,
      used_at REAL
    )`);
    db.run("CREATE INDEX IF NOT EXISTS invites_email ON invites (email) WHERE email IS NOT NULL AND used_at IS NULL");
    db.run("PRAGMA user_version = 7");
  })();
}

/**
 * v8: group chats (#12). Each link belongs to one group and only its members see it, so the same
 * URL can be in two chats, each with its own note, receipts and reactions. Everyone already here,
 * and every link, goes into one default chat, so nothing looks different until someone makes another.
 */
function migrateToV8(db: Database) {
  const { user_version } = db.query("PRAGMA user_version").get() as { user_version: number };
  if (user_version >= 8) return;
  db.exec("PRAGMA foreign_keys = OFF");
  try {
    db.transaction(() => {
      db.exec(`CREATE TABLE IF NOT EXISTS groups (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL DEFAULT '',
          created_by TEXT REFERENCES users(id) ON DELETE SET NULL,
          created_at REAL NOT NULL,
          is_default INTEGER NOT NULL DEFAULT 0
        );
        CREATE UNIQUE INDEX IF NOT EXISTS groups_default ON groups (is_default) WHERE is_default = 1;
        CREATE TABLE IF NOT EXISTS group_members (
          group_id INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
          user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          joined_at REAL NOT NULL,
          PRIMARY KEY (group_id, user_id)
        );
        CREATE INDEX IF NOT EXISTS group_members_user ON group_members (user_id);`);
      const found = db.query("SELECT id FROM groups WHERE is_default = 1").get() as { id: number } | null;
      const everyone = found?.id ??
        Number(db.run("INSERT INTO groups (name, created_by, created_at, is_default) VALUES ('', NULL, ?, 1)", [now()]).lastInsertRowid);
      // Legacy people too, so whoever claims one keeps it (claimLegacy moves memberships).
      db.run("INSERT OR IGNORE INTO group_members (group_id, user_id, joined_at) SELECT ?, id, created_at FROM users", [everyone]);
      const have = (db.query("PRAGMA table_info(links)").all() as { name: string }[]).map((c) => c.name);
      if (have.includes("group_id")) {
        db.run("PRAGMA user_version = 8");
        return;
      }
      const seq = db.query("SELECT seq FROM sqlite_sequence WHERE name = 'links'").get() as { seq: number } | null;
      const cols = "id, url, platform, title, author, thumb_type, meta, note, added_by, added_at, " +
                   "description, site_name, thumb_w, thumb_h, preview_v, thumb_v";
      db.exec(`CREATE TABLE links_v8 (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          group_id INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
          url TEXT NOT NULL,
          platform TEXT NOT NULL,
          title TEXT,
          author TEXT,
          thumb_type TEXT,
          meta TEXT NOT NULL DEFAULT 'pending',
          note TEXT NOT NULL DEFAULT '',
          added_by TEXT NOT NULL,      -- users.id
          added_at REAL NOT NULL,
          description TEXT,
          site_name TEXT,
          thumb_w INTEGER,
          thumb_h INTEGER,
          preview_v INTEGER NOT NULL DEFAULT 0,
          thumb_v INTEGER NOT NULL DEFAULT 0,
          UNIQUE (group_id, url)
        )`);
      db.run(`INSERT INTO links_v8 (group_id, ${cols}) SELECT ?, ${cols} FROM links`, [everyone]);
      db.exec("DROP TABLE links");
      db.exec("ALTER TABLE links_v8 RENAME TO links");
      db.exec("CREATE INDEX links_group ON links (group_id, added_at)");
      // Ids are never reused (see linksTable), including ones deleted before the rebuild.
      if (seq) {
        const moved = db.run("UPDATE sqlite_sequence SET seq = max(seq, ?) WHERE name = 'links'", [seq.seq]);
        if (!moved.changes) db.run("INSERT INTO sqlite_sequence (name, seq) VALUES ('links', ?)", [seq.seq]);
      }
      const broken = db.query("PRAGMA foreign_key_check").all();
      if (broken.length) throw new Error(`foreign key check failed: ${JSON.stringify(broken)}`);
      db.run("PRAGMA user_version = 8");
    })();
  } finally {
    db.exec("PRAGMA foreign_keys = ON");
  }
}

/**
 * v9 (#75): people see only who they share a chat with. An invite can name the inviter's chat the new
 * member joins, and everyone who came in on a friend's invite moves out of the default chat into a
 * new chat with just that friend. The links they sent stay where they are; people let in before
 * invites, or by an admin's invite, stay in the default chat.
 */
function migrateToV9(db: Database) {
  const { user_version } = db.query("PRAGMA user_version").get() as { user_version: number };
  if (user_version >= 9) return;
  db.transaction(() => {
    const have = (db.query("PRAGMA table_info(invites)").all() as { name: string }[]).map((c) => c.name);
    if (!have.includes("group_id")) {
      db.run("ALTER TABLE invites ADD COLUMN group_id INTEGER REFERENCES groups(id) ON DELETE SET NULL");
    }
    const everyone = defaultGroup(db);
    const invited = db.query(`SELECT i.used_by AS user, i.invited_by AS inviter, i.used_at AS at FROM invites i
        JOIN users u ON u.id = i.used_by AND u.member = 1
        JOIN users f ON f.id = i.invited_by AND f.member = 1
        WHERE i.used_by <> i.invited_by
        ORDER BY i.used_at, i.id`).all() as { user: string; inviter: string; at: number }[];
    for (const { user } of invited) {
      db.run("DELETE FROM group_members WHERE group_id = ? AND user_id = ?", [everyone, user]);
    }
    for (const { user, inviter, at } of invited) {
      const id = Number(db.run("INSERT INTO groups (name, created_by, created_at) VALUES ('', ?, ?)", [inviter, at]).lastInsertRowid);
      db.run("INSERT OR IGNORE INTO group_members (group_id, user_id, joined_at) VALUES (?, ?, ?), (?, ?, ?)",
        [id, inviter, at, id, user, at]);
    }
    db.run("PRAGMA user_version = 9");
  })();
}

/**
 * v10: a legacy person names the one account an admin let claim them. By account, not email, since
 * an email can move to someone else; deleting that account withdraws it.
 */
function migrateToV10(db: Database) {
  const { user_version } = db.query("PRAGMA user_version").get() as { user_version: number };
  if (user_version >= 10) return;
  db.transaction(() => {
    const have = (db.query("PRAGMA table_info(users)").all() as { name: string }[]).map((c) => c.name);
    if (!have.includes("claimable_by")) {
      db.run("ALTER TABLE users ADD COLUMN claimable_by TEXT REFERENCES users(id) ON DELETE SET NULL");
    }
    db.run("PRAGMA user_version = 10");
  })();
}

/** v11: each person's notification settings for activity on the links they sent, both on to start. */
function migrateToV11(db: Database) {
  const { user_version } = db.query("PRAGMA user_version").get() as { user_version: number };
  if (user_version >= 11) return;
  db.transaction(() => {
    const have = (db.query("PRAGMA table_info(users)").all() as { name: string }[]).map((c) => c.name);
    if (!have.includes("push_watched")) db.run("ALTER TABLE users ADD COLUMN push_watched INTEGER NOT NULL DEFAULT 1");
    if (!have.includes("push_reactions")) db.run("ALTER TABLE users ADD COLUMN push_reactions INTEGER NOT NULL DEFAULT 1");
    db.run("PRAGMA user_version = 11");
  })();
}

/**
 * v12: v8 put every user in the default chat, including accounts v7 left out (not members), so
 * they showed in it as people links went to. Only members and legacy people belong in chats.
 */
function migrateToV12(db: Database) {
  const { user_version } = db.query("PRAGMA user_version").get() as { user_version: number };
  if (user_version >= 12) return;
  db.transaction(() => {
    db.run(`DELETE FROM group_members WHERE user_id IN (SELECT id FROM users WHERE member = 0 AND id NOT LIKE ? || '%')`, [LEGACY]);
    db.run("PRAGMA user_version = 12");
  })();
}

/**
 * v13: whether each person's email is verified, so an invite bound to an email can be used by someone
 * already in (Accounts.joinWithInvite). Before this, only those an email-bound invite let in had shown it.
 */
function migrateToV13(db: Database) {
  const { user_version } = db.query("PRAGMA user_version").get() as { user_version: number };
  if (user_version >= 13) return;
  db.transaction(() => {
    const have = (db.query("PRAGMA table_info(users)").all() as { name: string }[]).map((c) => c.name);
    if (!have.includes("email_verified")) db.run("ALTER TABLE users ADD COLUMN email_verified INTEGER NOT NULL DEFAULT 0");
    db.run(`UPDATE users SET email_verified = 1 WHERE id IN (SELECT i.used_by FROM invites i JOIN users u ON u.id = i.used_by
              WHERE i.email IS NOT NULL AND i.email = u.email COLLATE NOCASE)`);
    db.run("PRAGMA user_version = 13");
  })();
}

/** v14: flat comment threads, removed with their link or author. */
function migrateToV14(db: Database) {
  const { user_version } = db.query("PRAGMA user_version").get() as { user_version: number };
  if (user_version >= 14) return;
  db.transaction(() => {
    db.exec(`CREATE TABLE IF NOT EXISTS comments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      link_id INTEGER NOT NULL REFERENCES links(id) ON DELETE CASCADE,
      person TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      body TEXT NOT NULL,
      created_at REAL NOT NULL,
      edited_at REAL
    );
    CREATE INDEX IF NOT EXISTS comments_link ON comments (link_id, created_at, id);`);
    db.run("PRAGMA user_version = 14");
  })();
}

function migrateToV15(db: Database) {
  const { user_version } = db.query("PRAGMA user_version").get() as { user_version: number };
  if (user_version >= 15) return;
  db.transaction(() => {
    db.exec(`ALTER TABLE group_members ADD COLUMN muted INTEGER NOT NULL DEFAULT 0;
      ALTER TABLE group_members ADD COLUMN muted_until REAL;`);
    db.run("PRAGMA user_version = 15");
  })();
}

/** The legacy chat everyone was in before groups. */
export function defaultGroup(db: Database): number {
  return (db.query("SELECT id FROM groups WHERE is_default = 1").get() as { id: number }).id;
}

export function directChat(db: Database, a: string, b: string): number | null {
  return (db.query(`SELECT g.id FROM group_members a
    JOIN group_members b ON b.group_id = a.group_id AND b.user_id = ?2
    JOIN groups g ON g.id = a.group_id AND g.is_direct = 1
    WHERE a.user_id = ?1 LIMIT 1`).get(a, b) as { id: number } | null)?.id ?? null;
}

/** Call in a write transaction so two joins can't create a second chat for the same pair. */
export function ensureDirectChat(db: Database, a: string, b: string, at = now()): number {
  const existing = directChat(db, a, b);
  if (existing !== null) return existing;
  const { id } = db.query("INSERT INTO groups (created_by, created_at) VALUES (?, ?) RETURNING id")
    .get(a, at) as { id: number };
  db.run("INSERT INTO group_members (group_id, user_id, joined_at) VALUES (?, ?, ?), (?, ?, ?)", [id, a, at, id, b, at]);
  db.run("UPDATE groups SET is_direct = 1 WHERE id = ?", [id]);
  return id;
}

/** A new relationship through group membership also gets a private chat. */
export function ensureDirectChatsFor(db: Database, user: string, group?: number) {
  const peers = db.query(`SELECT DISTINCT b.user_id FROM group_members a JOIN groups g ON g.id = a.group_id
    JOIN group_members b ON b.group_id = a.group_id AND b.user_id <> a.user_id
    JOIN users u ON u.id = b.user_id AND u.member = 1 AND u.id NOT LIKE ?3
    WHERE a.user_id = ?1 AND g.is_direct = 0 AND (?2 IS NULL OR a.group_id = ?2)
    ORDER BY b.user_id`).all(user, group ?? null, `${LEGACY}%`) as { user_id: string }[];
  const at = now();
  for (const peer of peers) ensureDirectChat(db, user, peer.user_id, at);
}

export function sharesGroupWithDirectPeer(db: Database, direct: number, user: string): boolean {
  return !!db.query(`SELECT 1 FROM group_members peer
    JOIN group_members a ON a.user_id = peer.user_id
    JOIN group_members b ON b.group_id = a.group_id AND b.user_id = ?2
    JOIN groups g ON g.id = a.group_id AND g.is_direct = 0
    WHERE peer.group_id = ?1 AND peer.user_id <> ?2 LIMIT 1`).get(direct, user);
}

/**
 * Delete chats nobody is in anymore (but never the default one), with their links. Returns those
 * links' ids, whose thumbnails the caller removes once the transaction commits.
 */
export function deleteEmptyGroups(db: Database): number[] {
  const empty = "SELECT id FROM groups WHERE is_default = 0 AND NOT EXISTS (SELECT 1 FROM group_members WHERE group_id = groups.id)";
  const ids = (db.query(`SELECT id FROM links WHERE group_id IN (${empty})`).all() as { id: number }[]).map((r) => r.id);
  db.run(`DELETE FROM groups WHERE id IN (${empty})`); // links, then their seen marks and reactions, cascade
  return ids;
}

/**
 * Re-spell stored URLs with today's normalize(). A row whose new spelling another row already has
 * keeps its old one, so both stay, each with its own note, reactions and receipts.
 */
function respellLinks(db: Database) {
  for (const { id, url } of db.query("SELECT id, url FROM links ORDER BY id").all() as { id: number; url: string }[]) {
    let respelled: string;
    try {
      respelled = normalize(new URL(url)).url;
    } catch {
      continue; // leave anything unparseable as it was
    }
    if (respelled !== url && !db.query("SELECT 1 FROM links WHERE url = ?").get(respelled)) {
      db.run("UPDATE links SET url = ? WHERE id = ?", [respelled, id]);
    }
  }
}

export const now = () => Date.now() / 1000;

/** Delete a link for everyone, with its thumbnail (seen marks and reactions cascade). */
export function deleteLink(db: Database, dataDir: string, id: number) {
  db.run("DELETE FROM links WHERE id = ?", [id]);
  rmSync(join(dataDir, "thumbs", String(id)), { force: true });
}

/** An email on an ALLOWED_EMAILS-style list (addresses and @domains). An empty list lets everyone in. */
function onList(list: string[], email: string | null): boolean {
  if (!list.length) return true;
  const e = (email ?? "").toLowerCase();
  return list.some((a) => e === a || (a.startsWith("@") && e.endsWith(a)));
}
