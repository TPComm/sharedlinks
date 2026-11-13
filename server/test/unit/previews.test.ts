import type { Database } from "bun:sqlite";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, spyOn, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { openDatabase } from "../../src/db.ts";
import { BOT_UA, BROWSER_UA } from "../../src/net.ts";
import { decodeEntities, fetchMetadata, fetchPreview, ogTags, previewFromTags } from "../../src/previews.ts";
import { fakeFetch, PNG, stubServer, tempDir } from "./helpers.ts";

const local = { allowPrivateNetwork: true };
const page = (head: string, status = 200) =>
  new Response(`<html><head>${head}</head><body></body></html>`, { status, headers: { "Content-Type": "text/html" } });

describe("decodeEntities", () => {
  test.each([
    ["Tom &amp; Jerry", "Tom & Jerry"],
    ["&lt;b&gt; &quot;hi&quot; &apos;x&apos;", `<b> "hi" 'x'`],
    ["Caf&eacute; &mdash; it&rsquo;s &hellip;", "Café — it’s …"],
    ["&Eacute;cole &eacute;cole", "École école"], // case-sensitive first
    ["&AMP; &Amp; &HELLIP;", "& & …"], // then case-insensitive
    ["a&nbsp;b", "a b"],
    ["&#65;&#x42;&#X43;&#x1F600;", "ABC😀"],
    ["&#1114111;", String.fromCodePoint(0x10ffff)],
    // Invalid or unknown: left as written.
    ["&#0; &#x0;", "&#0; &#x0;"],
    ["&#x110000; &#1114112;", "&#x110000; &#1114112;"],
    ["&#99999999;", "&#99999999;"],
    ["&bogus; &amp", "&bogus; &amp"],
    ["& alone; &;", "& alone; &;"],
    // One pass only.
    ["&amp;lt;", "&lt;"],
    // Names of Object.prototype members aren't entities.
    ["&constructor; &toString; &valueOf; &hasOwnProperty; &isPrototypeOf;", "&constructor; &toString; &valueOf; &hasOwnProperty; &isPrototypeOf;"],
  ])("%p -> %p", (input, want) => {
    expect(decodeEntities(input)).toBe(want);
  });
});

describe("ogTags", () => {
  test("first value wins, by property or name, with entities decoded", () => {
    expect(ogTags(`
      <meta content='X &amp; Y' property="og:title">
      <meta property="og:title" content="second">
      <meta name="description" content="a">
      <META PROPERTY="OG:Image" CONTENT="https://cdn/i.jpg">
      <meta name="twitter:title" content="tw">
    `)).toEqual({ "og:title": "X & Y", description: "a", "og:image": "https://cdn/i.jpg", "twitter:title": "tw" });
  });

  test("a meta tag without content doesn't claim the key", () => {
    expect(ogTags(`<meta property="og:title"><meta property="og:title" content="real">`)).toEqual({ "og:title": "real" });
  });

  test("attribute names must match whole words", () => {
    expect(ogTags(`<meta data-property="og:title" content="no"><meta xname="description" content="no">`)).toEqual({});
    expect(ogTags(`<meta property="og:title" data-content="no">`)).toEqual({});
  });

  test("<title>, decoded and trimmed, with attributes", () => {
    expect(ogTags(`<title data-rh="true">  Tom &amp; Jerry  </title>`)).toEqual({ title: "Tom & Jerry" });
    expect(ogTags(`<TITLE>Upper</TITLE>`)).toEqual({ title: "Upper" });
  });

  test("only the <head> is read", () => {
    const html = `<head><title>T</title></HEAD ><body><meta property="og:title" content="body"><title>Body</title></body>`;
    expect(ogTags(html)).toEqual({ title: "T" });
  });

  test("only the first 512 KB is read when there's no </head>", () => {
    const filler = "x".repeat(512 * 1024);
    expect(ogTags(`<meta property="og:title" content="early">${filler}`)).toEqual({ "og:title": "early" });
    expect(ogTags(`${filler}<meta property="og:title" content="late">`)).toEqual({});
  });

  // An attribute name can't start right after "-" or ":", or each segment of a hyphenated run
  // would rescan the rest of the tag (~1.5 s here instead of well under 1 ms).
  test.each([["-"], [":"]])("names joined by %p parse in linear time", (sep) => {
    const tag = `<meta ${`a${sep}`.repeat(40_000)}>`;
    const t = performance.now();
    expect(ogTags(tag)).toEqual({});
    expect(performance.now() - t).toBeLessThan(300);
  });
});

