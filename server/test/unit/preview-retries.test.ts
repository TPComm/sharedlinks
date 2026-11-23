import { expect, test } from "bun:test";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { startServer } from "../../src/app.ts";
import { configFromEnv } from "../../src/config.ts";
import { PREVIEW_VERSION } from "../../src/previews.ts";
import { fakeFetch, PNG, stubServer, tempDir } from "./helpers.ts";

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

test.each([false, true])("thrown preview fetches wait for backoff before retrying (refresh: %s)", async (refresh) => {
  const tmp = tempDir();
  let calls = 0;
  let now = 0;
  const stub = stubServer({
    "/preview": () => {
      calls++;
      return new Response(`<meta property="og:image" content="${stub.origin}/image">`);
    },
    "/image": () => new Response(PNG, { headers: { "Content-Type": "image/png" } }),
  });
  const { app, server } = startServer({ ...configFromEnv({}), hostname: "127.0.0.1", port: 0, dataDir: tmp.dir,
    allowPrivateNetwork: true, previewBackfillMs: 5 }, { previewNow: () => now });
  const tick = async () => { await Bun.sleep(25); await app.idle(); };
  try {
    const id = Number(app.db.run("INSERT INTO links (group_id, url, platform, meta, preview_v, added_by, added_at) VALUES (1, ?, 'web', 'failed', ?, 'u', 1)",
      [stub.origin + "/preview", refresh ? 0 : PREVIEW_VERSION]).lastInsertRowid);
    const thumbPath = join(tmp.dir, "thumbs", String(id));
    mkdirSync(thumbPath);
    writeFileSync(join(thumbPath, "blocker"), "");
    if (refresh) {
      const token = app.accounts.mintSession("retry@example.com", "Retry");
      const response = await fetch(`http://127.0.0.1:${server.port}/api/links/${id}/refresh`, {
        method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: "{}",
      });
      expect(response.status).toBe(200);
      await app.idle();
      expect(calls).toBe(1);
      expect(app.db.query("SELECT meta FROM links WHERE id = ?").get(id)).toEqual({ meta: "failed" });
    }
    await tick();
    expect(calls).toBe(refresh ? 1 : 0);
    now = 60_000;
    await tick();
    expect(calls).toBe(refresh ? 2 : 1);
    for (let i = 0; i < 3; i++) await tick();
    expect(calls).toBe(refresh ? 2 : 1);
  } finally {
    server.stop(true);
    app.push.close();
    await app.idle();
    app.db.close();
    stub.stop();
    tmp.cleanup();
  }
});

test.each(["HTML", "thumbnail"])("automatic Reddit retry recovers a missing thumbnail after a transient %s failure", async (failure) => {
  const tmp = tempDir();
  let now = 0;
  let up = false;
  const url = "https://www.reddit.com/r/AskReddit/comments/abc/question/";
  const image = "https://share.redd.it/preview/post/abc";
  const fake = fakeFetch((target) => {
    if (target.includes("/oembed?")) return Response.json({ title: "Question", author_name: "sam" });
    if (target === image) return new Response(up ? PNG : "busy", {
      status: up ? 200 : 503, headers: { "Content-Type": up ? "image/png" : "text/plain" },
    });
    return new Response(`<title>Question</title><meta property="og:image" content="${image}">`, {
      status: failure === "HTML" && !up ? 403 : 200,
    });
  });
  const { app, server } = startServer({ ...configFromEnv({}), hostname: "127.0.0.1", port: 0, dataDir: tmp.dir,
    allowPrivateNetwork: true, previewBackfillMs: 5 }, { previewNow: () => now });
  const tick = async () => { await Bun.sleep(25); await app.idle(); };
  try {
    const id = Number(app.db.run("INSERT INTO links (group_id, url, platform, meta, preview_v, added_by, added_at) VALUES (1, ?, 'reddit', 'failed', ?, 'u', 1)",
      [url, PREVIEW_VERSION]).lastInsertRowid);
    const row = () => app.db.query("SELECT meta, title, thumb_type, thumb_v FROM links WHERE id = ?").get(id);
    await tick();
    expect(fake.calls).toHaveLength(0);
    now = 60_000;
    await tick();
    expect(row()).toEqual({ meta: "done", title: "Question", thumb_type: null, thumb_v: 0 });
    const calls = fake.calls.length;
    up = true;
    now = 359_999;
    await tick();
    expect(fake.calls).toHaveLength(calls);
    now = 360_000;
    await tick();
    expect(row()).toEqual({ meta: "done", title: "Question", thumb_type: "image/png", thumb_v: 1 });
    expect(new Uint8Array(readFileSync(join(tmp.dir, "thumbs", String(id))))).toEqual(PNG);
    const recoveredCalls = fake.calls.length;
    now += 43_200_000;
    await tick();
    expect(fake.calls).toHaveLength(recoveredCalls);
  } finally {
    server.stop(true);
    app.push.close();
    await app.idle();
    app.db.close();
    fake.restore();
    tmp.cleanup();
  }
});
