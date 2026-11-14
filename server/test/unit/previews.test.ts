import type { Database } from "bun:sqlite";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, spyOn, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { openDatabase } from "../../src/db.ts";
import { BOT_UA, BROWSER_UA } from "../../src/net.ts";
import {
  decodeEntities, fetchMetadata, fetchPreview, imageSize, instagramEmbedUrl, instagramFromEmbed, ogTags, PREVIEW_VERSION,
  previewFromTags,
} from "../../src/previews.ts";
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
    ["instagram", { "og:title": " Instagram ", "og:site_name": "Instagram" }, { title: null, author: null, image: null }],
    ["instagram", { "og:title": "Something else" }, { title: "Something else", author: null, image: null }],
  ] as [string, Record<string, string>, object][])("%s %p", (platform, og, want) => {
    expect(previewFromTags(platform, og)).toMatchObject(want);
  });
});

describe("rich preview fields", () => {
  test("description, site name and the og:image size", () => {
    expect(previewFromTags("web", {
      "og:title": "Rates rise", "og:description": " The bank moved again. ", "og:site_name": "The Paper",
      "og:image": "https://cdn/a.jpg", "og:image:width": "1200", "og:image:height": " 630 ",
    })).toEqual({
      title: "Rates rise", author: "The Paper", image: "https://cdn/a.jpg", description: "The bank moved again.",
      siteName: "The Paper", imageWidth: 1200, imageHeight: 630,
    });
  });

  test.each([
    [{ "twitter:description": "tw" }, "tw"],
    [{ description: "plain" }, "plain"],
    [{ "og:title": "Same", "og:description": "Same" }, null], // no point repeating the title
    [{}, null],
  ])("description from %p", (og, want) => {
    expect(previewFromTags("web", og as Record<string, string>).description).toBe(want);
  });

  test.each([
    [{ "og:image": "a.jpg", "og:image:width": "0", "og:image:height": "10" }, null, 10],
    [{ "og:image": "a.jpg", "og:image:width": "wide", "og:image:height": "1.5" }, null, null],
    [{ "og:image": "a.jpg", "og:image:width": "999999" }, null, null],
    [{ "twitter:image": "t.jpg", "og:image:width": "100", "og:image:height": "100" }, null, null], // size is og:image's
    [{ "og:image:url": "u.jpg", "og:image:width": "100", "og:image:height": "200" }, 100, 200],
  ])("image size from %p", (og, w, h) => {
    const p = previewFromTags("web", og as Record<string, string>);
    expect([p.imageWidth, p.imageHeight]).toEqual([w, h]);
  });

  test("site name falls back to the platform's name", () => {
    expect(previewFromTags("youtube", {}).siteName).toBe("YouTube");
    expect(previewFromTags("tiktok", {}).siteName).toBe("TikTok");
    expect(previewFromTags("web", {}).siteName).toBeNull();
  });

  test("Instagram: caption, @handle and only the engagement counts as the description", () => {
    expect(previewFromTags("instagram", {
      "og:title": 'Sam Lee on Instagram: "beach day 🌊"',
      "og:description": '12K likes, 40 comments - samlee on May 1, 2025: "beach day 🌊"',
      "og:image": "https://cdn/reel.jpg", "og:image:width": "640", "og:image:height": "1136",
    })).toEqual({
      title: "beach day 🌊", author: "@samlee", image: "https://cdn/reel.jpg", description: "12K likes, 40 comments",
      siteName: "Instagram", imageWidth: 640, imageHeight: 1136,
    });
  });

  test("Instagram login wall: nothing usable", () => {
    expect(previewFromTags("instagram", { "og:title": "Instagram", "og:description": "Create an account or log in to Instagram." }))
      .toMatchObject({ title: null, author: null, description: null });
  });

  test("Instagram login wall: its logo and site name aren't the post's image and author", () => {
    // instagram.com/accounts/login/ as served to a link-preview bot.
    expect(previewFromTags("instagram", {
      "og:site_name": "Instagram", "og:title": "Instagram", "og:url": "https://instagram.com/",
      "og:image": "https://static.cdninstagram.com/rsrc.php/v4/yD/r/R0fBIMurK8v.png",
    })).toMatchObject({ title: null, author: null, image: null, description: null, siteName: "Instagram" });
  });
});

