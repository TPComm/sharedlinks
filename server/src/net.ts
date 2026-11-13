import { lookup } from "node:dns/promises";
import { isIP } from "node:net";

export const BROWSER_UA =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 " +
  "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
/** Instagram only serves Open Graph tags (title, thumbnail) to link-preview bots. */
export const BOT_UA = "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)";

export class BlockedAddressError extends Error {}

/** Loopback, private, link-local (cloud metadata lives at 169.254.169.254), CGNAT, multicast, reserved. */
export function isPrivateAddress(ip: string): boolean {
  const v4 = ip.match(/^(?:::ffff:)?(\d+)\.(\d+)\.(\d+)\.(\d+)$/i);
  if (v4) {
    const [a, b] = [Number(v4[1]), Number(v4[2])];
    return (
      a === 0 || a === 10 || a === 127 || a >= 224 ||
      (a === 100 && b >= 64 && b <= 127) ||
      (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && b === 168) ||
      (a === 192 && b === 0 && Number(v4[3]) === 0) ||
      (a === 198 && (b === 18 || b === 19))
    );
  }
  const v6 = ip.toLowerCase();
  if (v6 === "::" || v6 === "::1") return true;
  if (/^f[cd]/.test(v6)) return true; // fc00::/7 unique local
  if (/^fe[89ab]/.test(v6)) return true; // fe80::/10 link-local
  if (/^ff/.test(v6)) return true; // multicast
  const mapped = v6.match(/^(?:::ffff:|64:ff9b::)([0-9a-f]{1,4}):([0-9a-f]{1,4})$/);
  if (mapped) {
    const n = (parseInt(mapped[1]!, 16) << 16) | parseInt(mapped[2]!, 16);
    return isPrivateAddress([n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255].join("."));
  }
  return false;
}

/** Resolve the host once and check every answer; returns the address to connect to. */
async function vettedAddress(url: URL): Promise<string> {
  if (url.protocol !== "http:" && url.protocol !== "https:") throw new BlockedAddressError(`Not a web URL: ${url}`);
  const host = url.hostname.replace(/^\[|\]$/g, "");
  const addresses = isIP(host) ? [host] : (await lookup(host, { all: true })).map((a) => a.address);
  if (!addresses.length || addresses.some(isPrivateAddress)) {
    throw new BlockedAddressError(`Refusing to fetch private address for ${url.hostname}`);
  }
  return addresses[0]!;
}

/**
 * Connect to exactly the address that was checked. Letting fetch() resolve the name again would
 * allow DNS rebinding (public IP for the check, 127.0.0.1 or 169.254.169.254 for the connection).
 * For https, TLS still verifies the certificate against the real hostname via serverName.
 */
async function pinnedRequest(url: URL, headers: Record<string, string>): Promise<[URL, RequestInit]> {
  const ip = await vettedAddress(url);
  const host = url.hostname.replace(/^\[|\]$/g, "");
  if (isIP(host)) return [url, { headers }];
  const target = new URL(url);
  target.hostname = ip.includes(":") ? `[${ip}]` : ip;
  const init: RequestInit & { tls?: { serverName: string } } = { headers: { ...headers, Host: url.host } };
  if (url.protocol === "https:") init.tls = { serverName: host };
  return [target, init];
}

export interface FetchOptions {
  userAgent?: string;
  timeoutMs?: number;
  /** Follow redirects (each hop is re-checked). With false, 3xx responses are returned as-is. */
  followRedirects?: boolean;
  allowPrivateNetwork?: boolean;
  headers?: Record<string, string>;
}

/**
 * fetch() for user-submitted URLs: refuses private/internal addresses (so a link can't make
 * the server probe its own network or the cloud metadata service) and checks every redirect hop.
 */
export async function safeFetch(input: string | URL, opts: FetchOptions = {}): Promise<Response> {
  let url = new URL(input);
  const headers = {
    "User-Agent": opts.userAgent ?? BROWSER_UA,
    "Accept-Language": "en-US,en",
    ...opts.headers,
  };
  for (let hop = 0; hop < 6; hop++) {
    const [target, init] = opts.allowPrivateNetwork ? [url, { headers }] : await pinnedRequest(url, headers);
    const res = await fetch(target, {
      ...init,
      redirect: "manual",
      signal: AbortSignal.timeout(opts.timeoutMs ?? 10_000),
    });
    const location = res.headers.get("location");
    if (opts.followRedirects === false || res.status < 300 || res.status >= 400 || !location) return res;
    await res.body?.cancel();
    url = new URL(location, url);
  }
  throw new Error(`Too many redirects for ${input}`);
}

/** Read at most `limit` bytes of a response body. */
export async function readLimited(res: Response, limit: number): Promise<Uint8Array> {
  if (!res.body) return new Uint8Array();
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (size < limit) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    size += value.byteLength;
  }
  await reader.cancel().catch(() => {});
  const out = new Uint8Array(Math.min(size, limit));
  let offset = 0;
  for (const chunk of chunks) {
    const part = chunk.subarray(0, out.length - offset);
    out.set(part, offset);
    offset += part.length;
    if (offset >= out.length) break;
  }
  return out;
}

export function contentType(res: Response): string {
  return (res.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
}
