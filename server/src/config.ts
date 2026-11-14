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
  /** Pause between re-fetches of old links' previews after an upgrade; 0 turns that off. */
  previewBackfillMs: number;
}

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
    previewBackfillMs: Number(env.PREVIEW_BACKFILL_MS ?? 5000),
  };
}
