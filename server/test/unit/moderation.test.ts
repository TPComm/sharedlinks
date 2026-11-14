import type { Database } from "bun:sqlite";
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { openDatabase } from "../../src/db.ts";
import { BadRequest } from "../../src/links.ts";
import {
  DEFAULT_BLOCKED_WORDS, findBlockedWord, formatReport, loadBlockedWords, openReports, resolveReport, screener,
} from "../../src/moderation.ts";
import { tempDir } from "./helpers.ts";

let tmp: ReturnType<typeof tempDir>;
let db: Database;
beforeEach(() => {
  tmp = tempDir();
  db = openDatabase(tmp.dir);
});
afterEach(() => {
  db.close();
  tmp.cleanup();
});

describe("word list", () => {
  const words = new Set(["zonk", "bad", "dyke", "bitch"]);

  test("whole words, in any case, with accents or a plural", () => {
    for (const text of ["ZONK", "a zonk!", "zonks", "Zönk", "so...bad", "line\nbad", "bäds", "dykes", "bitches"]) {
      expect(findBlockedWord(text, words), text).not.toBeNull();
    }
    for (const text of ["", "zonked", "badge", "abad", "Scunthorpe", "z o n k"]) {
      expect(findBlockedWord(text, words), text).toBeNull();
    }
  });

  test("an -es plural only after s, x, z, ch or sh: spices isn't a slur", () => {
    const builtIn = new Set(DEFAULT_BLOCKED_WORDS);
    for (const text of ["Best spices for curry", "Spices", "bades"]) {
      expect(findBlockedWord(text, new Set([...builtIn, ...words])), text).toBeNull();
    }
    expect(findBlockedWord("spics", builtIn)).toBe("spic");
  });

  test("the built-in list, plus the owner's file with comments and blank lines", () => {
    expect(loadBlockedWords(tmp.dir)).toEqual(new Set(DEFAULT_BLOCKED_WORDS));
    writeFileSync(join(tmp.dir, "blocked-words.txt"), "# mine\nZonk\n\n  Flarp  # trailing comment\n");
    const loaded = loadBlockedWords(tmp.dir);
    expect(loaded.has("zonk") && loaded.has("flarp")).toBe(true);
    expect(loaded.size).toBe(DEFAULT_BLOCKED_WORDS.length + 2);
  });

  test("screener throws a readable 400 for notes and names", () => {
    const screen = screener(tmp.dir);
    expect(() => screen(`you ${DEFAULT_BLOCKED_WORDS[0]}`, "note")).toThrow(/note has a word/);
    expect(() => screen(DEFAULT_BLOCKED_WORDS[0]!, "name")).toThrow(/name has a word/);
    expect(() => screen("hello there", "note")).not.toThrow();
  });
});

describe("reports", () => {
  function seed() {
    mkdirSync(join(tmp.dir, "thumbs"), { recursive: true });
    writeFileSync(join(tmp.dir, "thumbs", "1"), "png");
    db.exec(`
      INSERT INTO users (id, email, name, created_at) VALUES ('user_A', 'a@x.com', 'Ann', 1), ('user_B', 'b@x.com', 'Bo', 2);
      INSERT INTO links (id, url, platform, added_by, added_at) VALUES (1, 'https://a.com/1', 'web', 'user_B', 1),
        (2, 'https://a.com/2', 'web', 'user_B', 1);
      INSERT INTO reports (reporter, link_id, reason, details, snapshot, created_at) VALUES
        ('user_A', 1, 'offensive', 'rude', '{"url":"https://a.com/1","note":"hi","title":null}', 10),
        ('user_A', 2, 'spam', '', '{"url":"https://a.com/2"}', 20);
      INSERT INTO reports (reporter, user_id, reason, snapshot, created_at) VALUES ('user_B', 'user_A', 'harassment', '{"name":"Ann"}', 30);
    `);
  }

  test("openReports lists them oldest first, with the snapshot and who reported it", () => {
    seed();
    const reports = openReports(db);
    expect(reports.map((r) => r.id)).toEqual([1, 2, 3]);
    const text = formatReport(reports[0]!);
    expect(text).toContain("#1  1970-01-01 00:00 UTC  offensive  link 1  reported by Ann <a@x.com>");
    expect(text).toContain('url: "https://a.com/1"');
    expect(text).toContain('details: "rude"');
    expect(text).not.toContain("title");
    db.run("DELETE FROM links WHERE id = 1");
    expect(formatReport(openReports(db)[0]!)).toContain("link 1 (deleted since)");
    expect(formatReport(openReports(db)[2]!)).toContain("person user_A");
  });

  test("resolve keeps the link; --remove deletes it and its thumbnail, resolving the rest on it", () => {
    seed();
    db.run("INSERT INTO reports (reporter, link_id, reason, snapshot, created_at) VALUES ('user_B', 1, 'spam', '{}', 40)");
    expect(resolveReport(db, tmp.dir, 2, false).resolution).toBe("kept");
    expect(db.query("SELECT 1 FROM links WHERE id = 2").get()).not.toBeNull();

    const removing: number[] = [];
    expect(resolveReport(db, tmp.dir, 1, true, (id) => removing.push(id)).resolution).toBe("removed");
    expect(removing).toEqual([1]);
    expect(db.query("SELECT 1 FROM links WHERE id = 1").get()).toBeNull();
    expect(existsSync(join(tmp.dir, "thumbs", "1"))).toBe(false);
    expect(openReports(db).map((r) => r.id)).toEqual([3]);

    expect(() => resolveReport(db, tmp.dir, 1, false)).toThrow(/already resolved/);
    expect(() => resolveReport(db, tmp.dir, 99, false)).toThrow(BadRequest);
    expect(() => resolveReport(db, tmp.dir, 3, true)).toThrow(/delete-user/);
  });

  test("a report needs exactly one target", () => {
    db.exec("INSERT INTO users (id, name, created_at) VALUES ('user_A', 'Ann', 1)");
    expect(() => db.run("INSERT INTO reports (reporter, reason, snapshot, created_at) VALUES ('user_A', 'spam', '{}', 1)")).toThrow();
    expect(() => db.run("INSERT INTO reports (reporter, link_id, user_id, reason, snapshot, created_at) VALUES ('user_A', 1, 'user_A', 'spam', '{}', 1)")).toThrow();
  });
});
