import type { Database } from "bun:sqlite";
import { renameSync, rmSync } from "node:fs";
import { join } from "node:path";
import { BOT_UA, BROWSER_UA, contentType, readLimited, safeFetch, type FetchOptions } from "./net.ts";
import { clip } from "./links.ts";
import type { LinkRow } from "./db.ts";

export interface Preview {
  title?: string | null;
  author?: string | null;
  image?: string | null;
  description?: string | null;
  siteName?: string | null;
  imageWidth?: number | null;
  imageHeight?: number | null;
}

/** Bump to have the server re-fetch every link's preview (rate-limited) on its next start. */
export const PREVIEW_VERSION = 2;

const SITE_NAMES: Record<string, string> = {
  instagram: "Instagram", tiktok: "TikTok", youtube: "YouTube", facebook: "Facebook", reddit: "Reddit", x: "X",
};

// Named entities that show up in real titles and descriptions (case-sensitive, as in HTML).
// A Map, so "&constructor;" on a hostile page doesn't find Object.prototype.constructor.
const ENTITIES = new Map(Object.entries({
  amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ",
  mdash: "—", ndash: "–", hellip: "…", bull: "•", middot: "·", laquo: "«", raquo: "»",
  lsquo: "‘", rsquo: "’", sbquo: "‚", ldquo: "“", rdquo: "”", bdquo: "„", prime: "′",
  copy: "©", reg: "®", trade: "™", deg: "°", times: "×", divide: "÷", plusmn: "±", micro: "µ",
  para: "¶", sect: "§", euro: "€", pound: "£", yen: "¥", cent: "¢", iexcl: "¡", iquest: "¿",
  agrave: "à", aacute: "á", acirc: "â", atilde: "ã", auml: "ä", aring: "å", aelig: "æ", ccedil: "ç",
  egrave: "è", eacute: "é", ecirc: "ê", euml: "ë", igrave: "ì", iacute: "í", icirc: "î", iuml: "ï",
  ntilde: "ñ", ograve: "ò", oacute: "ó", ocirc: "ô", otilde: "õ", ouml: "ö", oslash: "ø",
  ugrave: "ù", uacute: "ú", ucirc: "û", uuml: "ü", yacute: "ý", yuml: "ÿ", szlig: "ß",
  Agrave: "À", Aacute: "Á", Acirc: "Â", Atilde: "Ã", Auml: "Ä", Aring: "Å", AElig: "Æ", Ccedil: "Ç",
  Egrave: "È", Eacute: "É", Ecirc: "Ê", Euml: "Ë", Igrave: "Ì", Iacute: "Í", Icirc: "Î", Iuml: "Ï",
  Ntilde: "Ñ", Ograve: "Ò", Oacute: "Ó", Ocirc: "Ô", Otilde: "Õ", Ouml: "Ö", Oslash: "Ø",
  Ugrave: "Ù", Uacute: "Ú", Ucirc: "Û", Uuml: "Ü", Yacute: "Ý",
}));

export function decodeEntities(s: string): string {
  return s.replace(/&(#[xX][0-9a-fA-F]{1,6}|#\d{1,7}|[A-Za-z][A-Za-z0-9]{1,31});/g, (whole, name: string) => {
    if (name[0] === "#") {
      const code = name[1] === "x" || name[1] === "X" ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10);
      return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : whole;
    }
    return ENTITIES.get(name) ?? ENTITIES.get(name.toLowerCase()) ?? whole;
  });
}

/**
 * Open Graph / Twitter / <title> tags, first value wins.
 *
 * The page is attacker-controlled, so every pattern here must run in linear time: tags can't run
 * past the next "<", and an attribute name can only start at the beginning of a word.
 */