describe("previewFromTags", () => {
  test.each([
    ["web", { "og:title": "OG", "twitter:title": "TW", title: "T" }, { title: "OG", author: null, image: null }],
    ["web", { "twitter:title": "TW", title: "T" }, { title: "TW", author: null, image: null }],
    ["web", { "og:title": "", title: "T", "og:image": "", "twitter:image": "t.png" }, { title: "T", author: null, image: "t.png" }],
    ["web", { "og:site_name": "PetTube", "og:image": "o.png", "twitter:image": "t.png" }, { title: null, author: "PetTube", image: "o.png" }],
    ["web", {}, { title: null, author: null, image: null }],
    ["youtube", { "og:title": "Video", "og:site_name": "YouTube" }, { title: "Video", author: "YouTube", image: null }],
    // TikTok: "TikTok · Creator", the caption is the description.
    ["tiktok", { "og:title": "TikTok · Scout, Suki & Stella", "og:image": "x.jpg" }, { title: null, author: "Scout, Suki & Stella", image: "x.jpg" }],
    ["tiktok", { "og:title": "TikTok · Sam", "og:description": " the ending 😂 " }, { title: "the ending 😂", author: "Sam", image: null }],
    ["tiktok", { "og:title": "TikTok | Sam " }, { title: null, author: "Sam", image: null }],
    ["tiktok", { "og:title": "TikTok - Sam" }, { title: null, author: "Sam", image: null }],
    ["tiktok", { "og:title": "TikTok – Sam" }, { title: null, author: "Sam", image: null }],
    ["tiktok", { "og:title": " TikTok ", "og:site_name": "TikTok" }, { title: null, author: "TikTok", image: null }],
    ["tiktok", { "og:title": "A caption | TikTok" }, { title: "A caption | TikTok", author: null, image: null }],
    // Instagram: 'Name on Instagram: "caption"', the handle is in the description.
    ["instagram", {
      "og:title": 'Sam Lee on Instagram: "beach day"',
      "og:description": '12K likes, 40 comments - sam.lee_99 on May 1, 2025: "beach day"',
    }, { title: "beach day", author: "@sam.lee_99", image: null }],
    ["instagram", { "og:title": "Sam Lee on Instagram: “line one\nline two”" }, { title: "line one\nline two", author: "Sam Lee", image: null }],
    ["instagram", { "og:title": " Instagram ", "og:site_name": "Instagram" }, { title: null, author: "Instagram", image: null }],
    ["instagram", { "og:title": "Something else" }, { title: "Something else", author: null, image: null }],
  ] as [string, Record<string, string>, object][])("%s %p", (platform, og, want) => {
    expect(previewFromTags(platform, og)).toEqual(want);
  });
});

