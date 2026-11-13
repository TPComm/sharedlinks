import type { Database } from "bun:sqlite";
import { rmSync } from "node:fs";
import { join } from "node:path";
import { BOT_UA, BROWSER_UA, contentType, readLimited, safeFetch, type FetchOptions } from "./net.ts";
import { clip } from "./links.ts";

export interface Preview {
  title?: string | null;
  author?: string | null;
  image?: string | null;
}

// Named entities that show up in real titles and descriptions (case-sensitive, as in HTML).
const ENTITIES: Record<string, string> = {
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
};

export function decodeEntities(s: string): string {
  return s.replace(/&(#[xX][0-9a-fA-F]{1,6}|#\d{1,7}|[A-Za-z][A-Za-z0-9]{1,31});/g, (whole, name: string) => {
    if (name[0] === "#") {
      const code = name[1] === "x" || name[1] === "X" ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10);
      return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : whole;
    }
    return ENTITIES[name] ?? ENTITIES[name.toLowerCase()] ?? whole;
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

export async function fetchPreview(url: string, platform: string, opts: FetchOptions = {}): Promise<Preview> {
  const endpoint = OEMBED[platform];
  if (endpoint) {
    try {
      const d = JSON.parse(await getText(endpoint + encodeURIComponent(url), opts));
      if (d.title || d.thumbnail_url) return { title: d.title, author: d.author_name, image: d.thumbnail_url };
      // TikTok's oEmbed now often returns only the embed iframe; fall back to the page's tags.
    } catch (e) {
      if (platform === "youtube") throw e;
    }
  }
  const ua = BOT_ONLY.has(platform) ? BOT_UA : BROWSER_UA;
  return previewFromTags(platform, ogTags(await getText(url, { ...opts, userAgent: ua })));
}

/** Turn a page's Open Graph tags into a preview, with per-site clean-up. */
export function previewFromTags(platform: string, og: Record<string, string>): Preview {
  let title: string | null = og["og:title"] || og["twitter:title"] || og.title || null;
  const desc = og["og:description"] || og.description || "";
  let author: string | null = null;
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
  return { title, author: author || og["og:site_name"] || null, image: og["og:image"] || og["twitter:image"] || null };
}

/** Fetch a link's title, creator and thumbnail in the background, then store them. */
export async function fetchMetadata(db: Database, dataDir: string, linkId: number, url: string, platform: string,
                                    opts: FetchOptions = {}) {
  let meta: Preview = {};
  try {
    meta = await fetchPreview(url, platform, opts);
  } catch (e) {
    console.error(`preview failed for ${url}: ${e}`);
  }
  let thumbType: string | null = null;
  if (meta.image) {
    try {
      const res = await safeFetch(new URL(meta.image, url), opts);
      const type = contentType(res);
      if (res.ok && type.startsWith("image/")) {
        await Bun.write(join(dataDir, "thumbs", String(linkId)), await readLimited(res, 6_000_000));
        thumbType = type;
      } else {
        await res.body?.cancel();
      }
    } catch (e) {
      console.error(`thumbnail failed for ${url}: ${e}`);
    }
  }
  const title = clip(meta.title, 300) || null;
  const author = clip(meta.author, 80) || null;
  const { changes } = db.run("UPDATE links SET title = ?, author = ?, thumb_type = ?, meta = ? WHERE id = ?",
    [title, author, thumbType, title || thumbType ? "done" : "failed", linkId]);
  // Deleted while we were fetching: don't leave its thumbnail behind.
  if (!changes && thumbType) rmSync(join(dataDir, "thumbs", String(linkId)), { force: true });
}
