import type { Database } from "bun:sqlite";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { deleteLink, now } from "./db.ts";
import { BadRequest } from "./links.ts";

/**
 * Words a note or a display name may not contain (App Store guideline 1.2: filter objectionable
 * material). Deliberately short: slurs, not swearing. Whole words only, so "Scunthorpe" is fine.
 * The owner adds their own, one per line, in DATA_DIR/blocked-words.txt (read at start-up).
 */
export const DEFAULT_BLOCKED_WORDS = [
  "nigger", "nigga", "faggot", "fag", "kike", "spic", "chink", "gook", "wetback", "raghead",
  "tranny", "retard", "coon", "paki", "dyke",
];

export const WORDS_FILE = "blocked-words.txt";

const fold = (s: string) => s.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase();

export function loadBlockedWords(dataDir: string): Set<string> {
  const words = new Set(DEFAULT_BLOCKED_WORDS);
  const file = join(dataDir, WORDS_FILE);
  if (existsSync(file)) {
    for (const line of readFileSync(file, "utf8").split("\n")) {
      const word = fold(line.replace(/#.*/, "").trim());
      if (word) words.add(word);
    }
  }
  return words;
}

/** The first listed word in `text`, matched as a whole word (or its -s / -es plural), else null. */
export function findBlockedWord(text: string, words: Set<string>): string | null {
  for (const token of fold(text).split(/[^\p{L}\p{N}]+/u)) {
    if (!token) continue;
    // "dykes" -> "dyke", "fags" -> "fag", "bitches" -> "bitch". Only a sibilant takes -es, so
    // "spices" isn't "spic" + es.
    for (const form of [token, token.replace(/s$/, ""), token.replace(/(s|x|z|ch|sh)es$/, "$1")]) {
      if (words.has(form)) return form;
    }
  }
  return null;
}

/** Throws a 400 the app shows as is when `text` has a listed word. */
export function screener(dataDir: string) {
  const words = loadBlockedWords(dataDir);
  return (text: string, what: "note" | "name") => {
    if (!findBlockedWord(text, words)) return;
    throw new BadRequest(what === "name"
      ? "That name has a word Links doesn't allow. Choose another one."
      : "That note has a word Links doesn't allow. Change it and try again.");
  };
}

export const REPORT_REASONS = ["spam", "offensive", "harassment", "other"] as const;

export interface ReportRow {
  id: number;
  reporter: string;
  link_id: number | null;
  comment_id: number | null;
  user_id: string | null;
  reason: string;
  details: string;
  snapshot: string;
  created_at: number;
  resolved_at: number | null;
  resolution: string | null;
}

/** Open reports, oldest first, with who made them, for `links-server reports`. */
export function openReports(db: Database) {
  return db.query(
    `SELECT r.*, u.name AS reporter_name, u.email AS reporter_email,
            (r.link_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM links WHERE id = r.link_id)) AS gone
     FROM reports r LEFT JOIN users u ON u.id = r.reporter
     WHERE r.resolved_at IS NULL ORDER BY r.created_at, r.id`,
  ).all() as (ReportRow & { reporter_name: string | null; reporter_email: string | null; gone: number })[];
}

export function formatReport(r: ReturnType<typeof openReports>[number]): string {
  const when = new Date(r.created_at * 1000).toISOString().replace("T", " ").slice(0, 16);
  const target = r.link_id !== null ? `link ${r.link_id}${r.gone ? " (deleted since)" : ""}`
    : r.user_id !== null ? `person ${r.user_id}` : `comment ${r.comment_id}`;
  const by = `${r.reporter_name ?? r.reporter}${r.reporter_email ? ` <${r.reporter_email}>` : ""}`;
  const lines = [`#${r.id}  ${when} UTC  ${r.reason}  ${target}  reported by ${by}`];
  const snapshot = JSON.parse(r.snapshot) as Record<string, unknown>;
  for (const [key, value] of Object.entries(snapshot)) {
    if (value !== null && value !== "") lines.push(`    ${key}: ${JSON.stringify(value)}`);
  }
  if (r.details) lines.push(`    details: ${JSON.stringify(r.details)}`);
  return lines.join("\n");
}

/**
 * Mark a report handled. With `remove`, the reported link goes for everyone, and every other open
 * report on it is resolved with it.
 */
export function resolveReport(
  db: Database, dataDir: string, id: number, remove: boolean, beforeRemove?: (linkId: number) => void,
): ReportRow {
  return db.transaction(() => {
    const report = db.query("SELECT * FROM reports WHERE id = ?").get(id) as ReportRow | null;
    if (!report) throw new BadRequest(`no report #${id}`);
    if (report.resolved_at !== null) throw new BadRequest(`report #${id} was already resolved (${report.resolution})`);
    if (remove) {
      if (report.link_id === null) {
        throw new BadRequest("--remove only removes links; to remove a person, use links-server delete-user <email>");
      }
      beforeRemove?.(report.link_id);
      deleteLink(db, dataDir, report.link_id);
      db.run("UPDATE reports SET resolved_at = ?, resolution = 'removed' WHERE link_id = ? AND resolved_at IS NULL",
        [now(), report.link_id]);
    } else {
      db.run("UPDATE reports SET resolved_at = ?, resolution = 'kept' WHERE id = ?", [now(), id]);
    }
    return db.query("SELECT * FROM reports WHERE id = ?").get(id) as ReportRow;
  })();
}
