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
  /** Pause between re-fetches of old links' previews after an upgrade; 0 turns that off. */
  previewBackfillMs: number;
  /** Push notifications (APNs). With no key for either environment, push is off. */
  apnsTeamId: string;
  /** The app's bundle id (LINKS_BUNDLE_ID in ios/Config.xcconfig). */
  apnsTopic: string;
  /** Token-based (.p8) keys, one per environment. An older key that works in both can fill both. */
  apnsKeys: Partial<Record<ApnsEnv, { keyId: string; keyFile: string }>>;
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
    apnsTeamId: env.APNS_TEAM_ID?.trim() ?? "",
    apnsTopic: env.APNS_TOPIC?.trim() ?? "",
    apnsKeys: Object.fromEntries(([["production", env.APNS_KEY_ID, env.APNS_KEY_FILE],
                                   ["sandbox", env.APNS_SANDBOX_KEY_ID, env.APNS_SANDBOX_KEY_FILE]] as const)
      .filter(([, id, file]) => id?.trim() && file?.trim())
      .map(([name, id, file]) => [name, { keyId: id!.trim(), keyFile: resolve(file!.trim()) }])),
    apnsHosts: {
      production: (env.APNS_HOST ?? "https://api.push.apple.com").replace(/\/+$/, ""),
      sandbox: (env.APNS_SANDBOX_HOST ?? "https://api.sandbox.push.apple.com").replace(/\/+$/, ""),
    },
  };
}