describe("fetchPreview (fake fetch)", () => {
  let fake: ReturnType<typeof fakeFetch> | undefined;
  afterEach(() => fake?.restore());
  const TIKTOK = "https://www.tiktok.com/@/video/7506136711311772958";
  const YOUTUBE = "https://www.youtube.com/watch?v=abc&t=3";
  const tiktokPage = () => page(`<meta property="og:title" content="TikTok · Scout &amp; Suki">` +
    `<meta property="og:description" content="the ending"><meta property="og:image" content="https://cdn.example/t.jpg">`);

  test("YouTube uses oEmbed", async () => {
    fake = fakeFetch(() => Response.json({ title: "A video", author_name: "Chan", thumbnail_url: "https://i.ytimg.com/x.jpg" }));
    expect(await fetchPreview(YOUTUBE, "youtube", local)).toEqual({ title: "A video", author: "Chan", image: "https://i.ytimg.com/x.jpg" });
    expect(fake.calls.map((c) => c.url)).toEqual([`https://www.youtube.com/oembed?format=json&url=${encodeURIComponent(YOUTUBE)}`]);
  });

  test("a YouTube oEmbed error fails without fetching the page", async () => {
    fake = fakeFetch(() => new Response("nope", { status: 404 }));
    await expect(fetchPreview(YOUTUBE, "youtube", local)).rejects.toThrow("HTTP 404");
    expect(fake.calls.length).toBe(1);
  });

  test("TikTok oEmbed with a title is used as is", async () => {
    fake = fakeFetch(() => Response.json({ title: "cap", author_name: "Sam", thumbnail_url: "https://cdn/t.jpg", html: "<x>" }));
    expect(await fetchPreview(TIKTOK, "tiktok", local)).toEqual({ title: "cap", author: "Sam", image: "https://cdn/t.jpg" });
    expect(fake.calls.map((c) => c.url)).toEqual([`https://www.tiktok.com/oembed?url=${encodeURIComponent(TIKTOK)}`]);
  });

  test.each([
    ["only the embed html", () => Response.json({ html: "<blockquote></blockquote>" })],
    ["an error", () => new Response("busy", { status: 500 })],
    ["invalid JSON", () => new Response("<html>")],
  ])("TikTok oEmbed with %s falls back to the page's tags, fetched as a link-preview bot", async (_, oembed) => {
    fake = fakeFetch((url) => (url.includes("/oembed?") ? oembed() : tiktokPage()));
    expect(await fetchPreview(TIKTOK, "tiktok", local)).toEqual({ title: "the ending", author: "Scout & Suki", image: "https://cdn.example/t.jpg" });
    expect(fake.calls.map((c) => c.url)).toEqual([`https://www.tiktok.com/oembed?url=${encodeURIComponent(TIKTOK)}`, TIKTOK]);
    expect(fake.calls[1]!.headers.get("user-agent")).toBe(BOT_UA);
  });

  test.each([
    ["instagram", "https://www.instagram.com/reel/ABC", BOT_UA],
    ["facebook", "https://www.facebook.com/watch?v=1", BOT_UA],
    ["web", "https://example.com/a", BROWSER_UA],
    ["x", "https://x.com/a/status/1", BROWSER_UA],
    ["reddit", "https://www.reddit.com/r/a", BROWSER_UA],
  ])("%s: no oEmbed, page fetched once with the right User-Agent", async (platform, url, ua) => {
    fake = fakeFetch(() => page(`<meta property="og:title" content="Hi">`));
    expect((await fetchPreview(url, platform, local)).title).toBe("Hi");
    expect(fake.calls.map((c) => c.url)).toEqual([url]);
    expect(fake.calls[0]!.headers.get("user-agent")).toBe(ua);
  });

  test("a page that isn't 2xx fails", async () => {
    fake = fakeFetch(() => page("<title>Not found</title>", 404));
    await expect(fetchPreview("https://example.com/gone", "web", local)).rejects.toThrow("HTTP 404");
  });
});