describe("imageSize", () => {
  const bytes = (...parts: (number[] | string)[]) =>
    Uint8Array.from(parts.flatMap((p) => (typeof p === "string" ? [...p].map((c) => c.charCodeAt(0)) : p)));
  const u16be = (n: number) => [n >> 8, n & 255];
  const u16le = (n: number) => [n & 255, n >> 8];
  const u24le = (n: number) => [n & 255, (n >> 8) & 255, n >> 16];
  const u32le = (n: number) => [n & 255, (n >> 8) & 255, (n >> 16) & 255, n >>> 24];
  /** A 1920×1080 frame after an APP1 Exif segment holding `tiff`. */
  const jpegWithExif = (tiff: Uint8Array) => bytes([0xff, 0xd8, 0xff, 0xe1], u16be(8 + tiff.length), "Exif", [0, 0], [...tiff],
    [0xff, 0xc0], u16be(17), [8], u16be(1080), u16be(1920), new Array(12).fill(0));

  test.each([
    ["PNG", PNG, { width: 1, height: 1 }],
    ["GIF", bytes("GIF89a", u16le(320), u16le(240)), { width: 320, height: 240 }],
    ["JPEG (size after APP0)", bytes([0xff, 0xd8, 0xff, 0xe0], u16be(4), [0, 0],
      [0xff, 0xc0], u16be(17), [8], u16be(1920), u16be(1080), new Array(12).fill(0)), { width: 1080, height: 1920 }],
    ["progressive JPEG", bytes([0xff, 0xd8, 0xff, 0xc4], u16be(2), [0xff, 0xc2], u16be(17), [8], u16be(100), u16be(50),
      new Array(12).fill(0)), { width: 50, height: 100 }],
    ["JPEG turned by EXIF (big-endian)", jpegWithExif(bytes("MM", [0, 42], [0, 0, 0, 8], u16be(1), u16be(0x0112), u16be(3), [0, 0, 0, 1],
      u16be(6), [0, 0], [0, 0, 0, 0])), { width: 1080, height: 1920 }],
    ["JPEG turned by EXIF (little-endian)", jpegWithExif(bytes("II", [42, 0], [8, 0, 0, 0], u16le(1), u16le(0x0112), u16le(3), [1, 0, 0, 0],
      u16le(8), [0, 0], [0, 0, 0, 0])), { width: 1080, height: 1920 }],
    ["JPEG upright by EXIF", jpegWithExif(bytes("II", [42, 0], [8, 0, 0, 0], u16le(1), u16le(0x0112), u16le(3), [1, 0, 0, 0],
      u16le(1), [0, 0], [0, 0, 0, 0])), { width: 1920, height: 1080 }],
    ["JPEG with truncated EXIF", jpegWithExif(bytes("MM", [0, 42], [0, 0, 0xff, 0xff])), { width: 1920, height: 1080 }],
    ["WebP VP8X", bytes("RIFF", [0, 0, 0, 0], "WEBPVP8X", [0, 0, 0, 0, 0, 0, 0, 0], u24le(639), u24le(1135)), { width: 640, height: 1136 }],
    ["WebP VP8", bytes("RIFF", [0, 0, 0, 0], "WEBPVP8 ", new Array(10).fill(0), u16le(400), u16le(300)), { width: 400, height: 300 }],
    ["WebP VP8L", bytes("RIFF", [0, 0, 0, 0], "WEBPVP8L", [0, 0, 0, 0, 0x2f], u32le(99 | (199 << 14)), new Array(6).fill(0)), { width: 100, height: 200 }],
  ])("%s", (_, b, want) => {
    expect(imageSize(b as Uint8Array)).toEqual(want);
  });

  test.each([
    ["empty", new Uint8Array()],
    ["HTML", bytes("<html><head></head></html>")],
    ["truncated PNG", PNG.slice(0, 20)],
    ["JPEG without a frame", bytes([0xff, 0xd8, 0xff, 0xe0], u16be(4), [0, 0, 0xff, 0xd9, 0, 0, 0, 0, 0, 0, 0, 0])],
    ["JPEG with a zero-length segment", bytes([0xff, 0xd8, 0xff, 0xe1, 0, 0], new Array(12).fill(0))],
  ])("%s: null", (_, b) => {
    expect(imageSize(b)).toBeNull();
  });
});

