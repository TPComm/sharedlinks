import { afterEach, describe, expect, spyOn, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { openDatabase } from "../../src/db.ts";
import { fetchMetadata } from "../../src/previews.ts";
import { fakeFetch, tempDir } from "./helpers.ts";

/** The "Links 5xx spike" rule's LogQL line filter, as a JS RegExp (its RE2 pattern is plain enough to share). */
function fiveXxFilter(): RegExp {
  const file = join(import.meta.dir, "../../../deploy/grafana/links-alerts.json");
  const { groups } = JSON.parse(readFileSync(file, "utf8")) as { groups: { rules: { uid: string; data: { model: { expr?: string } }[] }[] }[] };
  const rule = groups.flatMap((g) => g.rules).find((r) => r.uid === "links-5xx-spike")!;
  const expr = rule.data.find((d) => d.model.expr)!.model.expr!;
  const pattern = expr.match(/\|~ "((?:[^"\\]|\\.)*)"/)![1]!;
  return new RegExp(JSON.parse(`"${pattern}"`));
}

describe("Links 5xx spike alert", () => {
  let restore: (() => void) | undefined;
  afterEach(() => restore?.());

  test("counts the server's request lines for 5xx responses, not other statuses", () => {
    const filter = fiveXxFilter();
    // The request log line route() in src/app.ts prints: `${method} ${path} ${status}`.
    for (const line of ["GET /api/state 500", "POST /api/links/12/react 503", "GET /favicon.ico 502"]) expect(line).toMatch(filter);
    for (const line of ["GET /api/state 200", "POST /api/links 400", "GET /x 404", "GET /api/links/500 200"]) expect(line).not.toMatch(filter);
  });

  test("doesn't count a site that answered a preview fetch with a 5xx", async () => {
    const tmp = tempDir();
    const db = openDatabase(tmp.dir);
    const errors: string[] = [];
    const consoleError = spyOn(console, "error").mockImplementation((...args: unknown[]) => { errors.push(args.join(" ")); });
    const fake = fakeFetch(() => new Response("upstream down", { status: 503 }));
    restore = () => { fake.restore(); consoleError.mockRestore(); db.close(); tmp.cleanup(); };
    const url = "https://www.tiktok.com/@a/video/1";
    const id = Number(db.run("INSERT INTO links (group_id, url, platform, meta, added_by, added_at) VALUES (1, ?, 'tiktok', 'pending', 'u', 1)",
      [url]).lastInsertRowid);
    await fetchMetadata(db, tmp.dir, id, url, "tiktok", { allowPrivateNetwork: true });
    const line = errors.find((e) => e.startsWith("preview failed"))!;
    expect(line).toEndWith("HTTP 503");
    expect(line).not.toMatch(fiveXxFilter());
  });
});