describe("fetchMetadata (local stub)", () => {
  const BIG = new Uint8Array(6_500_000).fill(1);
  let db: Database;
  let tmp: ReturnType<typeof tempDir>;
  let deleteOnThumb = 0;
  const stub = stubServer({
    "/page": () => page(`<meta property="og:title" content="Cats &amp; Dogs"><meta property="og:site_name" content="PetTube">` +
      `<meta property="og:image" content="/thumb.png">`),
    "/long": () => page(`<meta property="og:title" content="  A\n\n  ${"x".repeat(400)}">` +
      `<meta property="og:site_name" content="${"y".repeat(100)}">`),
    "/html-thumb": () => page(`<title>T</title><meta property="og:image" content="/not-image">`),
    "/missing-thumb": () => page(`<title>T</title><meta property="og:image" content="/nope.png">`),
    "/big-thumb": () => page(`<title>T</title><meta property="og:image" content="/big.jpg">`),
    "/no-title-thumb": () => page(`<meta property="og:image" content="/thumb.png">`),
    "/empty": () => page(""),
    "/error": () => page("<title>T</title>", 500),
    "/deleted": () => page(`<title>T</title><meta property="og:image" content="/thumb-delete.png">`),
    "/thumb.png": () => new Response(PNG, { headers: { "Content-Type": "image/png" } }),
    "/thumb-delete.png": () => {
      db.run("DELETE FROM links WHERE id = ?", [deleteOnThumb]);
      return new Response(PNG, { headers: { "Content-Type": "image/png" } });
    },
    "/not-image": () => page("<title>html</title>"),
    "/big.jpg": () => new Response(BIG, { headers: { "Content-Type": "image/jpeg" } }),
  });

  let consoleError: ReturnType<typeof spyOn>;
  beforeAll(() => {
    consoleError = spyOn(console, "error").mockImplementation(() => {});
  });
  afterAll(() => {
    consoleError.mockRestore();
    stub.stop();
  });
  beforeEach(() => {
    tmp = tempDir();
    db = openDatabase(tmp.dir);
  });
  afterEach(() => {
    db.close();
    tmp.cleanup();
  });

  async function run(path: string) {
    const url = stub.origin + path;
    const id = Number(db.run("INSERT INTO links (url, platform, added_by, added_at) VALUES (?, 'web', 'u', 1)", [url]).lastInsertRowid);
    await fetchMetadata(db, tmp.dir, id, url, "web", local);
    const row = db.query("SELECT title, author, thumb_type, meta FROM links WHERE id = ?").get(id);
    const file = join(tmp.dir, "thumbs", String(id));
    return { id, row, file, thumb: existsSync(file) ? readFileSync(file) : null };
  }

  test("stores the title, creator and thumbnail (relative URL resolved against the page)", async () => {
    const { row, thumb } = await run("/page");
    expect(row).toEqual({ title: "Cats & Dogs", author: "PetTube", thumb_type: "image/png", meta: "done" });
    expect(new Uint8Array(thumb!)).toEqual(PNG);
  });

  test("title and author are collapsed and clipped", async () => {
    const { row } = await run("/long");
    expect(row).toMatchObject({ title: `A ${"x".repeat(298)}`, author: "y".repeat(80) });
  });

  test.each([["/html-thumb"], ["/missing-thumb"]])("%p: no usable thumbnail, no file", async (path) => {
    const { row, thumb } = await run(path);
    expect(row).toEqual({ title: "T", author: null, thumb_type: null, meta: "done" });
    expect(thumb).toBeNull();
  });

  test("thumbnails are capped at 6 MB", async () => {
    const { row, thumb } = await run("/big-thumb");
    expect(row).toMatchObject({ thumb_type: "image/jpeg", meta: "done" });
    expect(thumb!.length).toBe(6_000_000);
  });

  test("a thumbnail without a title still counts as done", async () => {
    const { row } = await run("/no-title-thumb");
    expect(row).toEqual({ title: null, author: null, thumb_type: "image/png", meta: "done" });
  });

  test.each([["/empty"], ["/error"]])("%p: nothing found is 'failed'", async (path) => {
    const { row } = await run(path);
    expect(row).toEqual({ title: null, author: null, thumb_type: null, meta: "failed" });
  });

  test("a link deleted mid-fetch leaves no thumbnail behind", async () => {
    deleteOnThumb = 1; // a fresh database's first link
    const { id, row, file } = await run("/deleted");
    expect(id).toBe(deleteOnThumb);
    expect(row).toBeNull();
    expect(existsSync(file)).toBe(false);
  });
});
