import { resolve } from "node:path";

export interface Config {
  port: number;
  hostname: string;
  /** SQLite database and cached thumbnails live here. */
  dataDir: string;
  /** Where phones reach this server; AuthKit redirects to `${publicUrl}/auth/callback`. */
  publicUrl: string;
  /** The iOS app's URL scheme; /auth/callback bounces the code there. */
  appScheme: string;
  /** Sessions expire after this many days without use. */
  sessionDays: number;
  workosClientId: string;
  /** Optional: with PKCE the code exchange works without it. */
  workosApiKey: string;
  workosApi: string;
  /**
   * The old ALLOWED_EMAILS guest list (emails or "@domain.com"). Only the v7 migration reads it, to
   * decide who of those already signed up stays in; invites are the only way in now.
   */
  legacyAllowedEmails: string[];
  /** Let preview fetches reach private/loopback addresses. Only for tests. */
  allowPrivateNetwork: boolean;
  /** Log one line per request. */
  logRequests: boolean;
  /** Shown on /support, the page the App Store listing's Support URL points at. SUPPORT_EMAIL overrides it. */
  supportEmail: string;
  /** `TEAMID.bundleid` of each app that may open this server's links (universal links). Empty = no apple-app-site-association. */
  appleAppIds: string[];
  /** The app's numeric App Store ID, for the Smart App Banner on the web pages. Empty = no banner. */
  appStoreId: string;
  /** Pause between re-fetches of old links' previews after an upgrade; 0 turns that off. */
  previewBackfillMs: number;
}

/** Same as LINKS_SUPPORT_URL in ios/Config.xcconfig. */
export const DEFAULT_SUPPORT_EMAIL = "support@tpcomm.co";

export function configFromEnv(env: Record<string, string | undefined> = process.env): Config {
  const port = Number(env.PORT ?? 8000);
  return {
    port,
    hostname: env.HOST ?? "0.0.0.0",
    dataDir: resolve(env.DATA_DIR ?? "data"),
    publicUrl: (env.PUBLIC_URL ?? `http://localhost:${port}`).replace(/\/+$/, ""),
    appScheme: env.APP_SCHEME ?? "sharedlinks",
    sessionDays: Number(env.SESSION_DAYS ?? 90),
    workosClientId: env.WORKOS_CLIENT_ID ?? "",
    workosApiKey: env.WORKOS_API_KEY ?? "",
    workosApi: (env.WORKOS_API ?? "https://api.workos.com").replace(/\/+$/, ""),
    legacyAllowedEmails: (env.ALLOWED_EMAILS ?? "")
      .split(",")
      .map((e) => e.trim().toLowerCase())
      .filter(Boolean),
    allowPrivateNetwork: false,
    logRequests: true,
    supportEmail: env.SUPPORT_EMAIL?.trim() || DEFAULT_SUPPORT_EMAIL,
    previewBackfillMs: Number(env.PREVIEW_BACKFILL_MS ?? 5000),
    // Not lowercased: team IDs are upper case.
    appleAppIds: (env.APPLE_APP_IDS ?? "")
      .split(",")
      .map((id) => id.trim())
      .filter(Boolean),
    appStoreId: env.APP_STORE_ID?.trim() ?? "",
  };
}