describe("Instagram embed fallback", () => {
  test.each([
    ["https://www.instagram.com/reel/DCx_1-a/", "https://www.instagram.com/reel/DCx_1-a/embed/captioned/"],
    ["https://www.instagram.com/reels/DCx/", "https://www.instagram.com/reel/DCx/embed/captioned/"],
    ["https://www.instagram.com/p/Cab/?img_index=2", "https://www.instagram.com/p/Cab/embed/captioned/"],
    ["https://www.instagram.com/samlee/reel/DCx/", "https://www.instagram.com/reel/DCx/embed/captioned/"],
    ["https://www.instagram.com/samlee/", null],
  ])("%s -> %p", (url, want) => {
    expect(instagramEmbedUrl(url)).toBe(want);
  });

  const EMBED = `<html><body><div class="Embed">
    <a class="Header"><span class="UsernameText">samlee</span></a>
    <img class="EmbeddedMediaImage" alt="x" src="https://cdn/reel.jpg?a=1&amp;b=2">
    <div class="Caption"><a class="CaptionUsername" href="/samlee/">samlee</a><br>beach day &amp; sun 🌊<br><br>
      <a href="/explore/tags/summer/">#summer</a>
      <div class="CaptionComments"><a>View all 40 comments</a></div></div></div></body></html>`;

  test("parses the image, the @handle and the caption", () => {
    expect(instagramFromEmbed(EMBED)).toEqual({
      title: "beach day & sun 🌊\n\n#summer", author: "@samlee", image: "https://cdn/reel.jpg?a=1&b=2", siteName: "Instagram",
    });
  });

  test("a broken-media page gives nothing", () => {
    expect(instagramFromEmbed(`<div class="EmbedBrokenMedia">x</div>`)).toEqual({
      title: null, author: null, image: null, siteName: "Instagram",
    });
  });

  test("hostile pages parse in linear time", () => {
    const start = performance.now();
    instagramFromEmbed(`<div class="Caption">${"<a class='CaptionUsername' ".repeat(50_000)}`);
    instagramFromEmbed(`<img class="EmbeddedMediaImage" ${"src='x' ".repeat(100_000)}`);
    instagramFromEmbed(`class="UsernameText"${" ".repeat(500_000)}`);
    expect(performance.now() - start).toBeLessThan(1000);
  });

  let fake: ReturnType<typeof fakeFetch> | undefined;
  afterEach(() => fake?.restore());
  const REEL = "https://www.instagram.com/reel/DCx/";
  const EMBED_URL = "https://www.instagram.com/reel/DCx/embed/captioned/";
  const html = (body: string, status = 200) => new Response(body, { status, headers: { "Content-Type": "text/html" } });

  test("a full Open Graph page is used without the embed", async () => {
    fake = fakeFetch(() => page(`<meta property="og:title" content='Sam on Instagram: "hi"'><meta property="og:image" content="https://cdn/i.jpg">`));
    expect(await fetchPreview(REEL, "instagram", local)).toMatchObject({ title: "hi", image: "https://cdn/i.jpg" });
    expect(fake.calls.map((c) => c.url)).toEqual([REEL]);
    expect(fake.calls[0]!.headers.get("user-agent")).toBe(BOT_UA);
  });

  test("a login wall falls back to the embed page, fetched as a browser", async () => {
    fake = fakeFetch((url) => (url === EMBED_URL ? html(EMBED) : page(`<title>Instagram</title><meta property="og:title" content="Instagram">`)));
    expect(await fetchPreview(REEL, "instagram", local)).toMatchObject({
      title: "beach day & sun 🌊\n\n#summer", author: "@samlee", image: "https://cdn/reel.jpg?a=1&b=2", siteName: "Instagram",
    });
    expect(fake.calls.map((c) => c.url)).toEqual([REEL, EMBED_URL]);
    expect(fake.calls[1]!.headers.get("user-agent")).toBe(BROWSER_UA);
  });

  test("the page's counts and image size survive an embed that fills in the rest", async () => {
    fake = fakeFetch((url) => (url === EMBED_URL ? html(EMBED) : page(
      `<meta property="og:description" content="5 likes, 1 comment - samlee on May 1, 2025: &quot;x&quot;">`)));
    expect(await fetchPreview(REEL, "instagram", local)).toMatchObject({ description: "5 likes, 1 comment", author: "@samlee", title: "beach day & sun 🌊\n\n#summer" });
  });

  test("a failed page fetch still tries the embed", async () => {
    fake = fakeFetch((url) => (url === EMBED_URL ? html(EMBED) : html("", 429)));
    expect((await fetchPreview(REEL, "instagram", local)).author).toBe("@samlee");
  });

  test("both failing is an error", async () => {
    fake = fakeFetch(() => html("", 429));
    await expect(fetchPreview(REEL, "instagram", local)).rejects.toThrow("HTTP 429");
  });

  test("a backfill that meets the login wall and a rate-limited embed keeps the reel's thumbnail and @handle", async () => {
    const tmp = tempDir();
    const db = openDatabase(tmp.dir);
    const consoleError = spyOn(console, "error").mockImplementation(() => {});
    try {
      const id = Number(db.run(
        `INSERT INTO links (url, platform, title, author, thumb_type, thumb_w, thumb_h, thumb_v, meta, added_by, added_at)
         VALUES (?, 'instagram', 'beach day', '@samlee', 'image/png', 1, 1, 1, 'done', 'u', 1)`, [REEL]).lastInsertRowid);
      const file = join(tmp.dir, "thumbs", String(id));
      await Bun.write(file, PNG);
      const LOGO = "https://static.cdninstagram.com/rsrc.php/v4/yD/r/R0fBIMurK8v.png";
      fake = fakeFetch((url) => {
        if (url === EMBED_URL) return html("", 429);
        if (url === LOGO) return new Response(Uint8Array.from([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0]), { headers: { "Content-Type": "image/gif" } });
        return page(`<meta property="og:site_name" content="Instagram"><meta property="og:title" content="Instagram">` +
          `<meta property="og:image" content="${LOGO}">`);
      });
      await fetchMetadata(db, tmp.dir, id, REEL, "instagram", local);
      expect(db.query("SELECT title, author, thumb_type, thumb_v, meta FROM links WHERE id = ?").get(id))
        .toEqual({ title: "beach day", author: "@samlee", thumb_type: "image/png", thumb_v: 1, meta: "done" });
      expect(new Uint8Array(readFileSync(file))).toEqual(PNG);
    } finally {
      consoleError.mockRestore();
      db.close();
      tmp.cleanup();
    }
  });

  test("an empty embed keeps whatever the page had", async () => {
    fake = fakeFetch((url) => (url === EMBED_URL ? html("<div class='EmbedBrokenMedia'></div>") : page(`<meta property="og:title" content="Only a title">`)));
    expect(await fetchPreview(REEL, "instagram", local)).toMatchObject({ title: "Only a title", image: null });
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
    expect(await fetchPreview(YOUTUBE, "youtube", local)).toMatchObject({ title: "A video", author: "Chan", image: "https://i.ytimg.com/x.jpg" });
    expect(fake.calls.map((c) => c.url)).toEqual([`https://www.youtube.com/oembed?format=json&url=${encodeURIComponent(YOUTUBE)}`]);
  });

  test("a YouTube oEmbed error fails without fetching the page", async () => {
    fake = fakeFetch(() => new Response("nope", { status: 404 }));
    await expect(fetchPreview(YOUTUBE, "youtube", local)).rejects.toThrow("HTTP 404");
    expect(fake.calls.length).toBe(1);
  });

  test("TikTok oEmbed with a title is used as is", async () => {
    fake = fakeFetch(() => Response.json({ title: "cap", author_name: "Sam", thumbnail_url: "https://cdn/t.jpg", html: "<x>" }));
    expect(await fetchPreview(TIKTOK, "tiktok", local)).toMatchObject({ title: "cap", author: "Sam", image: "https://cdn/t.jpg" });
    expect(fake.calls.map((c) => c.url)).toEqual([`https://www.tiktok.com/oembed?url=${encodeURIComponent(TIKTOK)}`]);
  });

  test.each([
    ["only the embed html", () => Response.json({ html: "<blockquote></blockquote>" })],
    ["an error", () => new Response("busy", { status: 500 })],
    ["invalid JSON", () => new Response("<html>")],
  ])("TikTok oEmbed with %s falls back to the page's tags, fetched as a link-preview bot", async (_, oembed) => {
    fake = fakeFetch((url) => (url.includes("/oembed?") ? oembed() : tiktokPage()));
    expect(await fetchPreview(TIKTOK, "tiktok", local)).toMatchObject({ title: "the ending", author: "Scout & Suki", image: "https://cdn.example/t.jpg" });
    expect(fake.calls.map((c) => c.url)).toEqual([`https://www.tiktok.com/oembed?url=${encodeURIComponent(TIKTOK)}`, TIKTOK]);
    expect(fake.calls[1]!.headers.get("user-agent")).toBe(BOT_UA);
  });

  test.each([
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
    "/rich": () => page(`<meta property="og:title" content="Reel"><meta property="og:description" content="About it">` +
      `<meta property="og:site_name" content="Site"><meta property="og:image" content="/thumb.png">` +
      `<meta property="og:image:width" content="640"><meta property="og:image:height" content="1136">`),
    "/og-size": () => page(`<title>T</title><meta property="og:image" content="/big.jpg">` +
      `<meta property="og:image:width" content="640"><meta property="og:image:height" content="1136">`),
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

  const rich = (id: number) =>
    db.query("SELECT description, site_name, thumb_w, thumb_h, preview_v, thumb_v FROM links WHERE id = ?").get(id);

  test("stores the description, site name and the decoded thumbnail size over og:image:width/height", async () => {
    const { id, row } = await run("/rich");
    expect(row).toMatchObject({ title: "Reel", thumb_type: "image/png", meta: "done" });
    expect(rich(id)).toEqual({ description: "About it", site_name: "Site", thumb_w: 1, thumb_h: 1, preview_v: PREVIEW_VERSION, thumb_v: 1 });
  });

  test("each new thumbnail bumps thumb_v, so clients refetch it", async () => {
    const { id } = await run("/rich");
    await fetchMetadata(db, tmp.dir, id, `${stub.origin}/rich`, "web", local);
    expect(rich(id)).toMatchObject({ thumb_v: 2 });
  });

  test("an undecodable thumbnail keeps the og:image size", async () => {
    const { id } = await run("/og-size");
    expect(rich(id)).toMatchObject({ thumb_w: 640, thumb_h: 1136 });
  });

  test("a re-fetch that finds less keeps what the link had", async () => {
    const { id, file } = await run("/rich");
    const url = `${stub.origin}/error`;
    db.run("UPDATE links SET url = ?, preview_v = 0 WHERE id = ?", [url, id]);
    await fetchMetadata(db, tmp.dir, id, url, "web", local);
    expect(db.query("SELECT title, thumb_type, meta FROM links WHERE id = ?").get(id))
      .toEqual({ title: "Reel", thumb_type: "image/png", meta: "done" });
    expect(rich(id)).toEqual({ description: "About it", site_name: "Site", thumb_w: 1, thumb_h: 1, preview_v: PREVIEW_VERSION, thumb_v: 1 });
    expect(new Uint8Array(readFileSync(file))).toEqual(PNG);
  });

  test("a link deleted mid-fetch leaves no thumbnail behind", async () => {
    deleteOnThumb = 1; // a fresh database's first link
    const { id, row, file } = await run("/deleted");
    expect(id).toBe(deleteOnThumb);
    expect(row).toBeNull();
    expect(existsSync(file)).toBe(false);
    expect(existsSync(`${file}.part`)).toBe(false);
  });
});
