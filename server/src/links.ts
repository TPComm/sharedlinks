import { safeFetch, type FetchOptions } from "./net.ts";

export class BadRequest extends Error {}

const URL_RE = /https?:\/\/[^\s<>"']+/i;
const BARE_RE = /\b(?:[\w-]+\.)+[a-z]{2,}\/[^\s<>"']*/i;
const TRACKING_RE = /^(utm_\w+|igsh|igshid|fbclid|gclid|si|feature|ref|ref_src|s)$/;

export const PLATFORMS: Record<string, string[]> = {
  tiktok: ["tiktok.com"],
  instagram: ["instagram.com", "instagr.am"],
  youtube: ["youtube.com", "youtu.be"],
  x: ["x.com", "twitter.com"],
  reddit: ["reddit.com", "redd.it"],
  facebook: ["facebook.com", "fb.watch"],
};

/** Pull the first link out of whatever was pasted ("lol look https://..."). */
export function extractUrl(text: unknown): string | null {
  const s = String(text ?? "");
  const m = s.match(URL_RE) ?? s.match(BARE_RE);
  if (!m) return null;
  // Trailing punctuation and closing brackets/quotes belong to the message, not the link.
  const url = m[0].replace(/[).,!?;:'"\]}`>]+$/, "");
  return /^http/i.test(url) ? url : `https://${url}`;
}

/** host is domain or a subdomain of it ("m.tiktok.com" yes, "eviltiktok.com" no). */
const onDomain = (host: string, domain: string) => host === domain || host.endsWith(`.${domain}`);

export function platformOf(host: string): string {
  for (const [name, domains] of Object.entries(PLATFORMS)) {
    if (domains.some((d) => onDomain(host, d))) return name;
  }
  return "web";
}

/** Expand share short-links (vm.tiktok.com/..., instagram.com/share/...). */
export async function resolveRedirects(url: string, opts: FetchOptions = {}): Promise<string> {
  for (let hop = 0; hop < 6; hop++) {
    let res: Response;
    try {
      res = await safeFetch(url, { ...opts, followRedirects: false, timeoutMs: 6000 });
    } catch {
      return url;
    }
    await res.body?.cancel();
    const location = res.headers.get("location");
    if (res.status < 300 || res.status >= 400 || !location) return url;
    let next: URL;
    try {
      next = new URL(location, url);
    } catch {
      return url;
    }
    // Only follow to web pages, and stop at a login wall: the short link is the best we have.
    if (next.protocol !== "https:" && next.protocol !== "http:") return url;
    if (next.pathname.includes("login")) return url;
    url = next.toString();
  }
  return url;
}

function parse(url: string): URL {
  try {
    return new URL(url);
  } catch {
    throw new BadRequest("That doesn't look like a link.");
  }
}

/** Normalise a link so the same video shared twice is detected as a duplicate. */
export async function canonical(raw: string, opts: FetchOptions = {}): Promise<{ url: string; platform: string }> {
  let parts = parse(raw);
  const host = parts.hostname.toLowerCase();
  const path = parts.pathname;
  if (
    host === "vm.tiktok.com" || host === "vt.tiktok.com" ||
    (onDomain(host, "tiktok.com") && path.startsWith("/t/")) ||
    (onDomain(host, "instagram.com") && path.startsWith("/share/"))
  ) {
    parts = parse(await resolveRedirects(raw, opts));
  }
  return normalize(parts);
}

/**
 * The offline part of canonical(): one spelling per link. Also used to re-spell links stored by
 * older versions (see db.ts), so keep it deterministic.
 */
export function normalize(parts: URL): { url: string; platform: string } {
  if (parts.protocol !== "https:" && parts.protocol !== "http:") throw new BadRequest("That doesn't look like a link.");
  let host = parts.hostname.toLowerCase();
  // WHATWG URL already lowercased and punycoded the host. Anything else (e.g. "example.com}")
  // is something iOS can't parse, which would break the inbox for everyone.
  if (!/^[a-z0-9_.-]+$/.test(host) && !/^\[[0-9a-f:.]+\]$/.test(host)) {
    throw new BadRequest("That doesn't look like a link.");
  }
  let path = parts.pathname;

  const platform = platformOf(host);
  let query = "";
  if (platform === "instagram") {
    path = path.replace(/^\/reels\//, "/reel/").replace(/^\/[^/]+\/(reel|p)\//, "/$1/"); // /username/reel/ID -> /reel/ID
  } else if (platform !== "tiktok") {
    const params = new URLSearchParams(parts.search);
    for (const key of [...params.keys()]) if (TRACKING_RE.test(key)) params.delete(key);
    query = params.toString();
  }
  // One spelling per site (TikTok's oEmbed only accepts www.tiktok.com).
  const bare = host.replace(/^www\./, "").replace(/^m\./, "");
  if (["tiktok.com", "instagram.com", "youtube.com", "facebook.com", "reddit.com"].includes(bare)) host = `www.${bare}`;
  path = path.replace(/\/+$/, "") || "/";
  // WHATWG leaves [ ] | and a stray % raw in paths; RFC 3986 (and so Foundation's URL) doesn't
  // allow them, and iOS would then re-escape the whole path, including valid %XX escapes.
  path = path.replace(/[[\]|]|%(?![0-9A-Fa-f]{2})/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase().padStart(2, "0")}`);
  const scheme = platform === "web" ? parts.protocol.replace(":", "").toLowerCase() : "https";
  const netloc = host + (parts.port ? `:${parts.port}` : "");
  return { url: `${scheme}://${netloc}${path}${query ? `?${query}` : ""}`, platform };
}

/** Collapse whitespace, trim, and cut to `max` characters (not UTF-16 units). */
export function clip(value: unknown, max: number): string {
  return Array.from(String(value ?? "").replace(/\s+/g, " ").trim()).slice(0, max).join("");
}

/** Like clip() but keeps line breaks (for notes). */
export function clipText(value: unknown, max: number): string {
  return Array.from(String(value ?? "").trim()).slice(0, max).join("");
}
