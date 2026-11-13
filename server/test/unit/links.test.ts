import { afterAll, afterEach, describe, expect, test } from "bun:test";
import {
  BadRequest, canonical, clip, clipText, expandShortLink, extractUrl, normalize, platformOf, resolveRedirects,
} from "../../src/links.ts";
import { closedPort, fakeFetch, redirect, stubServer } from "./helpers.ts";

const ID = "7506136711311772958";
const POST = `https://www.tiktok.com/@/video/${ID}`;
const local = { allowPrivateNetwork: true };
const norm = (url: string) => normalize(new URL(url));

describe("extractUrl", () => {
  test.each([
    ["lol look https://vm.tiktok.com/ZMabc/ 😂", "https://vm.tiktok.com/ZMabc/"],
    ["line one\nhttps://a.com/x\nline three", "https://a.com/x"],
    // Trailing punctuation, closing brackets and quotes belong to the message.
    ["https://a.com/x.", "https://a.com/x"],
    ["https://a.com/x...", "https://a.com/x"],
    ["https://a.com/x?y=1!?", "https://a.com/x?y=1"],
    ["see: https://a.com/x: cool", "https://a.com/x"],
    ["(see https://a.com/x);", "https://a.com/x"],
    ["[https://a.com/x]", "https://a.com/x"],
    ["{https://a.com/x}", "https://a.com/x"],
    ["`https://a.com/x`", "https://a.com/x"],
    ["<https://a.com/x>", "https://a.com/x"],
    ['"https://a.com/x"', "https://a.com/x"],
    ["'https://a.com/x'", "https://a.com/x"],
    // Punctuation inside the link stays.
    ["https://a.com/x.html?a=1,2&b=c;d", "https://a.com/x.html?a=1,2&b=c;d"],
    ["HTTPS://EXAMPLE.COM/X.", "HTTPS://EXAMPLE.COM/X"],
    ["first https://a.com/1 then https://b.com/2", "https://a.com/1"],
    // A full URL wins over an earlier bare domain.
    ["example.com/a then https://b.com/c", "https://b.com/c"],
    // Bare domains (with a path) get https://.
    ["www.instagram.com/reel/xyz).", "https://www.instagram.com/reel/xyz"],
    ["go to Example.COM/path?x=1, ok", "https://Example.COM/path?x=1"],
    ["youtu.be/abc", "https://youtu.be/abc"],
  ])("%p -> %p", (text, want) => {
    expect(extractUrl(text)).toBe(want);
  });

  test.each([["nothing here"], ["example.com"], ["http:// spaced out"], [""]])(
    "no link in %p", (text) => {
      expect(extractUrl(text)).toBeNull();
    });

  test("non-strings", () => {
    expect(extractUrl(null)).toBeNull();
    expect(extractUrl(undefined)).toBeNull();
    expect(extractUrl(42)).toBeNull();
  });
});

describe("platformOf", () => {
  test.each([
    ["tiktok.com", "tiktok"], ["www.tiktok.com", "tiktok"], ["vm.tiktok.com", "tiktok"], ["m.tiktok.com", "tiktok"],
    ["instagram.com", "instagram"], ["www.instagram.com", "instagram"], ["instagr.am", "instagram"],
    ["youtube.com", "youtube"], ["m.youtube.com", "youtube"], ["music.youtube.com", "youtube"], ["youtu.be", "youtube"],
    ["x.com", "x"], ["twitter.com", "x"], ["mobile.twitter.com", "x"],
    ["reddit.com", "reddit"], ["old.reddit.com", "reddit"], ["redd.it", "reddit"],
    ["facebook.com", "facebook"], ["m.facebook.com", "facebook"], ["fb.watch", "facebook"],
    // Look-alikes are plain web links.
    ["eviltiktok.com", "web"], ["tiktok.com.evil.net", "web"], ["notinstagram.com", "web"], ["instagram.co", "web"],
    ["notyoutu.be", "web"], ["box.com", "web"], ["x.com.au", "web"], ["myreddit.com", "web"], ["fb.watch.example", "web"],
    ["example.com", "web"], ["", "web"],
  ])("%p is %p", (host, want) => {
    expect(platformOf(host)).toBe(want);
  });
});

