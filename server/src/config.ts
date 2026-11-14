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
  /** Emails (or "@domain.com") allowed to sign in. Empty = anyone your AuthKit lets in. */
  allowedEmails: string[];
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
  /** Push notifications (APNs). Without a key, push is off. */
  apnsTeamId: string;
  /** The app's bundle id (LINKS_BUNDLE_ID in ios/Config.xcconfig). */
  apnsTopic: string;
  /** One token-based (.p8) key, made for both Sandbox and Production. */
  apnsKey: { keyId: string; keyFile: string } | null;
  /** Overridable for tests, like workosApi. */
  apnsHosts: Record<ApnsEnv, string>;
}

export type ApnsEnv = "production" | "sandbox";

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
    allowedEmails: (env.ALLOWED_EMAILS ?? "")
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
    apnsTeamId: env.APNS_TEAM_ID?.trim() ?? "",
    apnsTopic: env.APNS_TOPIC?.trim() ?? "",
    apnsKey: env.APNS_KEY_ID?.trim() && env.APNS_KEY_FILE?.trim()
      ? { keyId: env.APNS_KEY_ID.trim(), keyFile: resolve(env.APNS_KEY_FILE.trim()) }
      : null,
    apnsHosts: {
      production: (env.APNS_HOST ?? "https://api.push.apple.com").replace(/\/+$/, ""),
      sandbox: (env.APNS_SANDBOX_HOST ?? "https://api.sandbox.push.apple.com").replace(/\/+$/, ""),
    },
  };
}
