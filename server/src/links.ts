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

/**
 * Every path TikTok uses for one post: /@handle/video/ID, /@handle/photo/ID, /v/ID.html,
 * /share/video/ID, /embed/v2/ID. The id is all TikTok needs. The handle is often stale, or
 * empty in links that come from short links.
 */
const TIKTOK_POST = /^\/(?:@[^/]*\/(?:video|photo)|v|share\/video|embed(?:\/v2)?)\/(\d{8,20})(?:\.html)?\/?$/;

/** Share short links (vm.tiktok.com/..., tiktok.com/t/..., instagram.com/share/...). */
function isShortLink(url: URL): boolean {
  const host = url.hostname.toLowerCase();
  const path = url.pathname;
  return host === "vm.tiktok.com" || host === "vt.tiktok.com" ||
    ((onDomain(host, "tiktok.com") || onDomain(host, "tt.site")) && path.startsWith("/t/")) ||
    (onDomain(host, "instagram.com") && path.startsWith("/share/"));
}

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
    // Out of the short-link service means we've reached the post. Fetching it too would only
    // download the page (~400 KB for TikTok).
    if (!isShortLink(next)) return url;
  }
  return url;
}

/** Follow a share short link to the post it points at. */
export async function expandShortLink(raw: string, opts: FetchOptions = {}): Promise<URL> {
  const expanded = parse(await resolveRedirects(raw, opts));
  // A dead or expired TikTok code redirects to the home page (/?_r=1). Don't save the home page
  // as the link: it isn't the video, and every dead link would count as a duplicate of it.
  if (platformOf(expanded.hostname) === "tiktok" && expanded.pathname === "/") {
    throw new BadRequest("That TikTok link has expired. Copy a fresh one from TikTok.");
  }
  return expanded;
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
  const parts = parse(raw);
  return normalize(isShortLink(parts) ? await expandShortLink(raw, opts) : parts);
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
  } else if (platform === "tiktok") {
    // TikTok's query string is all tracking (_t, _r, is_from_webapp, ...), so it goes. Posts get
    // one spelling: /@/video/ID opens in the browser and the app, oEmbed accepts it (it refuses
    // /photo/), and it is what short links expand to.
    const id = path.match(TIKTOK_POST)?.[1];
    if (id) path = `/@/video/${id}`;
  } else {
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