export function ogTags(html: string): Record<string, string> {
  const page = headOf(html);
  const tags: Record<string, string> = {};
  for (const [meta] of page.matchAll(/<meta\b[^<>]*>/gi)) {
    const attrs: Record<string, string> = {};
    for (const m of meta.matchAll(/(?<![\w:-])([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)) {
      attrs[m[1]!.toLowerCase()] = decodeEntities(m[2] ?? m[3] ?? "");
    }
    const key = (attrs.property ?? attrs.name)?.toLowerCase();
    if (key && "content" in attrs && !(key in tags)) tags[key] = attrs.content!;
  }
  const title = page.match(/<title\b[^<>]*>([^<]*)<\/title>/i);
  if (title && !("title" in tags)) tags.title = decodeEntities(title[1]!).trim();
  return tags;
}

/** Previews only need the <head>: cut there (or at 512 KB) before any parsing. */
function headOf(html: string): string {
  const end = html.search(/<\/head\s*>/i);
  return html.slice(0, Math.min(end === -1 ? html.length : end, 512 * 1024));
}

async function getText(url: string, opts: FetchOptions): Promise<string> {
  const res = await safeFetch(url, opts);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return new TextDecoder().decode(await readLimited(res, 2_000_000));
}

const OEMBED: Record<string, string> = {
  tiktok: "https://www.tiktok.com/oembed?url=",
  youtube: "https://www.youtube.com/oembed?format=json&url=",
};

/** Sites that only show Open Graph tags to link-preview bots. */
const BOT_ONLY = new Set(["instagram", "facebook", "tiktok"]);

function redditTitle(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const shell = /^(?:reddit(?:\s*[-–—:|]\s*the heart of the internet)?|welcome to reddit|(?:log\s*in|sign\s*in|sign\s*up)(?:\s*\/\s*sign\s*up)?(?:\s+(?:to|for)\s+reddit)?|reddit\s*[-–—:|]\s*(?:log\s*in|sign\s*in|sign\s*up))\s*[.!]?$/i;
  return shell.test(value.trim()) ? null : value;
}

export async function fetchPreview(url: string, platform: string, opts: FetchOptions = {}): Promise<Preview> {
  if (platform === "reddit") {
    let page: Preview = {};
    let embed: Preview = {};
    try {
      page = previewFromTags(platform, ogTags(await getText(url, { ...opts, userAgent: BOT_UA })));
    } catch {}
    try {
      const d = JSON.parse(await getText("https://www.reddit.com/oembed?url=" + encodeURIComponent(url), opts));
      embed = { title: d.title, author: d.author_name, image: d.thumbnail_url };
    } catch {}
    return { ...page, ...stripEmpty(embed), title: redditTitle(embed.title) || redditTitle(page.title) };
  }
  const endpoint = OEMBED[platform];
  if (endpoint) {
    try {
      const d = JSON.parse(await getText(endpoint + encodeURIComponent(url), opts));
      if (d.title || d.thumbnail_url) {
        return {
          title: d.title, author: d.author_name, image: d.thumbnail_url, siteName: d.provider_name,
          imageWidth: dimension(d.thumbnail_width), imageHeight: dimension(d.thumbnail_height),
        };
      }
      // TikTok's oEmbed now often returns only the embed iframe; fall back to the page's tags.
    } catch (e) {
      if (platform === "youtube") throw e;
    }
  }
  const ua = BOT_ONLY.has(platform) ? BOT_UA : BROWSER_UA;
  if (platform !== "instagram") return previewFromTags(platform, ogTags(await getText(url, { ...opts, userAgent: ua })));
  // Instagram often answers bots from server IPs with a bare login page: use the public embed page then.
  let page: Preview = {};
  let error: unknown = null;
  try {
    page = previewFromTags(platform, ogTags(await getText(url, { ...opts, userAgent: ua })));
    if (page.title && page.image) return page;
  } catch (e) {
    error = e;
  }
  const embed = instagramEmbedUrl(url);
  if (embed) {
    try {
      const e = instagramFromEmbed(await getText(embed, { ...opts, userAgent: BROWSER_UA }));
      if (e.title || e.image) return { ...page, ...stripEmpty(e) };
    } catch (e) {
      error ??= e;
    }
  }
  if (error && !page.title && !page.image) throw error;
  return page;
}

const stripEmpty = (p: Preview): Preview =>
  Object.fromEntries(Object.entries(p).filter(([, v]) => v != null && v !== "")) as Preview;

function dimension(v: unknown): number | null {
  const n = typeof v === "string" ? Number(v.trim()) : v;
  return typeof n === "number" && Number.isInteger(n) && n > 0 && n <= 100_000 ? n : null;
}

/** https://www.instagram.com/reel/<code>/embed/captioned/ for a post or reel, else null. */
export function instagramEmbedUrl(url: string): string | null {
  const m = new URL(url).pathname.match(/^\/(?:[\w.]+\/)?(reels?|p|tv)\/([\w-]+)/);
  return m ? `https://www.instagram.com/${m[1] === "reels" ? "reel" : m[1]}/${m[2]}/embed/captioned/` : null;
}

const stripTags = (html: string) =>
  decodeEntities(html.replace(/<br\s*\/?>/gi, "\n").replace(/<[^<>]*>/g, ""))
    .split("\n").map((line) => line.replace(/\s+/g, " ").trim()).join("\n").replace(/\n{3,}/g, "\n\n").trim();

/** Instagram's embed page: the media image, the @handle and the caption. */
export function instagramFromEmbed(html: string): Preview {
  const page = html.slice(0, 2_000_000);
  let image: string | null = null;
  for (const [tag] of page.matchAll(/<img\b[^<>]*>/gi)) {
    if (!/class\s*=\s*["'][^"']*\bEmbeddedMediaImage\b/i.test(tag)) continue;
    const src = tag.match(/(?<![\w-])src\s*=\s*(?:"([^"]*)"|'([^']*)')/i);
    if (src) image = decodeEntities(src[1] ?? src[2] ?? "");
    break;
  }
  const user = page.match(/class\s*=\s*["'][^"']*\bUsernameText\b[^"']*["'][^<>]*>([^<]*)</i);
  const handle = user ? decodeEntities(user[1]!).trim().replace(/^@/, "") : "";
  let title: string | null = null;
  const start = page.search(/<div\b[^<>]*class\s*=\s*["']Caption["'][^<>]*>/i);
  if (start !== -1) {
    let body = page.slice(start, start + 20_000);
    const end = body.search(/<div\b[^<>]*class\s*=\s*["'][^"']*\bCaptionComments\b/i);
    if (end !== -1) body = body.slice(0, end);
    // The caption starts with the poster's handle as a link: drop it.
    body = body.replace(/<a\b[^<>]*class\s*=\s*["'][^"']*\bCaptionUsername\b[^<>]*>[^<]*<\/a>/i, "");
    title = stripTags(body) || null;
  }
  return { title, author: handle ? `@${handle}` : null, image, siteName: "Instagram" };
}

/** Turn a page's Open Graph tags into a preview, with per-site clean-up. */
export function previewFromTags(platform: string, og: Record<string, string>): Preview {
  let title: string | null = og["og:title"] || og["twitter:title"] || og.title || null;
  const desc = og["og:description"] || og["twitter:description"] || og.description || "";
  let description: string | null = desc.trim() || null;
  let author: string | null = null;
  let loginWall = false;
  if (platform === "instagram") {
    // og:title looks like: Name on Instagram: "caption"
    // og:description like: 12K likes, 40 comments - handle on May 1, 2025: "caption"
    const handle = desc.match(/-\s+([\w.]+)\s+on\s+\w+ \d/);
    author = handle ? `@${handle[1]}` : null;
    const m = (title ?? "").match(/^(.*?) on Instagram: ["“]([\s\S]*)["”]\s*$/);
    if (m) {
      author ??= m[1]!;
      title = m[2]!;
    } else if (title?.trim().toLowerCase() === "instagram") {
      title = null;
    }
    // Keep only the engagement counts: the caption is the title, the handle the author.
    const counts = desc.match(/^\s*([^-]*?\b(?:likes?|comments?|views?|plays?)\b[^-]*?)\s+-\s/i);
    description = counts ? counts[1]!.trim() : null;
    // A login wall, not the post: its og:image is Instagram's logo and its og:site_name isn't the poster.
    loginWall = !title && !handle && !counts;
    if (loginWall) description = null;
  } else if (platform === "tiktok") {
    // og:title looks like: TikTok · Creator Name   (the caption, when there is one, is og:description)
    const m = (title ?? "").match(/^TikTok\s*[·|\-–]\s*(.+)$/);
    if (m) {
      author = m[1]!.trim();
      title = desc.trim() || null;
    } else if (title?.trim().toLowerCase() === "tiktok") {
      title = null;
    }
  }
  if (description && description === title?.trim()) description = null;
  const image = loginWall ? null : og["og:image"] || og["og:image:url"] || og["og:image:secure_url"] || og["twitter:image"] || null;
  const fromOg = image && (og["og:image"] || og["og:image:url"] || og["og:image:secure_url"]);
  return {
    title,
    author: author || (loginWall ? null : og["og:site_name"]) || null,
    image,
    description,
    siteName: og["og:site_name"] || SITE_NAMES[platform] || null,
    imageWidth: fromOg ? dimension(og["og:image:width"]) : null,
    imageHeight: fromOg ? dimension(og["og:image:height"]) : null,
  };
}

/** Pixel size of a PNG, GIF, JPEG or WebP, read from its header. */
export function imageSize(b: Uint8Array): { width: number; height: number } | null {
  const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
  const ok = (w: number, h: number) => (w > 0 && h > 0 ? { width: w, height: h } : null);
  const ascii = (at: number, s: string) => [...s].every((c, i) => b[at + i] === c.charCodeAt(0));
  if (b.length >= 24 && b[0] === 0x89 && ascii(1, "PNG") && ascii(12, "IHDR")) return ok(v.getUint32(16), v.getUint32(20));
  if (b.length >= 10 && ascii(0, "GIF8")) return ok(v.getUint16(6, true), v.getUint16(8, true));
  if (b.length >= 30 && ascii(0, "RIFF") && ascii(8, "WEBP")) {
    const u24 = (at: number) => b[at]! | (b[at + 1]! << 8) | (b[at + 2]! << 16);
    if (ascii(12, "VP8X")) return ok(1 + u24(24), 1 + u24(27));
    if (ascii(12, "VP8 ")) return ok(v.getUint16(26, true) & 0x3fff, v.getUint16(28, true) & 0x3fff);
    if (ascii(12, "VP8L")) {
      const bits = v.getUint32(21, true);
      return ok((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1);
    }
    return null;
  }
  if (b.length >= 4 && b[0] === 0xff && b[1] === 0xd8) {
    let i = 2;
    let rotated = false;
    while (i + 9 < b.length) {
      if (b[i] !== 0xff) return null;
      const marker = b[i + 1]!;
      if (marker === 0xff) { i++; continue; }
      if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) { i += 2; continue; }
      const len = v.getUint16(i + 2);
      // Start-of-frame markers (not DHT, JPG or DAC) carry the size.
      if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
        const [w, h] = [v.getUint16(i + 7), v.getUint16(i + 5)];
        return rotated ? ok(h, w) : ok(w, h);
      }
      if (len < 2) return null;
      if (marker === 0xe1 && ascii(i + 4, "Exif\0\0")) rotated = exifOrientation(v, i + 10) >= 5;
      i += 2 + len;
    }
  }
  return null;
}

/** The EXIF Orientation tag of the TIFF block at `t` (1 when absent); 5-8 mean the image displays turned 90°. */
function exifOrientation(v: DataView, t: number): number {
  try {
    const le = v.getUint16(t) === 0x4949;
    const ifd = t + v.getUint32(t + 4, le);
    const count = v.getUint16(ifd, le);
    for (let e = ifd + 2; e < ifd + 2 + count * 12; e += 12) {
      if (v.getUint16(e, le) === 0x0112) return v.getUint16(e + 8, le);
    }
  } catch {
    // Truncated EXIF: treat as unrotated.
  }
  return 1;
}

/**
 * Fetch a link's title, creator, description and thumbnail in the background, then store them.
 * A re-fetch that comes back with less keeps what the link already had.
 */
export async function fetchMetadata(db: Database, dataDir: string, linkId: number, url: string, platform: string,
                                    opts: FetchOptions = {}) {
  let meta: Preview = {};
  try {
    meta = await fetchPreview(url, platform, opts);
  } catch (e) {
    console.error(`preview failed for ${url}: ${e}`);
  }
  const thumbPath = join(dataDir, "thumbs", String(linkId));
  let thumb: { type: string; width: number | null; height: number | null } | null = null;
  if (meta.image) {
    try {
      const res = await safeFetch(new URL(meta.image, url), opts);
      const type = contentType(res);
      if (res.ok && type.startsWith("image/")) {
        const bytes = await readLimited(res, 6_000_000);
        const size = imageSize(bytes);
        await Bun.write(`${thumbPath}.part`, bytes);
        thumb = { type, width: size?.width ?? meta.imageWidth ?? null, height: size?.height ?? meta.imageHeight ?? null };
      } else {
        await res.body?.cancel();
      }
    } catch (e) {
      console.error(`thumbnail failed for ${url}: ${e}`);
    }
  }
  const old = db.query("SELECT * FROM links WHERE id = ?").get(linkId) as LinkRow | null;
  if (!old) {
    rmSync(`${thumbPath}.part`, { force: true });
    return;
  }
  if (thumb) renameSync(`${thumbPath}.part`, thumbPath);
  const title = clip(meta.title, 300) || (platform === "reddit" ? redditTitle(old.title) : old.title) || null;
  const author = clip(meta.author, 80) || old.author || null;
  const description = clip(meta.description, 1000) || old.description || null;
  const siteName = clip(meta.siteName, 80) || old.site_name || null;
  const thumbType = thumb?.type ?? old.thumb_type;
  const [w, h] = thumb ? [thumb.width, thumb.height] : [old.thumb_w, old.thumb_h];
  const { changes } = db.run(
    `UPDATE links SET title = ?, author = ?, description = ?, site_name = ?, thumb_type = ?, thumb_w = ?, thumb_h = ?,
       meta = ?, preview_v = ?, thumb_v = thumb_v + ? WHERE id = ?`,
    [title, author, description, siteName, thumbType, w, h, title || thumbType ? "done" : "failed", PREVIEW_VERSION, thumb ? 1 : 0, linkId]);
  // Deleted while we were fetching: don't leave its thumbnail behind.
  if (!changes && thumb) rmSync(thumbPath, { force: true });
}
