import { Database } from "bun:sqlite";
import { afterEach, beforeEach, describe, expect, setSystemTime, test } from "bun:test";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { openDatabase } from "../../src/db.ts";
import { tempDir } from "./helpers.ts";

const ID = "7506136711311772958";
const ID2 = "7400000000000000001";
const POST = `https://www.tiktok.com/@/video/${ID}`;

// Schemas as earlier versions created them: the Python server's links table had no AUTOINCREMENT.
const LINKS_V0 = `CREATE TABLE links (id INTEGER PRIMARY KEY, url TEXT NOT NULL UNIQUE, platform TEXT NOT NULL, title TEXT,
  author TEXT, thumb_type TEXT, meta TEXT NOT NULL DEFAULT 'pending', note TEXT NOT NULL DEFAULT '', added_by TEXT NOT NULL,
  added_at REAL NOT NULL);`;
const LINKS_V2 = LINKS_V0.replace("id INTEGER PRIMARY KEY", "id INTEGER PRIMARY KEY AUTOINCREMENT");
const SEEN_REACTIONS = `
  CREATE TABLE seen (link_id INTEGER NOT NULL REFERENCES links(id) ON DELETE CASCADE, person TEXT NOT NULL,
    seen_at REAL NOT NULL, PRIMARY KEY (link_id, person));
  CREATE TABLE reactions (link_id INTEGER NOT NULL REFERENCES links(id) ON DELETE CASCADE, person TEXT NOT NULL,
    emoji TEXT NOT NULL, PRIMARY KEY (link_id, person));`;
const USERS_SESSIONS = `
  CREATE TABLE users (id TEXT PRIMARY KEY, email TEXT, name TEXT NOT NULL, avatar TEXT, created_at REAL NOT NULL);
  CREATE TABLE sessions (token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at REAL NOT NULL, last_used REAL NOT NULL);`;

let tmp: ReturnType<typeof tempDir>;
beforeEach(() => {
  tmp = tempDir();
});
afterEach(() => {
  setSystemTime();
  tmp.cleanup();
});

function seed(sql: string) {
  const db = new Database(join(tmp.dir, "links.db"), { create: true });
  db.exec(`PRAGMA foreign_keys = OFF; ${sql}`);
  db.close();
}

const pragma = (db: Database, name: string) => Object.values(db.query(`PRAGMA ${name}`).get() as object)[0];
const linksSql = (db: Database) =>
  (db.query("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'links'").get() as { sql: string }).sql;
const urls = (db: Database) => (db.query("SELECT id, url FROM links ORDER BY id").all() as { id: number; url: string }[])
  .map((r) => [r.id, r.url]);
const addLink = (db: Database, url: string) =>
  Number(db.run("INSERT INTO links (url, platform, added_by, added_at) VALUES (?, 'web', 'u', 1)", [url]).lastInsertRowid);

