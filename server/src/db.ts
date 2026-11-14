import { Database } from "bun:sqlite";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { normalize } from "./links.ts";

export const LEGACY = "legacy:"; // people from the pre-sign-in version, until someone claims them
/**
 * Who sent a link whose sender deleted their account. There's no users row for it, so no account,
 * however it signs up again, can ever own those links; the app shows them as from "Deleted user".
 */
export const DELETED_USER = "deleted";

export interface LinkRow {
  id: number;
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
}

export interface UserRow {
  id: string;
  email: string | null;
  name: string;
  avatar: string | null;
  created_at: number;
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

export function openDatabase(dataDir: string): Database {
  mkdirSync(join(dataDir, "thumbs"), { recursive: true });
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
  `);
  migrateFromNames(db);
  migrateToV2(db);
  migrateToV3(db);
  migrateToV4(db);
  migrateToV5(db);
  return db;
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
