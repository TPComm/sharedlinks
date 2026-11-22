import { expect, test } from "bun:test";
import { startServer } from "../../src/app.ts";
import { configFromEnv } from "../../src/config.ts";
import { PREVIEW_VERSION } from "../../src/previews.ts";
import { stubServer, tempDir } from "./helpers.ts";

test("failed previews wait for increasing backoff, then recover without restarting the worker", async () => {
  const tmp = tempDir();
  let calls = 0;
  let up = false;
  let now = 0;
  const stub = stubServer({ "/preview": () => {
    calls++;
    return new Response(up ? "<title>Recovered</title>" : "", { status: up ? 200 : 503 });
  } });
  const { app, server } = startServer({ ...configFromEnv({}), hostname: "127.0.0.1", port: 0, dataDir: tmp.dir, allowPrivateNetwork: true, previewBackfillMs: 5 },
    { previewNow: () => now });
  const tick = async () => { await Bun.sleep(25); await app.idle(); };
  try {
    await tick(); // The worker must keep running even with no candidates.
    const id = Number(app.db.run("INSERT INTO links (group_id, url, platform, meta, preview_v, added_by, added_at) VALUES (1, ?, 'web', 'failed', ?, 'u', 1)",
      [stub.origin + "/preview", PREVIEW_VERSION]).lastInsertRowid);
    await tick();
    expect(calls).toBe(0);
    now = 59_999;
    await tick();
    expect(calls).toBe(0);
    now = 60_000;
    await tick();
    expect(calls).toBe(1);
    now = 359_999;
    await tick();
    expect(calls).toBe(1);
    up = true;
    now = 360_000;
    await tick();
    expect(calls).toBe(2);
    expect(app.db.query("SELECT meta, title FROM links WHERE id = ?").get(id)).toEqual({ meta: "done", title: "Recovered" });
    now += 43_200_000;
    await tick();
    expect(calls).toBe(2);
    const token = app.accounts.mintSession("retry@example.com", "Retry");
    app.db.run("UPDATE links SET meta = 'failed' WHERE id = ?", [id]);
    up = false;
    await tick();
    const refresh = () => fetch(`http://127.0.0.1:${server.port}/api/links/${id}/refresh`, {
      method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: "{}",
    });
    expect((await refresh()).status).toBe(200);
    await app.idle();
    expect(calls).toBe(3);
    up = true;
    expect((await refresh()).status).toBe(200);
    await app.idle();
    expect(calls).toBe(4);
    expect(app.db.query("SELECT meta FROM links WHERE id = ?").get(id)).toEqual({ meta: "done" });
  } finally {
    server.stop(true);
    app.push.close();
    await app.idle();
    app.db.close();
    stub.stop();
    tmp.cleanup();
  }
});
