import { afterAll, afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import * as dns from "node:dns/promises";
import { BlockedAddressError, BOT_UA, BROWSER_UA, contentType, isPrivateAddress, readLimited, safeFetch } from "../../src/net.ts";
import { fakeFetch, redirect, stubServer } from "./helpers.ts";

describe("isPrivateAddress", () => {
  test.each([
    // IPv4: this network, private, loopback, CGNAT, link-local (cloud metadata), IETF, benchmarking.
    "0.0.0.0", "0.1.2.3", "10.0.0.1", "10.255.255.255", "127.0.0.1", "127.8.9.10",
    "100.64.0.1", "100.127.255.255", "169.254.169.254", "169.254.0.1",
    "172.16.0.1", "172.31.255.255", "192.168.0.1", "192.168.255.255", "192.0.0.1", "198.18.0.1", "198.19.255.255",
    // Multicast, reserved, broadcast.
    "224.0.0.1", "239.255.255.250", "240.0.0.1", "255.255.255.255",
    // IPv6: unspecified, loopback, unique local, link-local, multicast.
    "::", "::1", "fc00::1", "fd12:3456::1", "FD00::1", "fe80::1", "febf::1", "FE80::abcd", "ff02::1",
    // IPv4-mapped and NAT64, dotted and hex.
    "::ffff:127.0.0.1", "::FFFF:10.0.0.1", "::ffff:169.254.169.254", "::ffff:7f00:1", "::ffff:a9fe:a9fe",
    "::ffff:c0a8:101", "::ffff:ffff:ffff", "64:ff9b::7f00:1", "64:ff9b::a00:1",
  ])("%p is private", (ip) => {
    expect(isPrivateAddress(ip)).toBe(true);
  });

  test.each([
    "1.1.1.1", "8.8.8.8", "93.184.215.14", "9.255.255.255", "11.0.0.1", "100.63.255.255", "100.128.0.1",
    "126.255.255.255", "128.0.0.1", "169.253.0.1", "169.255.0.1", "172.15.255.255", "172.32.0.1",
    "192.167.1.1", "192.169.1.1", "192.0.1.1", "198.17.0.1", "198.20.0.1", "223.255.255.255",
    "2606:4700:4700::1111", "2001:4860:4860::8888", "::ffff:1.1.1.1", "::ffff:808:808", "64:ff9b::808:808",
  ])("%p is public", (ip) => {
    expect(isPrivateAddress(ip)).toBe(false);
  });
});

describe("safeFetch (local stub)", () => {
  const stub = stubServer({
    "/ok": () => new Response("ok"),
    "/r1": () => redirect("/r2", 301),
    "/r2": () => redirect("/ok", 307),
    "/loop": () => redirect("/loop"),
    "/echo": (req) => Response.json(Object.fromEntries(req.headers)),
    "/slow": async () => {
      await Bun.sleep(1000);
      return new Response("late");
    },
  });
  afterAll(() => stub.stop());
  const local = { allowPrivateNetwork: true };

  test("refuses private targets unless allowPrivateNetwork, before connecting", async () => {
    stub.requests.length = 0;
    const port = new URL(stub.origin).port;
    for (const url of [`${stub.origin}/ok`, `http://localhost:${port}/ok`, `http://[::1]:${port}/ok`]) {
      await expect(safeFetch(url)).rejects.toBeInstanceOf(BlockedAddressError);
    }
    expect(stub.requests).toEqual([]);
    expect(await (await safeFetch(`${stub.origin}/ok`, local)).text()).toBe("ok");
  });

  test.each([["file:///etc/passwd"], ["ftp://example.com/x"], ["data:text/plain,hi"]])("refuses %p", async (url) => {
    await expect(safeFetch(url)).rejects.toBeInstanceOf(BlockedAddressError);
  });

  test("follows redirects, or returns them as-is with followRedirects: false", async () => {
    stub.requests.length = 0;
    const res = await safeFetch(`${stub.origin}/r1`, local);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("ok");
    expect(stub.requests).toEqual(["/r1", "/r2", "/ok"]);

    stub.requests.length = 0;
    const raw = await safeFetch(`${stub.origin}/r1`, { ...local, followRedirects: false });
    expect(raw.status).toBe(301);
    expect(raw.headers.get("location")).toBe("/r2");
    expect(stub.requests).toEqual(["/r1"]);
  });

  test("gives up after 6 hops", async () => {
    stub.requests.length = 0;
    await expect(safeFetch(`${stub.origin}/loop`, local)).rejects.toThrow("Too many redirects");
    expect(stub.requests.length).toBe(6);
  });

  test("sends a browser User-Agent by default; userAgent and headers override", async () => {
    const plain = await (await safeFetch(`${stub.origin}/echo`, local)).json() as Record<string, string>;
    expect(plain["user-agent"]).toBe(BROWSER_UA);
    expect(plain["accept-language"]).toBe("en-US,en");
    const bot = await (await safeFetch(`${stub.origin}/echo`, { ...local, userAgent: BOT_UA, headers: { "X-Test": "1" } }))
      .json() as Record<string, string>;
    expect(bot["user-agent"]).toBe(BOT_UA);
    expect(bot["x-test"]).toBe("1");
  });

  test("times out", async () => {
    const started = performance.now();
    const e = await safeFetch(`${stub.origin}/slow`, { ...local, timeoutMs: 50 }).catch((e) => e);
    expect(e?.name).toBe("TimeoutError");
    expect(performance.now() - started).toBeLessThan(900); // didn't wait for the 1 s response
  });
});

// Redirect hops are re-checked. The start must be a public address, so these use IP literals
// (no DNS) and a fake fetch (no network).
describe("safeFetch redirect checks (fake fetch)", () => {
  let fake: ReturnType<typeof fakeFetch> | undefined;
  afterEach(() => fake?.restore());

  test.each([
    ["http://169.254.169.254/latest/meta-data/"],
    ["http://127.0.0.1:9/admin"],
    ["http://[::1]/"],
    ["http://[::ffff:7f00:1]/"],
    ["http://localhost/"],
    ["file:///etc/passwd"],
  ])("a redirect to %p is refused before it is fetched", async (location) => {
    fake = fakeFetch(() => redirect(location));
    await expect(safeFetch("http://93.184.215.14/start")).rejects.toBeInstanceOf(BlockedAddressError);
    expect(fake.calls.map((c) => c.url)).toEqual(["http://93.184.215.14/start"]);
  });

  test("a redirect to another public address is followed", async () => {
    fake = fakeFetch((url) => (url.endsWith("/start") ? redirect("http://[2606:4700:4700::1111]/next") : new Response("done")));
    const res = await safeFetch("http://93.184.215.14/start");
    expect(await res.text()).toBe("done");
    expect(fake.calls.map((c) => c.url)).toEqual(["http://93.184.215.14/start", "http://[2606:4700:4700::1111]/next"]);
  });

  test("relative redirects resolve against the current hop", async () => {
    fake = fakeFetch((url) => (url.endsWith("/a/b") ? redirect("../c?x=1") : new Response("done")));
    await safeFetch("http://93.184.215.14/a/b");
    expect(fake.calls.map((c) => c.url)).toEqual(["http://93.184.215.14/a/b", "http://93.184.215.14/c?x=1"]);
  });
});

// Host names: resolved once, refused if any answer is private (DNS rebinding), then connected to
// at exactly the vetted address with the real Host and TLS name. DNS and fetch are both fakes.
describe("safeFetch DNS pinning (fake DNS and fetch)", () => {
  let answers: Record<string, string[]> = {};
  let lookups: string[] = [];
  let lookup: ReturnType<typeof spyOn>;
  let fake: ReturnType<typeof fakeFetch> | undefined;
  beforeEach(() => {
    answers = {};
    lookups = [];
    lookup = spyOn(dns, "lookup").mockImplementation((async (host: string, opts: { all?: boolean }) => {
      lookups.push(`${host} all=${opts?.all}`);
      if (!answers[host]) throw Object.assign(new Error(`getaddrinfo ENOTFOUND ${host}`), { code: "ENOTFOUND" });
      return answers[host].map((address) => ({ address, family: address.includes(":") ? 6 : 4 }));
    }) as unknown as typeof dns.lookup);
  });
  afterEach(() => {
    lookup.mockRestore();
    fake?.restore();
    fake = undefined;
  });

  test("https: connects to the first vetted address, with the real Host and TLS server name", async () => {
    answers["cdn.example"] = ["93.184.215.14", "93.184.215.15"];
    fake = fakeFetch(() => new Response("ok"));
    expect(await (await safeFetch("https://cdn.example:8443/a?b=1", { userAgent: BOT_UA })).text()).toBe("ok");
    expect(lookups).toEqual(["cdn.example all=true"]);
    const [call] = fake.calls;
    expect(call!.url).toBe("https://93.184.215.14:8443/a?b=1");
    expect(call!.headers.get("host")).toBe("cdn.example:8443");
    expect(call!.headers.get("user-agent")).toBe(BOT_UA);
    expect(call!.init.tls).toEqual({ serverName: "cdn.example" });
  });

  test("http: no TLS name; IPv6 answers are bracketed", async () => {
    answers["v6.example"] = ["2606:4700:4700::1111"];
    fake = fakeFetch(() => new Response("ok"));
    await safeFetch("http://v6.example/x");
    expect(fake.calls[0]!.url).toBe("http://[2606:4700:4700::1111]/x");
    expect(fake.calls[0]!.headers.get("host")).toBe("v6.example");
    expect(fake.calls[0]!.init.tls).toBeUndefined();
  });

  test.each([
    [["93.184.215.14", "127.0.0.1"]],
    [["10.0.0.1"]],
    [["169.254.169.254"]],
    [["93.184.215.14", "fd00::1"]],
    [["::1"]],
    [["::ffff:7f00:1"]],
    [[]],
  ])("a name resolving to %p is refused before connecting", async (ips) => {
    answers["rebind.example"] = ips;
    fake = fakeFetch(() => new Response("should not be fetched"));
    await expect(safeFetch("https://rebind.example/")).rejects.toBeInstanceOf(BlockedAddressError);
    expect(fake.calls).toEqual([]);
  });

  test("a name that doesn't resolve fails before connecting", async () => {
    fake = fakeFetch(() => new Response("should not be fetched"));
    await expect(safeFetch("https://nowhere.example/")).rejects.toThrow("ENOTFOUND");
    expect(fake.calls).toEqual([]);
  });

  test("every redirect hop is resolved and vetted again", async () => {
    answers["a.example"] = ["93.184.215.14"];
    answers["b.example"] = ["2606:4700:4700::1111"];
    answers["internal.example"] = ["10.1.2.3"];
    fake = fakeFetch((url) => (url.includes("93.184.215.14") ? redirect("https://b.example/next") : redirect("http://internal.example/admin")));
    await expect(safeFetch("https://a.example/start")).rejects.toBeInstanceOf(BlockedAddressError);
    expect(lookups).toEqual(["a.example all=true", "b.example all=true", "internal.example all=true"]);
    expect(fake.calls.map((c) => [c.url, c.headers.get("host"), c.init.tls?.serverName])).toEqual([
      ["https://93.184.215.14/start", "a.example", "a.example"],
      ["https://[2606:4700:4700::1111]/next", "b.example", "b.example"],
    ]);
  });
});

describe("readLimited", () => {
  const stream = (chunks: number[][]) => new Response(new ReadableStream<Uint8Array>({
    start(c) {
      for (const chunk of chunks) c.enqueue(Uint8Array.from(chunk));
      c.close();
    },
  }));

  test.each([
    [[[1, 2, 3, 4, 5, 6]], 4, [1, 2, 3, 4]],
    [[[1, 2, 3], [4, 5, 6], [7, 8, 9]], 5, [1, 2, 3, 4, 5]],
    [[[1, 2, 3], [4, 5, 6]], 6, [1, 2, 3, 4, 5, 6]],
    [[[1, 2], [3]], 100, [1, 2, 3]],
    [[[1, 2, 3]], 0, []],
    [[], 10, []],
  ])("chunks %p, limit %p -> %p", async (chunks, limit, want) => {
    expect(Array.from(await readLimited(stream(chunks), limit))).toEqual(want);
  });

  test("no body", async () => {
    expect((await readLimited(new Response(null), 10)).length).toBe(0);
  });

  test("stops reading an endless body at the limit", async () => {
    let cancelled = false;
    let pulls = 0;
    const endless = new ReadableStream<Uint8Array>({
      pull(c) {
        pulls++;
        // "Endless" up to 1000 chunks, so a regression fails the test instead of hanging it.
        if (pulls > 1000) c.close();
        else c.enqueue(new Uint8Array(1000).fill(7));
      },
      cancel() {
        cancelled = true;
      },
    });
    const out = await readLimited(new Response(endless), 2500);
    expect(out.length).toBe(2500);
    expect(out.every((b) => b === 7)).toBe(true);
    expect(cancelled).toBe(true);
    expect(pulls).toBeLessThan(10);
  });
});

describe("contentType", () => {
  test.each([
    ["text/html; charset=utf-8", "text/html"],
    ["IMAGE/PNG", "image/png"],
    ["  image/jpeg ; q=1", "image/jpeg"],
    ["image/webp", "image/webp"],
  ])("%p -> %p", (header, want) => {
    expect(contentType(new Response(null, { headers: { "Content-Type": header } }))).toBe(want);
  });

  test("missing header", () => {
    expect(contentType(new Response(null))).toBe("");
  });
});