describe("normalize", () => {
  const cases: [string, string, string][] = [
    // TikTok: every spelling of a post becomes /@/video/<id>, with no query.
    [`https://www.tiktok.com/@someone/video/${ID}?_r=1&_t=ZS-92jrA0wKM6y`, POST, "tiktok"],
    [`https://www.tiktok.com/@someone/video/${ID}?is_from_webapp=1&sender_device=pc`, POST, "tiktok"],
    [`https://tiktok.com/@someone/video/${ID}/`, POST, "tiktok"],
    [`https://m.tiktok.com/@someone/video/${ID}`, POST, "tiktok"],
    [`http://www.tiktok.com/@someone/video/${ID}`, POST, "tiktok"],
    [`https://www.tiktok.com/@/video/${ID}`, POST, "tiktok"],
    [`https://www.tiktok.com/@someone/photo/${ID}`, POST, "tiktok"],
    [`https://www.tiktok.com/@SomeOne/video/${ID}.html`, POST, "tiktok"],
    [`https://m.tiktok.com/v/${ID}.html?u_code=x`, POST, "tiktok"],
    [`https://www.tiktok.com/v/${ID}`, POST, "tiktok"],
    [`https://www.tiktok.com/share/video/${ID}`, POST, "tiktok"],
    [`https://www.tiktok.com/embed/${ID}`, POST, "tiktok"],
    [`https://www.tiktok.com/embed/v2/${ID}`, POST, "tiktok"],
    [`https://www.tiktok.com/@a/video/${ID}#comments`, POST, "tiktok"],
    ["https://www.tiktok.com/@a/video/12345678", "https://www.tiktok.com/@/video/12345678", "tiktok"],
    ["https://www.tiktok.com/@a/video/12345678901234567890", "https://www.tiktok.com/@/video/12345678901234567890", "tiktok"],
    // TikTok, not a post: path kept, query dropped.
    ["https://www.tiktok.com/@someone?_t=x&_r=1", "https://www.tiktok.com/@someone", "tiktok"],
    ["https://www.tiktok.com/@a/live?enter_from=x", "https://www.tiktok.com/@a/live", "tiktok"],
    ["https://www.tiktok.com/tag/funny?lang=en", "https://www.tiktok.com/tag/funny", "tiktok"],
    ["https://www.tiktok.com/@a/video/1234567", "https://www.tiktok.com/@a/video/1234567", "tiktok"],
    ["https://www.tiktok.com/@a/video/123456789012345678901", "https://www.tiktok.com/@a/video/123456789012345678901", "tiktok"],
    [`https://www.tiktok.com/@a/video/${ID}/extra`, `https://www.tiktok.com/@a/video/${ID}/extra`, "tiktok"],
    ["https://vm.tiktok.com/ZMabc/?x=1", "https://vm.tiktok.com/ZMabc", "tiktok"],
    // Instagram: reel/reels/p, with or without the username, no query.
    ["https://instagram.com/reel/ABC/?igsh=1", "https://www.instagram.com/reel/ABC", "instagram"],
    ["https://www.instagram.com/reels/ABC/", "https://www.instagram.com/reel/ABC", "instagram"],
    ["https://www.instagram.com/someone/reel/ABC/?igsh=1", "https://www.instagram.com/reel/ABC", "instagram"],
    ["https://www.instagram.com/someone/p/ABC/?img_index=2", "https://www.instagram.com/p/ABC", "instagram"],
    ["https://m.instagram.com/p/ABC", "https://www.instagram.com/p/ABC", "instagram"],
    ["http://instagram.com/p/ABC/", "https://www.instagram.com/p/ABC", "instagram"],
    ["https://instagr.am/p/ABC/", "https://instagr.am/p/ABC", "instagram"],
    ["https://www.instagram.com/someone/", "https://www.instagram.com/someone", "instagram"],
    ["https://www.instagram.com/stories/someone/123/", "https://www.instagram.com/stories/someone/123", "instagram"],
    // A share link that couldn't be expanded keeps its path: its code isn't a post ID.
    ["https://www.instagram.com/share/reel/BAxyz/", "https://www.instagram.com/share/reel/BAxyz", "instagram"],
    ["https://www.instagram.com/share/p/BAxyz/?igsh=1", "https://www.instagram.com/share/p/BAxyz", "instagram"],
    // YouTube: www. forced, tracking removed, real params (v, t, list) kept in order.
    ["https://m.youtube.com/watch?v=1&si=2&t=3", "https://www.youtube.com/watch?v=1&t=3", "youtube"],
    ["https://youtube.com/watch?feature=share&v=X&list=L", "https://www.youtube.com/watch?v=X&list=L", "youtube"],
    ["http://www.youtube.com/watch?v=1&utm_source=a&utm_medium=b", "https://www.youtube.com/watch?v=1", "youtube"],
    ["https://www.youtube.com/shorts/abc/?feature=share", "https://www.youtube.com/shorts/abc", "youtube"],
    ["https://youtu.be/abc?si=x&t=10", "https://youtu.be/abc?t=10", "youtube"],
    ["https://music.youtube.com/watch?v=1&si=2", "https://music.youtube.com/watch?v=1", "youtube"],
    // Reddit and Facebook: www. forced on the bare domain only.
    ["https://reddit.com/r/a/comments/b/?utm_source=share&utm_medium=ios_app&context=3", "https://www.reddit.com/r/a/comments/b?context=3", "reddit"],
    ["https://old.reddit.com/r/a/?ref=x", "https://old.reddit.com/r/a", "reddit"],
    ["https://redd.it/abc", "https://redd.it/abc", "reddit"],
    ["https://m.facebook.com/watch/?v=123&fbclid=x", "https://www.facebook.com/watch?v=123", "facebook"],
    ["https://fb.watch/abc/?ref=x", "https://fb.watch/abc", "facebook"],
    // X keeps its host as given. Its share sheet adds s= and a per-share t= token, in either order.
    ["https://x.com/a/status/1?s=20&t=abc", "https://x.com/a/status/1", "x"],
    ["https://twitter.com/a/status/1?t=ZqHq3bx&s=19", "https://twitter.com/a/status/1", "x"],
    ["http://twitter.com/a/status/1?ref_src=twsrc", "https://twitter.com/a/status/1", "x"],
    // Web: scheme and port kept, tracking dropped, everything else kept.
    ["http://Example.com:8080/a/b/?utm_medium=x&page=2", "http://example.com:8080/a/b?page=2", "web"],
    ["https://example.com/?gclid=1&fbclid=2&igshid=3&igsh=4&ref=5&ref_src=6&si=8&feature=9&utm_campaign=10&q=keep",
      "https://example.com/?q=keep", "web"],
    // s= and t= are only tracking on X: a WordPress search, a video's start time.
    ["https://blog.example.com/?s=pasta", "https://blog.example.com/?s=pasta", "web"],
    ["https://example.com/video?t=90", "https://example.com/video?t=90", "web"],
    ["https://example.com/?referrer=x&source=y&sid=1", "https://example.com/?referrer=x&source=y&sid=1", "web"],
    ["https://example.com/?q=a b", "https://example.com/?q=a+b", "web"],
    ["https://example.com/page#section", "https://example.com/page", "web"],
    ["https://user:pass@example.com/x", "https://example.com/x", "web"],
    ["https://example.com:443/", "https://example.com/", "web"],
    ["http://example.com:80/x", "http://example.com/x", "web"],
    ["https://example.com", "https://example.com/", "web"],
    ["https://example.com/a//", "https://example.com/a", "web"],
    ["https://www.example.com/", "https://www.example.com/", "web"],
    ["https://EXAMPLE.com/A/B", "https://example.com/A/B", "web"],
    ["https://münchen.de/", "https://xn--mnchen-3ya.de/", "web"],
    ["https://ex_ample.com/x", "https://ex_ample.com/x", "web"],
    // Paths are spelled so Foundation's URL keeps them byte for byte.
    ["https://example.com/café|menu", "https://example.com/caf%C3%A9%7Cmenu", "web"],
    ["https://example.com/a[1]b", "https://example.com/a%5B1%5Db", "web"],
    ["https://example.com/100%", "https://example.com/100%25", "web"],
    ["https://example.com/a%zz", "https://example.com/a%25zz", "web"],
    ["https://example.com/x%7Cy", "https://example.com/x%7Cy", "web"],
    ["https://example.com/a%2Fb", "https://example.com/a%2Fb", "web"],
    ["https://example.com/a{b}^`", "https://example.com/a%7Bb%7D%5E%60", "web"],
    // IP hosts.
    ["http://[::1]:8080/a", "http://[::1]:8080/a", "web"],
    ["https://[2001:DB8::1]/x", "https://[2001:db8::1]/x", "web"],
    ["http://[::ffff:127.0.0.1]/", "http://[::ffff:7f00:1]/", "web"],
    ["https://127.0.0.1:3000/x?y=1", "https://127.0.0.1:3000/x?y=1", "web"],
  ];

  test.each(cases)("%p -> %p (%s)", (raw, url, platform) => {
    expect(norm(raw)).toEqual({ url, platform });
  });

  test("is idempotent (db.ts re-spells stored links with it)", () => {
    for (const [raw] of cases) {
      const once = norm(raw);
      expect(norm(once.url)).toEqual(once);
    }
  });

  test("paths only contain characters RFC 3986 allows", () => {
    for (const [raw] of cases) {
      const path = new URL(norm(raw).url).pathname;
      expect(path).toMatch(/^(?:[A-Za-z0-9\-._~!$&'()*+,;=:@/]|%[0-9A-F]{2})*$/);
    }
  });

  test.each([
    ["ftp://example.com/"], ["javascript:alert(1)"], ["mailto:a@b.com"], ["data:text/html,hi"], ["file:///etc/passwd"],
    // Hosts WHATWG accepts but iOS can't parse.
    ["https://exa{mple.com/x"], ["https://exa!mple.com/"], ["https://exa`mple.com/"], ["https://a$b.com/"], ["https://a*b.com/"],
  ])("rejects %p", (raw) => {
    expect(() => norm(raw)).toThrow(BadRequest);
    expect(() => norm(raw)).toThrow("That doesn't look like a link.");
  });
});

describe("clip", () => {
  test.each([
    ["  a \n\t b  ", 10, "a b"],
    ["abcdef", 3, "abc"],
    ["a😀b", 2, "a😀"], // characters, not UTF-16 units: the emoji isn't cut in half
    [null, 5, ""],
    [undefined, 5, ""],
    [12345, 2, "12"],
    ["abc", 0, ""],
  ])("clip(%p, %p) = %p", (value, max, want) => {
    expect(clip(value, max)).toBe(want);
  });

  test("clipText keeps line breaks", () => {
    expect(clipText("  line1\n\n  line2  ", 100)).toBe("line1\n\n  line2");
    expect(clipText("😀😀😀", 2)).toBe("😀😀");
    expect(clipText(null, 5)).toBe("");
  });
});

describe("resolveRedirects and expandShortLink (local stub)", () => {
  const stub = stubServer({
    "/start": () => redirect("/next"),
    "/next": () => redirect("/third"),
    "/post": () => redirect(`https://www.tiktok.com/@someone/video/${ID}?_r=1&u_code=x`),
    "/ig-wall": () => redirect("https://www.instagram.com/accounts/login/?next=%2Freel%2Fabc%2F"),
    "/tt-wall": () => redirect("https://www.tiktok.com/login?redirect_url=x"),
    "/login-handle": () => redirect(`https://www.tiktok.com/@loginqueen/video/${ID}`),
    "/app-scheme": () => redirect("snssdk1233://aweme/detail/123"),
    "/js": () => redirect("javascript:alert(1)"),
    "/bad-location": () => redirect("http://[oops"),
    "/no-location": () => new Response(null, { status: 302 }),
    "/ok-with-location": () => new Response("hi", { headers: { Location: "/elsewhere" } }),
    "/ok": () => new Response("hi"),
    "/dead": () => redirect("https://www.tiktok.com/?_r=1"),
    "/dead-bare": () => redirect("https://m.tiktok.com/"),
    "/foryou": () => redirect("https://www.tiktok.com/foryou"),
  });
  afterAll(() => stub.stop());

  const expand = async (path: string) => {
    stub.requests.length = 0;
    return resolveRedirects(stub.origin + path, local);
  };

  test("stops at the first hop outside the short-link service without fetching it", async () => {
    expect(await expand("/start")).toBe(`${stub.origin}/next`);
    expect(stub.requests).toEqual(["/start"]);
    expect(await expand("/post")).toBe(`https://www.tiktok.com/@someone/video/${ID}?_r=1&u_code=x`);
    expect(stub.requests).toEqual(["/post"]);
  });

  test("a login wall keeps the link it came from", async () => {
    expect(await expand("/ig-wall")).toBe(`${stub.origin}/ig-wall`);
    expect(await expand("/tt-wall")).toBe(`${stub.origin}/tt-wall`);
  });

  test("a handle that merely contains 'login' is not a login wall", async () => {
    expect(await expand("/login-handle")).toBe(`https://www.tiktok.com/@loginqueen/video/${ID}`);
  });

  test.each([["/app-scheme"], ["/js"], ["/bad-location"], ["/no-location"], ["/ok-with-location"], ["/ok"]])(
    "%p is not followed", async (path) => {
      expect(await expand(path)).toBe(stub.origin + path);
      expect(stub.requests).toEqual([path]);
    });

  test("a network error returns the input", async () => {
    const url = `http://127.0.0.1:${closedPort()}/t/abc`;
    expect(await resolveRedirects(url, local)).toBe(url);
  });

  test("private addresses are refused unless allowed, leaving the link as is", async () => {
    stub.requests.length = 0;
    expect(await resolveRedirects(`${stub.origin}/post`)).toBe(`${stub.origin}/post`);
    expect(stub.requests).toEqual([]);
  });

  test("a dead TikTok code (sent to the home page) is refused", async () => {
    for (const path of ["/dead", "/dead-bare"]) {
      const err = await expandShortLink(stub.origin + path, local).catch((e) => e);
      expect(err).toBeInstanceOf(BadRequest);
      expect(err.message).toContain("expired");
    }
    expect((await expandShortLink(`${stub.origin}/foryou`, local)).href).toBe("https://www.tiktok.com/foryou");
  });

  test("expandShortLink returns the post's URL, and the input when nothing expands", async () => {
    const post = await expandShortLink(`${stub.origin}/post`, local);
    expect(post).toBeInstanceOf(URL);
    expect(post.href).toBe(`https://www.tiktok.com/@someone/video/${ID}?_r=1&u_code=x`);
    expect((await expandShortLink(`${stub.origin}/ok`, local)).href).toBe(`${stub.origin}/ok`);
    await expect(expandShortLink("not a url", local)).rejects.toThrow(BadRequest);
  });
});

// Hops within the short-link service need real short-link hosts (isShortLink is host-based), so
// these swap fetch for a fake that answers as vm.tiktok.com would.
describe("short links on real hosts (fake fetch)", () => {
  let fake: ReturnType<typeof fakeFetch> | undefined;
  afterEach(() => fake?.restore());

  test("follows hops inside the short-link service, then stops at the post", async () => {
    fake = fakeFetch((url) => {
      if (url === "https://vm.tiktok.com/ZMa/") return redirect("https://www.tiktok.com/t/ZTb/", 301);
      if (url === "https://www.tiktok.com/t/ZTb/") return redirect(`https://www.tiktok.com/@x/video/${ID}?_r=1`);
      return new Response("should not be fetched", { status: 500 });
    });
    expect(await resolveRedirects("https://vm.tiktok.com/ZMa/", local)).toBe(`https://www.tiktok.com/@x/video/${ID}?_r=1`);
    expect(fake.calls.map((c) => c.url)).toEqual(["https://vm.tiktok.com/ZMa/", "https://www.tiktok.com/t/ZTb/"]);
  });

  test("gives up after 6 hops", async () => {
    fake = fakeFetch((url) => redirect(`https://vm.tiktok.com/ZM${Number(url.match(/ZM(\d+)/)![1]) + 1}/`));
    expect(await resolveRedirects("https://vm.tiktok.com/ZM0/", local)).toBe("https://vm.tiktok.com/ZM6/");
    expect(fake.calls.length).toBe(6);
  });

  test("canonical expands only real short links", async () => {
    fake = fakeFetch((url) => {
      if (url.startsWith("https://vm.tiktok.com/")) return redirect(`https://www.tiktok.com/@x/video/${ID}?_r=1&_t=abc`);
      if (url.startsWith("https://vt.tiktok.com/")) return redirect(`https://www.tiktok.com/@y/photo/${ID}`);
      if (url.startsWith("https://www.tiktok.com/t/")) return redirect(`https://m.tiktok.com/v/${ID}.html`);
      if (url.startsWith("https://tt.site/t/")) return redirect(`https://www.tiktok.com/@z/video/${ID}?_r=1`);
      if (url === "https://www.instagram.com/share/reel/BAxyz/") return redirect("https://www.instagram.com/reel/DEF/?igsh=abc");
      if (url === "https://www.instagram.com/share/p/BAwall/") return redirect("https://www.instagram.com/accounts/login/?next=x");
      return new Response("should not be fetched", { status: 500 });
    });
    const tiktok = { url: POST, platform: "tiktok" };
    expect(await canonical("https://vm.tiktok.com/ZMabc/", local)).toEqual(tiktok);
    expect(await canonical("https://vt.tiktok.com/ZSabc/", local)).toEqual(tiktok);
    expect(await canonical("https://www.tiktok.com/t/ZTabc/", local)).toEqual(tiktok);
    expect(await canonical("https://tt.site/t/ZTabc/", local)).toEqual(tiktok);
    expect(await canonical("https://www.instagram.com/share/reel/BAxyz/", local))
      .toEqual({ url: "https://www.instagram.com/reel/DEF", platform: "instagram" });
    // Behind a login wall the share link itself is the best we have.
    expect(await canonical("https://www.instagram.com/share/p/BAwall/", local))
      .toEqual({ url: "https://www.instagram.com/share/p/BAwall", platform: "instagram" });
    expect(fake.calls.length).toBe(6);

    // Not short links: no fetch.
    expect(await canonical(`https://www.tiktok.com/@a/video/${ID}`, local)).toEqual(tiktok);
    expect(await canonical("https://eviltiktok.com/t/abc", local)).toEqual({ url: "https://eviltiktok.com/t/abc", platform: "web" });
    expect(await canonical("https://tt.site/@a", local)).toEqual({ url: "https://tt.site/@a", platform: "web" });
    expect(await canonical("https://notinstagram.com/share/x", local)).toEqual({ url: "https://notinstagram.com/share/x", platform: "web" });
    expect(await canonical("https://www.instagram.com/reel/DEF/", local)).toEqual({ url: "https://www.instagram.com/reel/DEF", platform: "instagram" });
    expect(fake.calls.length).toBe(6);
  });

  test("canonical refuses what isn't a link", async () => {
    fake = fakeFetch(() => new Response("should not be fetched", { status: 500 }));
    for (const raw of ["not a url", "https://", "ftp://example.com/x"]) {
      await expect(canonical(raw, local)).rejects.toThrow(BadRequest);
    }
    expect(fake.calls.length).toBe(0);
  });
});