describe("openDatabase", () => {
  test("creates a v5 database (and its folders) in an empty directory", () => {
    const dir = join(tmp.dir, "nested", "data");
    const db = openDatabase(dir);
    expect(existsSync(join(dir, "thumbs"))).toBe(true);
    expect(existsSync(join(dir, "links.db"))).toBe(true);
    expect(pragma(db, "user_version")).toBe(5);
    expect(pragma(db, "foreign_keys")).toBe(1);
    expect(pragma(db, "journal_mode")).toBe("wal");
    expect(db.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").all().map((r: any) => r.name))
      .toEqual(["links", "reactions", "seen", "sessions", "sqlite_sequence", "users"]);
    expect(linksSql(db)).toContain("AUTOINCREMENT");
    db.close();
  });

  test("a deleted link's id is never handed out again", () => {
    const db = openDatabase(tmp.dir);
    expect([addLink(db, "https://a.com/1"), addLink(db, "https://a.com/2")]).toEqual([1, 2]);
    db.run("DELETE FROM links WHERE id = 2");
    expect(addLink(db, "https://a.com/3")).toBe(3);
    db.run("DELETE FROM links");
    expect(addLink(db, "https://a.com/4")).toBe(4);
    db.close();
  });

  test("foreign keys are on: deleting a link or user cascades", () => {
    const db = openDatabase(tmp.dir);
    db.run("INSERT INTO users (id, name, created_at) VALUES ('u', 'U', 1)");
    const id = addLink(db, "https://a.com/1");
    db.run("INSERT INTO seen VALUES (?, 'u', 1)", [id]);
    db.run("INSERT INTO reactions VALUES (?, 'u', '🔥')", [id]);
    db.run("INSERT INTO sessions VALUES ('h', 'u', 1, 1)");
    db.run("DELETE FROM links WHERE id = ?", [id]);
    expect(db.query("SELECT COUNT(*) AS n FROM seen").get()).toEqual({ n: 0 });
    expect(db.query("SELECT COUNT(*) AS n FROM reactions").get()).toEqual({ n: 0 });
    db.run("DELETE FROM users WHERE id = 'u'");
    expect(db.query("SELECT COUNT(*) AS n FROM sessions").get()).toEqual({ n: 0 });
    db.close();
  });

  test("reopening a v5 database changes nothing (re-spelling only runs on upgrade)", () => {
    let db = openDatabase(tmp.dir);
    addLink(db, "https://youtube.com/watch?v=1&si=x"); // not today's spelling, on purpose
    db.close();
    db = openDatabase(tmp.dir);
    expect(urls(db)).toEqual([[1, "https://youtube.com/watch?v=1&si=x"]]);
    expect(pragma(db, "user_version")).toBe(5);
    db.close();
  });
});

describe("migrations", () => {
  test("v0: people identified by typed names become legacy users", () => {
    setSystemTime(new Date(1_700_000_000_000));
    seed(`
      CREATE TABLE people (name TEXT PRIMARY KEY COLLATE NOCASE, created_at REAL NOT NULL);
      ${LINKS_V0} ${SEEN_REACTIONS}
      INSERT INTO people VALUES ('Sam', 1), ('Alex', 2);
      INSERT INTO links (id, url, platform, title, meta, added_by, added_at) VALUES
        (1, 'https://www.youtube.com/watch?v=old', 'youtube', 'Old', 'done', 'Sam', 10),
        (2, 'https://de.wikipedia.org/wiki/München', 'web', 'München', 'done', 'Jo', 9),
        (3, 'https://www.tiktok.com/@old_handle/video/${ID}', 'tiktok', 'A TikTok', 'done', 'Alex', 8);
      INSERT INTO seen VALUES (1, 'Alex', 11), (3, 'Jo', 12);
      INSERT INTO reactions VALUES (1, 'Alex', '🔥');
    `);
    const db = openDatabase(tmp.dir);
    expect(db.query("SELECT 1 FROM sqlite_master WHERE name = 'people'").get()).toBeNull();
    // People keep their join date; names only seen on links ("Jo") join now.
    expect(db.query("SELECT * FROM users ORDER BY id").all()).toEqual([
      { id: "legacy:Alex", email: null, name: "Alex", avatar: null, created_at: 2 },
      { id: "legacy:Jo", email: null, name: "Jo", avatar: null, created_at: 1_700_000_000 },
      { id: "legacy:Sam", email: null, name: "Sam", avatar: null, created_at: 1 },
    ]);
    expect(db.query("SELECT id, added_by FROM links ORDER BY id").all())
      .toEqual([{ id: 1, added_by: "legacy:Sam" }, { id: 2, added_by: "legacy:Jo" }, { id: 3, added_by: "legacy:Alex" }]);
    expect(db.query("SELECT * FROM seen ORDER BY link_id").all())
      .toEqual([{ link_id: 1, person: "legacy:Alex", seen_at: 11 }, { link_id: 3, person: "legacy:Jo", seen_at: 12 }]);
    expect(db.query("SELECT * FROM reactions").all()).toEqual([{ link_id: 1, person: "legacy:Alex", emoji: "🔥" }]);
    // ...and the later migrations ran too.
    expect(linksSql(db)).toContain("AUTOINCREMENT");
    expect(urls(db)).toEqual([
      [1, "https://www.youtube.com/watch?v=old"],
      [2, "https://de.wikipedia.org/wiki/M%C3%BCnchen"],
      [3, POST],
    ]);
    expect(pragma(db, "user_version")).toBe(5);
    db.close();
  });

  test("v1: links is rebuilt with AUTOINCREMENT; rows, receipts, reactions and foreign keys survive", () => {
    seed(`
      ${LINKS_V0} ${SEEN_REACTIONS} ${USERS_SESSIONS}
      INSERT INTO users VALUES ('user_A', 'a@x.com', 'A', NULL, 1), ('legacy:Sam', NULL, 'Sam', NULL, 1);
      INSERT INTO sessions VALUES ('hash', 'user_A', 1, 1);
      INSERT INTO links VALUES
        (1, 'https://example.com/1', 'web', 'One', 'Ann', 'image/png', 'done', 'a note', 'user_A', 10),
        (2, 'https://example.com/2', 'web', NULL, NULL, NULL, 'pending', '', 'legacy:Sam', 11),
        (5, 'https://example.com/5', 'web', NULL, NULL, NULL, 'failed', '', 'user_A', 12);
      INSERT INTO seen VALUES (1, 'user_A', 3), (5, 'legacy:Sam', 4);
      INSERT INTO reactions VALUES (5, 'user_A', '😂');
      PRAGMA user_version = 1;
    `);
    const db = openDatabase(tmp.dir);
    expect(linksSql(db)).toContain("AUTOINCREMENT");
    expect(db.query("SELECT 1 FROM sqlite_master WHERE name = 'links_v2'").get()).toBeNull();
    expect(db.query("SELECT id, url, platform, title, author, thumb_type, meta, note, added_by, added_at FROM links ORDER BY id").all()).toEqual([
      { id: 1, url: "https://example.com/1", platform: "web", title: "One", author: "Ann", thumb_type: "image/png", meta: "done", note: "a note", added_by: "user_A", added_at: 10 },
      { id: 2, url: "https://example.com/2", platform: "web", title: null, author: null, thumb_type: null, meta: "pending", note: "", added_by: "legacy:Sam", added_at: 11 },
      { id: 5, url: "https://example.com/5", platform: "web", title: null, author: null, thumb_type: null, meta: "failed", note: "", added_by: "user_A", added_at: 12 },
    ]);
    expect(db.query("SELECT * FROM seen ORDER BY link_id").all())
      .toEqual([{ link_id: 1, person: "user_A", seen_at: 3 }, { link_id: 5, person: "legacy:Sam", seen_at: 4 }]);
    expect(db.query("SELECT * FROM reactions").all()).toEqual([{ link_id: 5, person: "user_A", emoji: "😂" }]);
    expect(db.query("SELECT user_id FROM sessions").all()).toEqual([{ user_id: "user_A" }]);
    expect(pragma(db, "foreign_keys")).toBe(1);
    expect(db.query("PRAGMA foreign_key_check").all()).toEqual([]);
    expect(pragma(db, "user_version")).toBe(5);

    // The rebuilt table is still the one seen/reactions cascade from.
    db.run("DELETE FROM links WHERE id = 5");
    expect(db.query("SELECT link_id FROM seen").all()).toEqual([{ link_id: 1 }]);
    expect(db.query("SELECT COUNT(*) AS n FROM reactions").get()).toEqual({ n: 0 });
    // The old table would have handed out 5 again (or 3); AUTOINCREMENT continues after the highest.
    expect(addLink(db, "https://example.com/new")).toBe(6);
    db.close();
  });

  test("v1: a rebuild that would break foreign keys is rolled back", () => {
    seed(`
      ${LINKS_V0} ${SEEN_REACTIONS} ${USERS_SESSIONS}
      INSERT INTO links VALUES (1, 'https://example.com/1', 'web', NULL, NULL, NULL, 'done', '', 'u', 1);
      INSERT INTO seen VALUES (99, 'u', 1);
      PRAGMA user_version = 1;
    `);
    expect(() => openDatabase(tmp.dir)).toThrow("foreign key check failed");
    const db = new Database(join(tmp.dir, "links.db"));
    expect(linksSql(db)).not.toContain("AUTOINCREMENT");
    expect(db.query("SELECT 1 FROM sqlite_master WHERE name = 'links_v2'").get()).toBeNull();
    expect(urls(db)).toEqual([[1, "https://example.com/1"]]);
    expect(pragma(db, "user_version")).toBe(1);
    db.close();
  });

  test("v2: stored links are re-spelled without rebuilding the table", () => {
    seed(`
      ${LINKS_V2} ${SEEN_REACTIONS} ${USERS_SESSIONS}
      INSERT INTO links (id, url, platform, added_by, added_at) VALUES
        (1, 'https://www.tiktok.com/@zed/video/${ID}', 'tiktok', 'u', 1),
        (2, 'https://www.tiktok.com/@abe/video/${ID}', 'tiktok', 'u', 2),
        (3, 'https://www.tiktok.com/@old/video/${ID2}', 'tiktok', 'u', 3),
        (4, 'https://www.tiktok.com/@/video/${ID2}', 'tiktok', 'u', 4),
        (5, 'not a url', 'web', 'u', 5),
        (6, 'ftp://example.com/x', 'web', 'u', 6),
        (7, 'https://youtube.com/watch?v=1&si=x', 'youtube', 'u', 7);
      UPDATE sqlite_sequence SET seq = 20 WHERE name = 'links';
      PRAGMA user_version = 2;
    `);
    const db = openDatabase(tmp.dir);
    expect(urls(db)).toEqual([
      [1, POST], // the lowest id gets the new spelling...
      [2, `https://www.tiktok.com/@abe/video/${ID}`], // ...and a later duplicate keeps its own
      [3, `https://www.tiktok.com/@old/video/${ID2}`], // a later row already has the new spelling
      [4, `https://www.tiktok.com/@/video/${ID2}`],
      [5, "not a url"], // unparseable: left alone
      [6, "ftp://example.com/x"],
      [7, "https://www.youtube.com/watch?v=1"],
    ]);
    expect(pragma(db, "user_version")).toBe(5);
    expect(addLink(db, "https://example.com/new")).toBe(21); // sqlite_sequence kept: no rebuild
    db.close();
  });

  test("v3: X links lose their share token; s= and t= elsewhere stay", () => {
    seed(`
      ${LINKS_V2} ${SEEN_REACTIONS} ${USERS_SESSIONS}
      INSERT INTO links (id, url, platform, added_by, added_at) VALUES
        (1, 'https://x.com/a/status/1?t=AAAA', 'x', 'u', 1),
        (2, 'https://x.com/a/status/1?t=BBBB', 'x', 'u', 2),
        (3, 'https://youtu.be/abc?t=10', 'youtube', 'u', 3),
        (4, 'https://blog.example.com/?s=pasta', 'web', 'u', 4);
      PRAGMA user_version = 3;
    `);
    const db = openDatabase(tmp.dir);
    expect(urls(db)).toEqual([
      [1, "https://x.com/a/status/1"],
      [2, "https://x.com/a/status/1?t=BBBB"], // the new spelling is taken, so this one keeps its own
      [3, "https://youtu.be/abc?t=10"],
      [4, "https://blog.example.com/?s=pasta"],
    ]);
    expect(pragma(db, "user_version")).toBe(5);
    db.close();
  });

  test("v4: links gain the rich preview columns, left empty for the backfill", () => {
    seed(`
      ${LINKS_V2} ${SEEN_REACTIONS} ${USERS_SESSIONS}
      INSERT INTO links (id, url, platform, title, thumb_type, meta, added_by, added_at) VALUES
        (1, 'https://example.com/a', 'web', 'A', 'image/png', 'done', 'u', 1),
        (2, 'https://www.instagram.com/reel/abc/', 'instagram', NULL, NULL, 'failed', 'u', 2);
      PRAGMA user_version = 4;
    `);
    const db = openDatabase(tmp.dir);
    expect(db.query("SELECT id, title, meta, description, site_name, thumb_w, thumb_h, preview_v FROM links ORDER BY id").all())
      .toEqual([
        { id: 1, title: "A", meta: "done", description: null, site_name: null, thumb_w: null, thumb_h: null, preview_v: 0 },
        { id: 2, title: null, meta: "failed", description: null, site_name: null, thumb_w: null, thumb_h: null, preview_v: 0 },
      ]);
    expect(pragma(db, "user_version")).toBe(5);
    db.close();
    // Reopening runs nothing again.
    openDatabase(tmp.dir).close();
  });
});
