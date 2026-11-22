import type { Database } from "bun:sqlite";
import { randomBytes } from "node:crypto";
import { readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { Accounts, AuthError, INVITE_TOKEN_RE, MAX_GROUP_MEMBERS, MAX_PHOTO_BYTES, photoType, publicUser, reportPhoto } from "./accounts.ts";
import type { Config } from "./config.ts";
import { defaultGroup, deleteEmptyGroups, deleteLink, ensureDirectChatsFor, now, openDatabase, sharesGroupWithDirectPeer, type CommentRow, type GroupRow, type LinkRow, type UserRow } from "./db.ts";
import { BadRequest, canonical, clipText, extractUrl } from "./links.ts";
import { landingPage } from "./landing.ts";
import { REPORT_REASONS } from "./moderation.ts";
import { fetchMetadata, PREVIEW_VERSION } from "./previews.ts";
import { Pusher, type PushOptions } from "./push.ts";
// Embedded in the compiled binary (bun build --compile), for invite pages and their link previews.
import iconPath from "../../assets/icon/previews/B/default-256.png" with { type: "file" };
import appPreviewPath from "../../assets/landing/inbox.png" with { type: "file" };
import { BUILD_COMMIT } from "./version.ts";

export const EMOJIS = new Set(["❤️", "😂", "🔥", "😮", "😭", "👎"]);

class NotFound extends Error {}
/** 413, which Bun itself sent before PUT /api/me/photo raised its body limit. */
class TooLarge extends Error {}

const MAX_GROUP_NAME = 60;
const json = (body: unknown, status = 200) =>
  Response.json(body, { status, headers: { "Cache-Control": "no-store" } });

const redirect = (location: string) =>
  new Response(null, { status: 302, headers: { Location: location, "Cache-Control": "no-store" } });

async function readJson(req: Request): Promise<Record<string, any>> {
  // Bytes, not characters: the server-wide cap is the photo's, so this is JSON's only one.
  const body = new Uint8Array(await req.arrayBuffer());
  if (body.length > 65536) throw new TooLarge("Request too large.");
  const text = new TextDecoder().decode(body);
  if (!text.trim()) return {};
  try {
    const value = JSON.parse(text);
    return value && typeof value === "object" ? value : {};
  } catch {
    throw new BadRequest("Invalid JSON.");
  }
}

const escapeHtml = (s: string) =>
  s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

/** The page the App Store listing's Support URL points at (guideline 1.2: published contact information). */
function supportPage(email: string): string {
  const contact = email
    ? `<p>Email <a href="mailto:${escapeHtml(email)}">${escapeHtml(email)}</a>. We read every message.</p>`
    : "<p>Ask the person who runs this Links server.</p>";
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Links Support</title><style>body{font:17px/1.5 -apple-system,system-ui,sans-serif;max-width:36em;margin:3em auto;padding:0 1em}</style></head>
<body><h1>Links Support</h1>${contact}
<p>To report a link or a person, long-press the link in the app and choose <b>Report…</b> or <b>Block…</b>. Reported links are hidden for you straight away.</p>
</body></html>
`;
}

/** Paths that open the app (universal links), claimed before the features that use them ship,
 *  since phones only recheck the file about once a week. */
export const APP_PATHS = ["/l/", "/invite/", "/g/"] as const;

/** The apple-app-site-association file: which apps may open which paths on this host. */
export function appSiteAssociation(appIds: string[]) {
  return {
    applinks: {
      details: [{
        appIDs: appIds,
        // The first match wins, so the excludes go first.
        components: [
          { "/": "/api/*", exclude: true, comment: "JSON API" },
          { "/": "/auth/*", exclude: true, comment: "sign-in redirects" },
          { "/": "/thumbs/*", exclude: true, comment: "thumbnails" },
          { "/": "/l/*", comment: "a link's page" },
          { "/": "/invite/*", comment: "invites" },
          { "/": "/g/*", comment: "chats" },
        ],
      }],
    },
    webcredentials: { apps: appIds },
  };
}

const TOKEN = /^[A-Za-z0-9_-]{1,64}$/;

/** Shown in a browser for a universal link when the app isn't installed (or Safari kept it). */
function openInAppPage(pageUrl: string, appStoreId: string): string {
  const banner = appStoreId
    ? `<meta name="apple-itunes-app" content="app-id=${escapeHtml(appStoreId)}, app-argument=${escapeHtml(pageUrl)}">`
    : "";
  const store = appStoreId
    ? `<p><a href="https://apps.apple.com/app/id${escapeHtml(appStoreId)}">Get Links on the App Store</a>, then open this link again.</p>`
    : "<p>Ask whoever sent it how to get the app, then open this link again.</p>";
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
${banner}<title>Open in Links</title><style>body{font:17px/1.5 -apple-system,system-ui,sans-serif;max-width:36em;margin:3em auto;padding:0 1em}</style></head>
<body><h1>Open this in the Links app</h1><p>This link opens in Links on an iPhone that has the app.</p>${store}
</body></html>
`;
}

/**
 * What an invite link shows in a browser and in Messages' preview: who sent it and how to get in,
 * nothing from the inbox. Loading it never uses the invite up; only signing in does.
 */
function invitePage(config: Config, token: string, invite: { inviter: string | null } | null): string {
  const appLink = `${config.appScheme}://invite/${token}`;
  const store = config.appStoreId ? `https://apps.apple.com/app/id${encodeURIComponent(config.appStoreId)}` : "";
  const title = !invite ? "This invite doesn't work anymore" : invite.inviter ? `${invite.inviter} invited you to Links` : "You're invited to Links";
  const description = invite
    ? "Share articles, videos, recipes, gift ideas and more, and see who's seen them."
    : "It was already used, cancelled, or it expired. Ask for a new one.";
  const banner = invite && config.appStoreId
    ? `<meta name="apple-itunes-app" content="app-id=${escapeHtml(config.appStoreId)}, app-argument=${escapeHtml(`${config.publicUrl}/invite/${token}`)}">`
    : "";
  const steps = invite
    ? `<ol><li>${store ? `<a href="${escapeHtml(store)}">Get Links</a>` : "Install Links"} on your iPhone.</li>
<li>Come back here and tap <b>Open in Links</b>, then sign in.</li></ol>
<p><a class="button" href="${escapeHtml(appLink)}">Open in Links</a></p>
<p class="small">${invite?.inviter ? `If ${escapeHtml(invite.inviter)} sent the invite to your email address` : "If the invite was sent to your email address"}, signing in with it works even without this link.</p>`
    : "";
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${escapeHtml(title)}</title>${banner}
<meta property="og:title" content="${escapeHtml(title)}"><meta property="og:description" content="${escapeHtml(description)}">
<meta property="og:site_name" content="Links"><meta property="og:image" content="${escapeHtml(`${config.publicUrl}/icon.png`)}">
<style>body{font:17px/1.5 -apple-system,system-ui,sans-serif;max-width:30em;margin:3em auto;padding:0 1em}
.button{display:inline-block;background:#1f9d55;color:#fff;padding:.6em 1.4em;border-radius:2em;text-decoration:none;font-weight:600}
.small{color:#666;font-size:15px}</style></head>
<body><img src="/icon.png" width="72" height="72" alt="" style="border-radius:16px"><h1>${escapeHtml(title)}</h1><p>${escapeHtml(description)}</p>${steps}
</body></html>
`;
}

function linkPage(config: Config, link: LinkRow | null): string {
  const platform = link ? ({ tiktok: "TikTok", instagram: "Instagram", youtube: "YouTube", x: "X", reddit: "Reddit", facebook: "Facebook" }[link.platform] ?? "") : "";
  const title = link ? link.title || (platform ? `${/^(Instagram|X)$/.test(platform) ? "An" : "A"} ${platform} shared on Links` : "A link shared on Links") : "This link isn't available";
  const button = platform ? `Watch on ${platform}` : "Open the link";
  const url = link ? `${config.publicUrl}/l/${link.share_token}` : "";
  const image = `${config.publicUrl}${link?.thumb_type ? `/l/${link.share_token}/image` : "/icon.png"}`;
  const banner = link && config.appStoreId ? `<meta name="apple-itunes-app" content="app-id=${escapeHtml(config.appStoreId)}, app-argument=${escapeHtml(url)}">` : "";
  const og = link ? `<meta property="og:title" content="${escapeHtml(title)}">
<meta property="og:image" content="${escapeHtml(image)}"><meta property="og:site_name" content="Links"><meta property="og:url" content="${escapeHtml(url)}">
${link.thumb_type ? `<meta name="twitter:card" content="summary_large_image">${link.thumb_w ? `<meta property="og:image:width" content="${link.thumb_w}">` : ""}${link.thumb_h ? `<meta property="og:image:height" content="${link.thumb_h}">` : ""}` : ""}` : "";
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex"><title>${escapeHtml(title)}</title>${banner}${og}
<style>body{font:17px/1.5 -apple-system,system-ui,sans-serif;max-width:30em;margin:3em auto;padding:0 1em}img{max-width:100%;border-radius:16px}a{display:inline-block;background:#1f9d55;color:#fff;padding:.6em 1.4em;border-radius:2em;text-decoration:none;font-weight:600}</style></head>
<body><h1>${escapeHtml(title)}</h1>${link?.thumb_type ? `<img src="${escapeHtml(image)}" alt="">` : ""}${link ? `<p><a href="${escapeHtml(link.url)}">${escapeHtml(button)}</a></p>` : ""}</body></html>`;
}

/**
 * The privacy policy (guideline 5.1.1(i)): the App Store listing's Privacy Policy URL, and the app's
 * account menu and sign-in screen. Keep it in step with ios/Links/PrivacyInfo.xcprivacy.
 */
function privacyPage(email: string, sessionDays: number): string {
  const contact = email
    ? `<a href="mailto:${escapeHtml(email)}">${escapeHtml(email)}</a>`
    : "the person who runs this Links server";
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Links Privacy Policy</title><style>body{font:17px/1.5 -apple-system,system-ui,sans-serif;max-width:36em;margin:3em auto;padding:0 1em}h2{font-size:1.1em;margin-top:1.6em}</style></head>
<body><h1>Links Privacy Policy</h1>
<p>Last updated 17 November 2026.</p>
<p>Links is a private inbox for the links a few friends send each other. This policy covers the Links app and this server, which keeps what the app shows. Questions or requests: ${contact}.</p>

<h2>What Links keeps, and why</h2>
<ul>
<li><b>Your account:</b> your email address, display name and profile photo. They come from WorkOS, our sign-in provider, when you first sign in, and you can change your name and photo in the app; a photo you choose is stored on our server. They sign you in, match invites sent to you, and show your friends who sent what.</li>
<li><b>What you do in Links:</b> the links you send and their notes, your comments, which links you've seen, your reactions, the reports you make and the people you block. For each link the server also fetches its title, author and thumbnail from the link's page.</li>
<li><b>Invites you send:</b> the email address you invite, if you type one, when the invite expires, and who used it. They let your friend in; cancelling an invite deletes it.</li>
<li><b>Signed-in devices:</b> a scrambled (hashed) copy of each device's sign-in token, with when it was created and last used, and the push notification token Apple gives the app on that device, which the server uses to send it notifications.</li>
<li><b>Server logs:</b> one line per request, with what was asked for (for example, "mark link 12 seen") and whether it worked, plus messages about errors and events, which can include a link's address or an account's ID. They're used to fix problems.</li>
<li><b>Server health:</b> the server computer's CPU, memory, disk and network use, once a minute. It's about the server, not about you.</li>
<li><b>Backups:</b> a copy of the server's database, made every day.</li>
</ul>
<p>Links uses this only to run the app. There are no ads, no analytics and no tracking, and nothing is sold or shared for marketing.</p>

<h2>Who else sees it</h2>
<ul>
<li><b>The people in your chats</b> see your name and photo. People only lists people you share a chat with. Anyone with a link's share URL can see its title, thumbnail and original URL. Notes, who sent it, comments, reactions and activity stay private to the chat. Your name and photo can still appear on links in a chat you've left, or under Blocked People for someone who blocked you. Reports and blocks are private: only the person who runs the server reads reports.</li>
<li><b>WorkOS</b> runs sign-in. It keeps your email, your sign-in details and the sign-ins you make, and gets the app's name and version and your iOS version when you sign in, plus, like any website, your IP address and browser details while you sign in. See the <a href="https://workos.com/legal/privacy">WorkOS privacy policy</a>.</li>
<li><b>Apple</b> delivers push notifications. For each one, the server sends Apple your device's push token and what the notification shows: who sent a link, nudged you, reacted or commented, the chat's name, the link's title and note (shortened if long), the reaction or shortened comment text, and how many links are in your Queue tab, along with a link to the sender's profile photo for a new link (anyone holding that link can open the photo), and Links' own numbers for the link, its sender, its chat and the comment. See the <a href="https://www.apple.com/legal/privacy/">Apple privacy policy</a>.</li>
<li><b>Grafana Cloud</b> (Grafana Labs) keeps a copy of the server logs, the web server's and the daily backup's own messages, and the server health figures, so problems can be spotted and fixed. See the <a href="https://grafana.com/legal/privacy-policy/">Grafana Labs privacy policy</a>.</li>
<li><b>The company that hosts this server</b> stores it on its computers.</li>
</ul>
<p>Links only uses services like these that protect your data the way this policy describes. When the server fetches a link's preview, the site sees the server, not you. When you open a link, it opens in its own app (such as TikTok or Instagram) or in Safari, and their privacy policies apply there.</p>

<h2>How long it's kept</h2>
<ul>
<li>Your account and what you do in Links: until you delete them, or your account.</li>
<li>A device's sign-in: until you sign out on it, or ${sessionDays} days after it was last used.</li>
<li>A device's push token: until you sign out on it, or Apple tells the server the token no longer works.</li>
<li>Server logs: until the server's system log replaces them with newer ones, usually within a few weeks. Grafana Cloud's copy of the logs and server health figures is kept for up to 31 days.</li>
<li>Backups: the newest 14 days are kept, so anything deleted is gone from the backups within two weeks.</li>
</ul>

<h2>Your choices</h2>
<ul>
<li>Change your display name in the app's account menu. Delete a link you sent, or change its note, from the link's long-press menu.</li>
<li>To delete your account, open the account menu in the app and choose <b>Delete Account</b>. That deletes your account, your sign-ins on every device, the links you sent with their notes and thumbnails (for your friends too), your comments, seen marks and reactions, and your WorkOS account.</li>
<li>You can also email ${contact} to ask what Links keeps about you, to correct it, or to delete it.</li>
</ul>

<h2>Changes</h2>
<p>If this policy changes, this page shows the new version and its date.</p>
</body></html>
`;
}

function bearer(req: Request): string | null {
  const auth = req.headers.get("authorization") ?? "";
  return auth.slice(0, 7).toLowerCase() === "bearer " ? auth.slice(7).trim() || null : null;
}

export interface AppOptions extends PushOptions {
  /** How long a new link's push waits for its preview (title) before going out without it. */
  previewWaitMs?: number;
  previewNow?: () => number;
}

export function createApp(config: Config, opts: AppOptions = {}) {
  const db = openDatabase(config.dataDir, config.legacyAllowedEmails);
  const accounts = new Accounts(db, config);
  const fetchOpts = { allowPrivateNetwork: config.allowPrivateNetwork };
  const pending = new Set<Promise<void>>();
  function track(task: Promise<void>) {
    const settled: Promise<void> = task.catch((e) => console.error(`push: ${e}`)).finally(() => pending.delete(settled));
    pending.add(settled);
  }
  const push = new Pusher(db, config, accounts, track, opts);

  // One fetch per link at a time (a retry during the backfill, an edit mid-fetch): the next waits its turn.
  const latest = new Map<number, Promise<void>>();
  const retries = new Map<number, { attempts: number; after: number }>();
  const retryDelays = [60_000, 300_000, 1_800_000, 7_200_000, 43_200_000];
  const previewNow = opts.previewNow ?? Date.now;
  function failedAttempt(id: number) {
    const attempts = (retries.get(id)?.attempts ?? 0) + 1;
    retries.set(id, { attempts, after: previewNow() + retryDelays[Math.min(attempts - 1, retryDelays.length - 1)]! });
  }
  function queueFetch(id: number, url: string, platform: string): Promise<void> {
    const run = (latest.get(id) ?? Promise.resolve()).then(async () => {
      const result = await fetchMetadata(db, config.dataDir, id, url, platform, fetchOpts).catch((e) => {
        failedAttempt(id);
        try {
          db.run("UPDATE links SET meta = 'failed', preview_v = ? WHERE id = ? AND meta = 'pending'", [PREVIEW_VERSION, id]);
        } catch {}
        throw e;
      });
      const row = db.query("SELECT meta FROM links WHERE id = ?").get(id) as { meta: string } | null;
      if (row?.meta === "failed" || result?.retryThumbnail) failedAttempt(id);
      else retries.delete(id);
    });
    const settled = run.catch(() => {});
    latest.set(id, settled);
    void settled.then(() => { if (latest.get(id) === settled) latest.delete(id); });
    return run;
  }

  function startMetadataFetch(id: number, url: string, platform: string): Promise<void> {
    const task = queueFetch(id, url, platform)
      .catch((e) => console.error(`metadata ${id}: ${e}`))
      .finally(() => pending.delete(task));
    pending.add(task);
    return task;
  }

  // Previews that were mid-fetch when the server last stopped get retried.
  for (const row of db.query("SELECT id, url, platform FROM links WHERE meta = 'pending'").all() as LinkRow[]) {
    startMetadataFetch(row.id, row.url, row.platform);
  }

  // Backfill old previews and retry failures or missing thumbnails with backoff, one at a time.
  function backfillNext() {
    let row: LinkRow | null;
    try {
      const rows = db.query("SELECT id, url, platform, preview_v, meta FROM links WHERE (preview_v < ? OR meta = 'failed' OR (meta = 'done' AND thumb_type IS NULL)) AND meta != 'pending' ORDER BY added_at DESC")
        .all(PREVIEW_VERSION) as LinkRow[];
      row = rows.find((candidate) => {
        if (latest.has(candidate.id)) return false;
        if (candidate.preview_v < PREVIEW_VERSION) return true;
        if (candidate.meta === "done" && !retries.has(candidate.id)) return false;
        if (!retries.has(candidate.id)) failedAttempt(candidate.id);
        return retries.get(candidate.id)!.after <= previewNow();
      }) ?? null;
    } catch (e) {
      return console.error(`backfill stopped: ${e}`); // the database closed under us (shutdown)
    }
    if (!row) {
      setTimeout(backfillNext, config.previewBackfillMs).unref();
      return;
    }
    const task = queueFetch(row.id, row.url, row.platform)
      .catch((e) => {
        console.error(`backfill ${row.id}: ${e}`);
        db.run("UPDATE links SET preview_v = ? WHERE id = ?", [PREVIEW_VERSION, row.id]);
      })
      .finally(() => {
        pending.delete(task);
        setTimeout(backfillNext, config.previewBackfillMs).unref();
      });
    pending.add(task);
  }
  if (config.previewBackfillMs > 0) setTimeout(backfillNext, config.previewBackfillMs).unref();

  /**
   * A link `?1` can see: one in a chat they're in (#12), but not one they reported, nor one from
   * someone they blocked. Everyone else in the chat still sees it. getState, getLink's callers (via
   * linkId) and addLink's duplicate check use this.
   */
  const VISIBLE = `EXISTS (SELECT 1 FROM group_members WHERE group_id = links.group_id AND user_id = ?1)
    AND NOT EXISTS (SELECT 1 FROM reports WHERE reporter = ?1 AND link_id = links.id)
    AND NOT EXISTS (SELECT 1 FROM blocks WHERE blocker = ?1 AND blocked = links.added_by)`;

  const isVisible = (id: number, me: string) =>
    !!db.query(`SELECT 1 FROM links WHERE ${VISIBLE} AND id = ?2`).get(me, id);

  /** The people `me` has blocked. */
  function blockedBy(me: string): Set<string> {
    const rows = db.query("SELECT blocked FROM blocks WHERE blocker = ? ORDER BY created_at").all(me) as { blocked: string }[];
    return new Set(rows.map((r) => r.blocked));
  }

  const hasBlocked = (blocker: string, blocked: string) =>
    !!db.query("SELECT 1 FROM blocks WHERE blocker = ? AND blocked = ?").get(blocker, blocked);

  const inGroup = (groupId: number, me: string) =>
    !!db.query("SELECT 1 FROM group_members WHERE group_id = ? AND user_id = ?").get(groupId, me);

  /** A chat `me` is in, from a request; any other is a 404, as if it were gone. */
  function groupOf(id: unknown, me: string): number {
    const n = typeof id === "string" && /^\d+$/.test(id) ? Number(id) : id;
    if (!Number.isSafeInteger(n) || !inGroup(n as number, me)) throw new NotFound("That chat isn't there anymore.");
    return n as number;
  }

  /** A chat as the app sees it: `members` are user ids, oldest first; `default` is the one everyone started in. */
  function toGroup(r: GroupRow, me: string) {
    const members = (db.query("SELECT user_id FROM group_members WHERE group_id = ? ORDER BY joined_at, user_id")
      .all(r.id) as { user_id: string }[]).map((m) => m.user_id);
    const settings = db.query("SELECT muted, muted_until FROM group_members WHERE group_id = ? AND user_id = ?")
      .get(r.id, me) as { muted: number; muted_until: number | null };
    const muted = !!settings.muted && (settings.muted_until === null || settings.muted_until > now());
    return { id: r.id, name: r.name, created_by: r.created_by, created_at: r.created_at, default: !!r.is_default, direct: !!r.is_direct, members,
      muted, muted_until: muted ? settings.muted_until : null };
  }

  const getGroup = (id: number, me: string) => toGroup(db.query("SELECT * FROM groups WHERE id = ?").get(id) as GroupRow, me);

  function groupsOf(me: string) {
    return (db.query(`SELECT g.* FROM groups g JOIN group_members m ON m.group_id = g.id AND m.user_id = ?
        ORDER BY g.is_default DESC, g.created_at, g.id`).all(me) as GroupRow[]).map((r) => toGroup(r, me));
  }

  /**
   * `me`'s view: the chats they're in and those chats' links (just one chat's with `groupId`), with no
   * hidden links, and no seen marks or reactions from people they blocked.
   */
  /**
   * Who `me` may see (#75): people they share a chat with, plus anyone named on a link in their chats
   * (a sender, seen mark or reaction from someone who has since left) and people they blocked, so the
   * app can still name them under Blocked People. Takes `me` as ?1.
   */
  const PEOPLE = `SELECT ?1
    UNION SELECT b.user_id FROM group_members a JOIN group_members b ON b.group_id = a.group_id WHERE a.user_id = ?1
    UNION SELECT l.added_by FROM links l JOIN group_members m ON m.group_id = l.group_id AND m.user_id = ?1
    UNION SELECT s.person FROM seen s JOIN links l ON l.id = s.link_id JOIN group_members m ON m.group_id = l.group_id AND m.user_id = ?1
    UNION SELECT r.person FROM reactions r JOIN links l ON l.id = r.link_id JOIN group_members m ON m.group_id = l.group_id AND m.user_id = ?1
    UNION SELECT c.person FROM comments c JOIN links l ON l.id = c.link_id JOIN group_members m ON m.group_id = l.group_id AND m.user_id = ?1
    UNION SELECT blocked FROM blocks WHERE blocker = ?1`;

  const sees = (me: string, id: string) =>
    !!db.query(`SELECT 1 WHERE ?2 IN (${PEOPLE})`).get(me, id);

  function getState(me: string, groupId?: number) {
    const blocked = blockedBy(me);
    const links = new Map<number, ReturnType<typeof toLink>>();
    const only = groupId === undefined ? "" : " AND group_id = ?2";
    const rows = db.query(`SELECT * FROM links WHERE ${VISIBLE}${only} ORDER BY added_at DESC`)
      .all(...(groupId === undefined ? [me] : [me, groupId])) as LinkRow[];
    for (const r of rows) {
      links.set(r.id, toLink(r, me));
    }
    for (const r of db.query("SELECT * FROM seen").all() as { link_id: number; person: string; seen_at: number }[]) {
      const link = links.get(r.link_id);
      if (link && !blocked.has(r.person)) link.seen[r.person] = r.seen_at;
    }
    for (const r of db.query("SELECT * FROM reactions").all() as { link_id: number; person: string; emoji: string }[]) {
      const link = links.get(r.link_id);
      if (link && !blocked.has(r.person)) link.reactions[r.person] = r.emoji;
    }
    for (const summary of commentSummaries(me, "group_id", groupId)) {
      const link = links.get(summary.link_id);
      if (link) applyCommentSummary(link, summary);
    }
    const users = (db.query(`SELECT * FROM users WHERE id IN (${PEOPLE}) ORDER BY created_at`).all(me) as UserRow[]).map((u) => publicUser(u, config.publicUrl));
    return { me, users, groups: groupsOf(me), links: [...links.values()], blocked: [...blocked] };
  }

  function toLink(r: LinkRow, me: string) {
    return {
      token: r.share_token, share_url: `${config.publicUrl}/l/${r.share_token}`,
      id: r.id, group_id: r.group_id, url: r.url, platform: r.platform, title: r.title, author: r.author, note: r.note,
      description: r.description, site_name: r.site_name,
      thumb: r.thumb_type ? `/thumbs/${r.id}${r.thumb_v ? `/${r.thumb_v}` : ""}` : null, thumb_w: r.thumb_w, thumb_h: r.thumb_h, meta: r.meta, added_by: r.added_by, added_at: r.added_at,
      seen: {} as Record<string, number>, reactions: {} as Record<string, string>,
      ...(r.added_by === me ? { nudged: Object.fromEntries((db.query("SELECT person, nudged_at FROM nudges WHERE link_id = ?").all(r.id) as { person: string; nudged_at: number }[]).map((n) => [n.person, n.nudged_at])) } : {}),
      comment_count: 0, last_comment: null as { person: string; snippet: string; at: number } | null,
    };
  }

  function commentSummaries(me: string, field: "group_id" | "id", id?: number) {
    const only = id === undefined ? "" : ` AND links.${field} = ?2`;
    return db.query(`SELECT link_id, comment_count, person, snippet, at FROM (
      SELECT c.link_id, c.person, substr(c.body, 1, 120) AS snippet, c.created_at AS at,
        count(*) OVER (PARTITION BY c.link_id) AS comment_count,
        row_number() OVER (PARTITION BY c.link_id ORDER BY c.created_at DESC, c.id DESC) AS rank
      FROM comments c JOIN links ON links.id = c.link_id
      WHERE ${VISIBLE}${only}
        AND NOT EXISTS (SELECT 1 FROM blocks WHERE blocker = ?1 AND blocked = c.person)
        AND NOT EXISTS (SELECT 1 FROM reports WHERE reporter = ?1 AND comment_id = c.id)
    ) WHERE rank = 1`).all(...(id === undefined ? [me] : [me, id])) as {
      link_id: number; comment_count: number; person: string; snippet: string; at: number;
    }[];
  }

  function applyCommentSummary(link: ReturnType<typeof toLink>, summary: ReturnType<typeof commentSummaries>[number]) {
    link.comment_count = summary.comment_count;
    link.last_comment = { person: summary.person, snippet: summary.snippet, at: summary.at };
  }

  function commentsFor(id: number, me: string): CommentRow[] {
    return db.query(`SELECT * FROM comments WHERE link_id = ?2
      AND NOT EXISTS (SELECT 1 FROM blocks WHERE blocker = ?1 AND blocked = comments.person)
      AND NOT EXISTS (SELECT 1 FROM reports WHERE reporter = ?1 AND comment_id = comments.id)
      ORDER BY created_at, id`).all(me, id) as CommentRow[];
  }

  function commentOf(id: string, me: string, includeReported = false): CommentRow {
    const row = /^\d+$/.test(id) ? db.query("SELECT * FROM comments WHERE id = ?").get(Number(id)) as CommentRow | null : null;
    if (!row || !isVisible(row.link_id, me) || hasBlocked(me, row.person)
        || (!includeReported && db.query("SELECT 1 FROM reports WHERE reporter = ? AND comment_id = ?").get(me, row.id))) {
      throw new NotFound("That comment was deleted.");
    }
    return row;
  }

  function commentBody(body: unknown): string {
    if (typeof body !== "string") throw new BadRequest("Write a comment first.");
    const clean = clipText(body, 1000);
    if (!clean) throw new BadRequest("Write a comment first.");
    accounts.screen(clean, "comment");
    return clean;
  }

  /** One link as `me` sees it (see getState). Callers check it's visible to them first. */
  function getLink(id: number, me: string) {
    const row = db.query("SELECT * FROM links WHERE id = ?").get(id) as LinkRow | null;
    if (!row) return null;
    const blocked = blockedBy(me);
    const link = toLink(row, me);
    for (const r of db.query("SELECT person, seen_at FROM seen WHERE link_id = ?").all(id) as { person: string; seen_at: number }[]) {
      if (!blocked.has(r.person)) link.seen[r.person] = r.seen_at;
    }
    for (const r of db.query("SELECT person, emoji FROM reactions WHERE link_id = ?").all(id) as { person: string; emoji: string }[]) {
      if (!blocked.has(r.person)) link.reactions[r.person] = r.emoji;
    }
    const [summary] = commentSummaries(me, "id", id);
    if (summary) applyCommentSummary(link, summary);
    return link;
  }

  /**
   * A write on `me`'s behalf, if their account still exists. A request can outlive it: DELETE /api/me
   * (or `links-server delete-user`) can land while it awaits its body or a short link, and rows
   * written after that would stay under the deleted id instead of going with the account.
   */
  function asUser<T>(me: string, write: () => T): T {
    return db.transaction(() => {
      if (!db.query("SELECT 1 FROM users WHERE id = ?").get(me)) throw new AuthError("Sign in to continue.");
      return write();
    }).immediate();
  }

  /**
   * Where a link goes: the chat asked for, or for apps from before groups, the default chat (or
   * their only one, if they left it).
   */
  function targetGroup(requested: unknown, by: string): number {
    if (requested !== undefined && requested !== null) return groupOf(requested, by);
    const mine = db.query(`SELECT g.id FROM groups g JOIN group_members m ON m.group_id = g.id AND m.user_id = ?
        ORDER BY g.is_default DESC LIMIT 2`).all(by) as { id: number }[];
    const everyone = defaultGroup(db);
    if (mine[0]?.id === everyone || mine.length === 1) return mine[0]!.id;
    throw new BadRequest(mine.length ? "Pick a chat to send it to." : "Start a chat to send links.");
  }

  async function addLink(text: unknown, note: unknown, requestedGroup: unknown, by: string) {
    let raw = extractUrl(text);
    if (!raw) throw new BadRequest("That doesn't look like a link.");
    let page: URL;
    try { page = new URL(raw); } catch { throw new BadRequest("That doesn't look like a link."); }
    if (page.origin === new URL(config.publicUrl).origin) {
      const token = page.pathname.match(/^\/l\/([^/]+)\/?$/)?.[1];
      if (token) raw = publicLink(token)?.url ?? raw;
    }
    const cleanNote = clipText(note, 500);
    accounts.screen(cleanNote, "note");
    const { url, platform } = await canonical(raw, fetchOpts);
    if (!new URL(url).hostname) throw new BadRequest("That doesn't look like a link.");
    const groupId = asUser(by, () => targetGroup(requestedGroup, by));
    const existing = db.query("SELECT id FROM links WHERE group_id = ? AND url = ?").get(groupId, url) as { id: number } | null;
    if (existing) {
      // Hidden for them (reported, or from someone they blocked): don't hand it back.
      if (!isVisible(existing.id, by)) throw new BadRequest("That link was already shared.");
      return { link: getLink(existing.id, by)!, duplicate: true };
    }
    const { lastInsertRowid } = asUser(by, () => {
      // They may have left while the short link resolved.
      if (!inGroup(groupId, by)) throw new NotFound("That chat isn't there anymore.");
      return db.run(
        "INSERT INTO links (group_id, url, platform, note, added_by, added_at, share_token) VALUES (?, ?, ?, ?, ?, ?, ?)",
        [groupId, url, platform, cleanNote, by, now(), randomBytes(24).toString("base64url")],
      );
    });
    const id = Number(lastInsertRowid);
    const preview = startMetadataFetch(id, url, platform);
    // Wait (briefly) for the preview, so the notification can show the link's title.
    if (push.enabled) track(Promise.race([preview, Bun.sleep(opts.previewWaitMs ?? 5000)]).then(() => push.newLink(id)));
    return { link: getLink(id, by)!, duplicate: false };
  }

  /** The link in the path, if `me` can see it; a hidden one is a 404, as if it were gone. */
  function linkId(req: Request & { params: { id: string } }, me: string): number {
    if (!/^\d+$/.test(req.params.id)) throw new NotFound("Not found");
    const id = Number(req.params.id);
    if (!isVisible(id, me)) throw new NotFound("That link was deleted.");
    return id;
  }

  /** Again inside a write, once the body is in: they may have left its chat while it uploaded. */
  function stillSees(id: number, me: string) {
    if (!isVisible(id, me)) throw new NotFound("That link was deleted.");
  }

  const sender = (id: number) => (db.query("SELECT added_by FROM links WHERE id = ?").get(id) as { added_by: string }).added_by;

  /** A report snapshot: what was reported as it was, since it can be edited or deleted later. */
  function reportTarget(data: Record<string, any>, me: string) {
    const given = (["link_id", "comment_id", "user_id"] as const).filter((k) => data[k] !== undefined && data[k] !== null);
    if (given.length !== 1) throw new BadRequest("Report one link, comment or person.");
    if (given[0] === "link_id") {
      const id = data.link_id;
      const row = Number.isSafeInteger(id) ? db.query("SELECT * FROM links WHERE id = ?").get(id) as LinkRow | null : null;
      if (!row || !inGroup(row.group_id, me)) throw new NotFound("That link was deleted.");
      if (row.added_by === me) throw new BadRequest("That's your own link. Delete it instead.");
      const from = db.query("SELECT name, email FROM users WHERE id = ?").get(row.added_by) as { name: string; email: string | null } | null;
      return {
        link_id: row.id as number, comment_id: null, user_id: null, label: `link ${row.id}`,
        snapshot: { url: row.url, title: row.title, author: row.author, note: row.note, sender: row.added_by,
                    sender_name: from?.name ?? null, sender_email: from?.email ?? null },
      };
    }
    if (given[0] === "user_id") {
      const id = String(data.user_id);
      if (id === me) throw new BadRequest("You can't report yourself.");
      const user = db.query("SELECT * FROM users WHERE id = ?").get(id) as UserRow | null;
      if (!user || !sees(me, id)) throw new NotFound("That person isn't in Links anymore.");
      return {
        link_id: null, comment_id: null, user_id: id, label: `person ${id}`, photo: user.photo || null,
        snapshot: { name: user.name, avatar: publicUser(user, config.publicUrl).avatar, email: user.email,
                    ...(user.photo ? { photo_copy: reportPhoto(user.photo) } : {}) },
      };
    }
    if (!Number.isSafeInteger(data.comment_id)) throw new NotFound("That comment was deleted.");
    const comment = commentOf(String(data.comment_id), me, true);
    if (comment.person === me) throw new BadRequest("That's your own comment. Delete it instead.");
    return {
      link_id: null, comment_id: comment.id, user_id: null, label: `comment ${comment.id}`,
      snapshot: { ...comment },
    };
  }

  function groupName(name: unknown): string {
    const clean = clipText(name, MAX_GROUP_NAME).replace(/\s+/g, " ");
    accounts.screen(clean, "name");
    return clean;
  }

  /**
   * People to add to a chat that already has `have`: user ids of members of Links (not legacy or
   * deleted people) whom `me` can see. Unknown ids are an error, so the app doesn't think it added someone it didn't.
   */
  function newMembers(ids: unknown, me: string, have: string[]): string[] {
    if (ids === undefined || ids === null) ids = [];
    if (!Array.isArray(ids) || !ids.every((id) => typeof id === "string")) throw new BadRequest("Pick the people to add.");
    const add = [...new Set(ids as string[])].filter((id) => id !== me && !have.includes(id));
    for (const id of add) {
      if (!accounts.isMember(id) || !sees(me, id)) throw new BadRequest("Someone you picked isn't in Links anymore.");
    }
    if (Math.max(have.length, 1) + add.length > MAX_GROUP_MEMBERS) {
      throw new BadRequest(`A chat can have up to ${MAX_GROUP_MEMBERS} people.`);
    }
    return add;
  }

  type Handler<R extends Request> = (req: R, me: string) => Response | Promise<Response>;

  /** Wrap a route: map errors to JSON, log, and (unless public) require a session. */
  function route<R extends Request>(handler: Handler<R>, opts: { public?: boolean } = {}) {
    return async (req: R): Promise<Response> => {
      let res: Response;
      try {
        const me = accounts.sessionUser(bearer(req));
        if (!me && !opts.public) {
          res = json({ error: "Sign in to continue." }, 401);
        } else {
          res = await handler(req, me ?? "");
        }
      } catch (e) {
        if (e instanceof AuthError) res = json({ error: e.message }, e.status);
        else if (e instanceof BadRequest) res = json({ error: e.message }, 400);
        else if (e instanceof NotFound) res = json({ error: e.message }, 404);
        else if (e instanceof TooLarge) res = json({ error: e.message }, 413);
        else {
          console.error(`error handling ${req.method} ${new URL(req.url).pathname}:`, e);
          res = json({ error: "Something went wrong." }, 500);
        }
      }
      const path = new URL(req.url).pathname;
      if (config.logRequests && (path !== "/api/state" || res.status >= 500)) console.log(`${req.method} ${path} ${res.status}`);
      return res;
    };
  }

  const pub = { public: true };
  type WithId = Request & { params: { id: string } };

  // Absent when unset, so the fallback 404s it.
  const appSiteRoute: Record<string, Response> = config.appleAppIds.length
    ? { "/.well-known/apple-app-site-association": Response.json(appSiteAssociation(config.appleAppIds)) }
    : {};
  const routes = {
    "/": new Response(landingPage(config), { headers: { "Content-Type": "text/html; charset=utf-8" } }),
    "/healthz": new Response("ok\n"),
    // What's deployed: the nightly check compares `commit` with origin/main.
    "/version": Response.json({ commit: BUILD_COMMIT }),

    // -- sign-in (AuthKit authorization code + PKCE)
    // 1. The app opens /auth/authorize in ASWebAuthenticationSession with its PKCE challenge.
    "/auth/authorize": {
      GET: route((req) => {
        const q = new URL(req.url).searchParams;
        return redirect(accounts.authorizeUrl(q.get("code_challenge") ?? "", q.get("state") ?? "", q.get("screen_hint")));
      }, pub),
    },
    // 2. AuthKit redirects here (an https URL WorkOS accepts in production); bounce the code to
    //    the app's URL scheme, which ASWebAuthenticationSession is listening for.
    "/auth/callback": {
      GET: route((req) => redirect(`${config.appScheme}://auth/callback${new URL(req.url).search}`), pub),
    },
    // 3. The app sends the code and its PKCE verifier; we exchange them and start a session.
    "/api/auth/token": {
      POST: route(async (req) => {
        const data = await readJson(req);
        return json(await accounts.signIn(String(data.code ?? ""), String(data.code_verifier ?? ""),
                                          req.headers.get("user-agent") ?? "", String(data.invite ?? "")));
      }, pub),
    },
    "/api/auth/logout": {
      POST: route((req) => {
        accounts.endSession(bearer(req)!);
        return json({ ok: true });
      }),
    },

    // The app's APNs token for this session. Signing out (which ends the session) removes it, and
    // registering it again (another account signing in on that phone) moves it.
    "/api/devices": {
      POST: route(async (req, me) => {
        const data = await readJson(req);
        const token = typeof data.token === "string" ? data.token.trim().toLowerCase() : "";
        if (!/^[0-9a-f]{16,400}$/.test(token) || token.length % 2) throw new BadRequest("That isn't a device token.");
        if (data.env !== "sandbox" && data.env !== "production") throw new BadRequest("env must be sandbox or production.");
        const session = accounts.sessionHash(bearer(req)!);
        const t = now();
        asUser(me, () => db.run(
          `INSERT INTO device_tokens (token, user_id, session_hash, env, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)
             ON CONFLICT (token) DO UPDATE SET user_id = excluded.user_id, session_hash = excluded.session_hash,
               env = excluded.env, updated_at = excluded.updated_at`,
          [token, me, session, data.env, t, t],
        ));
        // `push`: whether this server sends any, so the app knows it can poll less often.
        return json({ ok: true, push: push.enabled });
      }),
    },
    "/api/devices/:token": {
      DELETE: route<Request & { params: { token: string } }>((req, me) => {
        db.run("DELETE FROM device_tokens WHERE token = ? AND user_id = ?", [decodeURIComponent(req.params.token).toLowerCase(), me]);
        return json({ ok: true });
      }),
    },

    "/api/me": {
      GET: route((_req, me) => json(accounts.mePayload(me))),
      PATCH: route(async (req, me) => {
        const { name, notifications } = await readJson(req);
        return json(asUser(me, () => {
          if (name !== undefined || notifications === undefined) accounts.rename(me, name);
          if (notifications !== undefined) accounts.setNotifications(me, notifications);
          return accounts.mePayload(me);
        }));
      }),
      // Delete the account and the links it sent, with their notes (see Accounts.deleteUser).
      DELETE: route(async (_req, me) => {
        const badgesChange = push.enabled ? push.unwatchedFrom(me) : [];
        await accounts.deleteUser(me);
        push.badges(badgesChange);
        return json({ ok: true });
      }),
    },
    // The body is the photo itself (a JPEG or PNG; the app sends a 512px JPEG), not JSON.
    "/api/me/photo": {
      PUT: route(async (req, me) => {
        if (Number(req.headers.get("content-length") ?? 0) > MAX_PHOTO_BYTES) throw new TooLarge("That photo is too big.");
        const bytes = new Uint8Array(await req.arrayBuffer());
        accounts.setPhoto(me, bytes, (change) => asUser(me, change));
        return json(accounts.mePayload(me));
      }),
      DELETE: route((_req, me) => {
        accounts.removePhoto(me, (change) => asUser(me, change));
        return json(accounts.mePayload(me));
      }),
    },
    "/api/me/claim": {
      POST: route(async (req, me) => {
        const id = String((await readJson(req)).id ?? "");
        return json(asUser(me, () => {
          accounts.claimLegacy(me, id);
          // Their links leave your To Watch, and blocks of them now hide your links too.
          const blockers = db.query("SELECT blocker FROM blocks WHERE blocked = ?").all(me) as { blocker: string }[];
          push.badges([me, ...blockers.map((b) => b.blocker)]);
          return accounts.mePayload(me);
        }));
      }),
    },

    ...appSiteRoute,
    // Invites have their own page, below.
    ...Object.fromEntries(APP_PATHS.filter((prefix) => prefix === "/g/").map((prefix) => [`${prefix}:token`, {
      GET: route<Request & { params: { token: string } }>((req) => {
        if (!TOKEN.test(req.params.token)) throw new NotFound("Not found");
        return new Response(openInAppPage(`${config.publicUrl}${prefix}${req.params.token}`, config.appStoreId),
                            { headers: { "Content-Type": "text/html; charset=utf-8" } });
      }, pub),
    }])),
    ...Object.fromEntries(["/l/:token", "/l/:token/"].map((path) => [path, {
      GET: route<Request & { params: { token: string } }>((req) => {
        const link = publicLink(req.params.token);
        return new Response(linkPage(config, link), { status: link ? 200 : 404, headers: { "Content-Type": "text/html; charset=utf-8" } });
      }, pub),
    }])),
    "/l/:token/image": {
      GET: route<Request & { params: { token: string } }>(async (req) => {
        const link = publicLink(req.params.token);
        if (!link?.thumb_type) throw new NotFound("Not found");
        const file = Bun.file(join(config.dataDir, "thumbs", String(link.id)));
        if (!await file.exists()) throw new NotFound("Not found");
        return new Response(file, { headers: { "Content-Type": link.thumb_type, "Cache-Control": "public, max-age=300",
          "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; sandbox", "X-Content-Type-Options": "nosniff" } });
      }, pub),
    },
    "/support": new Response(supportPage(config.supportEmail), { headers: { "Content-Type": "text/html; charset=utf-8" } }),
    "/privacy": new Response(privacyPage(config.supportEmail, config.sessionDays), { headers: { "Content-Type": "text/html; charset=utf-8" } }),

    "/api/wrapped": {
      GET: route((req, me) => {
        const params = new URL(req.url).searchParams;
        const parse = (key: string) => {
          const value = params.get(key);
          if (value === null || !/^-?\d+$/.test(value) || !Number.isSafeInteger(Number(value))) throw new BadRequest("Choose a valid date range.");
          return Number(value);
        };
        const start = parse("start"), end = parse("end");
        if (start >= end || end - start > 366 * 86400) throw new BadRequest("Choose a range of up to 366 days.");
        const group = params.get("group_id");
        const groupId = group === null ? null : groupOf(group, me);
        const scope = `${VISIBLE} AND added_at >= ?2 AND added_at < ?3 AND (?4 IS NULL OR group_id = ?4)`;
        const rows = db.query(`WITH scoped AS (SELECT * FROM links WHERE ${scope}),
          reaction_counts AS (SELECT r.link_id, count(*) AS total FROM reactions r
            JOIN scoped ON scoped.id = r.link_id WHERE r.emoji != '👎'
              AND NOT EXISTS (SELECT 1 FROM blocks WHERE blocker = ?1 AND blocked = r.person)
            GROUP BY r.link_id)
          SELECT scoped.*, coalesce(reaction_counts.total, 0) AS reaction_count, seen.person IS NOT NULL AS watched
          FROM scoped LEFT JOIN reaction_counts ON reaction_counts.link_id = scoped.id
          LEFT JOIN seen ON seen.link_id = scoped.id AND seen.person = ?1
          ORDER BY scoped.added_at DESC, scoped.id DESC`).all(me, start, end, groupId) as (LinkRow & { reaction_count: number; watched: number })[];
        const received = rows.filter(r => r.added_by !== me);
        const counts = (values: string[]) => {
          const result = new Map<string, number>();
          for (const value of values) result.set(value, (result.get(value) ?? 0) + 1);
          return [...result];
        };
        const compare = (a: string, b: string) => a < b ? -1 : a > b ? 1 : 0;
        const senders = db.query(`SELECT links.added_by AS id, coalesce(users.name, 'Deleted user') AS name, count(*) AS count
          FROM links LEFT JOIN users ON users.id = links.added_by WHERE ${scope} AND links.added_by != ?1
          GROUP BY links.added_by`)
          .all(me, start, end, groupId) as { id: string; name: string; count: number }[];
        const topSender = senders.sort((a, b) => b.count - a.count || compare(a.name, b.name) || compare(a.id, b.id))[0];
        const platform = counts(received.map(r => r.platform)).sort((a, b) => b[1] - a[1] || compare(a[0], b[0]))[0];
        const ranked = rows.map(r => ({ row: r, count: r.reaction_count })).sort((a, b) => b.count - a.count);
        const best = ranked[0];
        const bestSender = best && best.count > 0
          ? db.query("SELECT name FROM users WHERE id = ?").get(best.row.added_by) as { name: string } | null : null;
        return json({ start, end, received: received.length, sent: rows.length - received.length,
          watched: received.filter(r => r.watched).length,
          top_sender: topSender ?? null,
          top_platform: platform ? { platform: platform[0], count: platform[1] } : null,
          most_reacted: best && best.count > 0 ? { ...toLink(best.row), sender_name: bestSender?.name ?? "Deleted user", reactions: best.count } : null });
      }),
    },
    "/api/state": {
      GET: route((req, me) => {
        const groupId = new URL(req.url).searchParams.get("group_id");
        return json(getState(me, groupId === null ? undefined : groupOf(groupId, me)));
      }),
    },

    // Group chats (#12). Anyone in a chat can rename it and add people who are in Links; nobody
    // removes anyone else. Leaving keeps the links you sent there; the last one out deletes it.
    "/api/groups": {
      POST: route(async (req, me) => {
        const data = await readJson(req);
        const name = groupName(data.name);
        const id = asUser(me, () => {
          const members = newMembers(data.members, me, []);
          const at = now();
          const id = Number(db.run("INSERT INTO groups (name, created_by, created_at) VALUES (?, ?, ?)", [name, me, at]).lastInsertRowid);
          for (const user of [me, ...members]) {
            db.run("INSERT INTO group_members (group_id, user_id, joined_at) VALUES (?, ?, ?)", [id, user, at]);
          }
          for (const user of members) ensureDirectChatsFor(db, user, id);
          return id;
        });
        return json({ group: getGroup(id, me) }, 201);
      }),
    },
    "/api/groups/:id": {
      PATCH: route<WithId>(async (req, me) => {
        const id = groupOf(req.params.id, me);
        const data = await readJson(req);
        if (data.name === undefined && data.muted === undefined && data.muted_until === undefined) {
          throw new BadRequest("Choose a name or mute setting.");
        }
        const name = data.name === undefined ? undefined : groupName(data.name);
        if (data.muted !== undefined && typeof data.muted !== "boolean") throw new BadRequest("muted must be a boolean.");
        if (data.muted_until !== undefined && data.muted_until !== null &&
            (typeof data.muted_until !== "number" || !Number.isFinite(data.muted_until) || data.muted_until <= now())) {
          throw new BadRequest("muted_until must be a future timestamp.");
        }
        // Again once the body is in: they may have left while it uploaded.
        asUser(me, () => {
          groupOf(id, me);
          if (name !== undefined) {
            if (getGroup(id, me).direct) throw new BadRequest("Direct chats use the other person's name.");
            db.run("UPDATE groups SET name = ? WHERE id = ?", [name, id]);
          }
          if (data.muted !== undefined) {
            db.run("UPDATE group_members SET muted = ?, muted_until = ? WHERE group_id = ? AND user_id = ?",
              [data.muted ? 1 : 0, data.muted ? data.muted_until ?? null : null, id, me]);
          } else if (data.muted_until !== undefined) {
            db.run("UPDATE group_members SET muted_until = ? WHERE group_id = ? AND user_id = ?", [data.muted_until, id, me]);
          }
        });
        return json({ group: getGroup(id, me) });
      }),
      // Leave the chat.
      DELETE: route<WithId>((req, me) => {
        const id = groupOf(req.params.id, me);
        const orphaned = asUser(me, () => {
          if (getGroup(id, me).direct && sharesGroupWithDirectPeer(db, id, me)) {
            throw new BadRequest("Leave your shared group chats before leaving this direct chat.");
          }
          db.run("DELETE FROM group_members WHERE group_id = ? AND user_id = ?", [id, me]);
          return deleteEmptyGroups(db);
        });
        for (const link of orphaned) rmSync(join(config.dataDir, "thumbs", String(link)), { force: true });
        push.badges([me]); // the chat's links leave their To Watch; nobody else's change
        return json({ ok: true });
      }),
    },
    "/api/groups/:id/members": {
      POST: route<WithId>(async (req, me) => {
        const id = groupOf(req.params.id, me);
        const data = await readJson(req);
        const added = asUser(me, () => {
          groupOf(id, me); // still in it now the body is in
          const group = getGroup(id, me);
          if (group.direct) throw new BadRequest("Start a group chat to add more people.");
          const added = newMembers(data.members, me, group.members);
          const at = now();
          for (const user of added) {
            db.run("INSERT OR IGNORE INTO group_members (group_id, user_id, joined_at) VALUES (?, ?, ?)", [id, user, at]);
          }
          for (const user of added) ensureDirectChatsFor(db, user, id);
          return added;
        });
        push.badges(added); // the chat's links land in their To Watch
        return json({ group: getGroup(id, me) });
      }),
    },

    // Invites (#5): anyone who's in can let a friend in. The link (with its token) is only in the
    // POST's reply; the server keeps its hash. Only POST /api/auth/token and /api/invites/accept use an invite up.
    "/api/invites": {
      GET: route((_req, me) => json({ invites: accounts.pendingInvites(me) })),
      POST: route(async (req, me) => {
        const { email, group_id } = await readJson(req);
        const { invite, token } = asUser(me, () => {
          const group = group_id === undefined || group_id === null ? null : getGroup(groupOf(group_id, me), me);
          if (group?.direct) throw new BadRequest("You can't invite someone into a direct chat.");
          return accounts.createInvite(me, email, group?.id ?? null);
        });
        return json({ invite: { ...invite, url: `${config.publicUrl}/invite/${token}` } }, 201);
      }),
    },
    // Someone who's already in opens an invite link: they join its chat (see Accounts.joinWithInvite).
    "/api/invites/accept": {
      POST: route(async (req, me) => {
        const { token } = await readJson(req);
        const id = asUser(me, () => accounts.joinWithInvite(me, String(token ?? "")));
        if (id !== null) push.badges([me]); // the chat's links land in their To Watch
        return json({ group: id === null ? null : getGroup(id, me) });
      }),
    },
    "/api/invites/:id": {
      DELETE: route<WithId>((req, me) => {
        if (!/^\d+$/.test(req.params.id) || !accounts.revokeInvite(me, Number(req.params.id))) {
          throw new NotFound("That invite was already used or cancelled.");
        }
        return json({ invites: accounts.pendingInvites(me) });
      }),
    },
    "/invite/:token": {
      GET: (req: Request & { params: { token: string } }) => {
        const { token } = req.params;
        if (!INVITE_TOKEN_RE.test(token)) return new Response("Not found\n", { status: 404 });
        const invite = accounts.pendingInvite(token);
        return new Response(invitePage(config, token, invite), {
          status: invite ? 200 : 404,
          headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" },
        });
      },
    },
    "/icon.png": new Response(Bun.file(iconPath), {
      headers: { "Content-Type": "image/png", "Cache-Control": "public, max-age=86400" },
    }),
    "/app-preview.png": new Response(Bun.file(appPreviewPath), {
      headers: { "Content-Type": "image/png", "Cache-Control": "public, max-age=86400" },
    }),

    // Report a link, comment or person. Links and comments are hidden for the reporter at once.
    // The owner reads reports with `links-server reports` (and in the log).
    "/api/reports": {
      POST: route(async (req, me) => {
        const data = await readJson(req);
        if (!REPORT_REASONS.includes(data.reason)) throw new BadRequest("Pick a reason for the report.");
        const details = clipText(data.details, 1000);
        const { id, label, linkId } = asUser(me, () => {
          const target = reportTarget(data, me);
          const { changes, lastInsertRowid } = db.run(
            "INSERT OR IGNORE INTO reports (reporter, link_id, comment_id, user_id, reason, details, snapshot, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [me, target.link_id, target.comment_id, target.user_id, data.reason, details, JSON.stringify(target.snapshot), now()],
          );
          // Copied only for a report that was saved, so a repeat (ignored) leaves no stray copy.
          const photo = "photo" in target ? target.photo : null;
          if (changes && photo && !accounts.keepPhotoForReport(photo)) {
            db.run("UPDATE reports SET snapshot = json_set(snapshot, '$.photo_copy', NULL) WHERE id = ?", [lastInsertRowid]);
          }
          return { id: changes ? Number(lastInsertRowid) : null, label: target.label, linkId: target.link_id };
        });
        if (id !== null) {
          console.log(`report ${id}: ${data.reason}, ${label}, by ${me}`);
          if (linkId !== null) push.badges([me]); // a reported link leaves To Watch
        }
        return json({ ok: true }, 201);
      }),
    },

    // One-way: the blocker stops seeing the blocked person's links, marks and reactions. The
    // blocked person isn't told, and sees no change.
    "/api/blocks": {
      POST: route(async (req, me) => {
        const id = String((await readJson(req)).user_id ?? "");
        if (id === me) throw new BadRequest("You can't block yourself.");
        asUser(me, () => {
          // Only someone I can see: a block is how blocked people stay in my `users`.
          if (!db.query("SELECT 1 FROM users WHERE id = ?").get(id) || !sees(me, id)) throw new NotFound("That person isn't in Links anymore.");
          db.run("INSERT OR IGNORE INTO blocks (blocker, blocked, created_at) VALUES (?, ?, ?)", [me, id, now()]);
        });
        push.badges([me]);
        return json({ blocked: [...blockedBy(me)] });
      }),
    },
    // The id is URL-encoded (legacy ones look like legacy:<name>); Bun has already decoded the param.
    "/api/blocks/:user_id": {
      DELETE: route<Request & { params: { user_id: string } }>((req, me) => {
        db.run("DELETE FROM blocks WHERE blocker = ? AND blocked = ?", [me, req.params.user_id]);
        push.badges([me]);
        return json({ blocked: [...blockedBy(me)] });
      }),
    },

    "/api/links": {
      POST: route(async (req, me) => {
        const data = await readJson(req);
        const { link, duplicate } = await addLink(data.url ?? data.text, data.note, data.group_id, me);
        return json({ link, duplicate }, duplicate ? 200 : 201);
      }),
    },
    "/api/links/:id": {
      // Only the sender writes a link's note, so nobody someone blocked can put words under it.
      PATCH: route<WithId>(async (req, me) => {
        const id = linkId(req, me);
        const note = clipText((await readJson(req)).note, 500);
        if (sender(id) !== me) throw new AuthError("Only the person who sent a link can change its note.", 403);
        accounts.screen(note, "note");
        asUser(me, () => {
          stillSees(id, me);
          db.run("UPDATE links SET note = ? WHERE id = ?", [note, id]);
        });
        return json({ link: getLink(id, me) });
      }),
      DELETE: route<WithId>((req, me) => {
        const id = linkId(req, me);
        if (hasBlocked(sender(id), me)) throw new AuthError("You can't delete this link.", 403);
        const badgesChange = push.enabled ? push.unwatchedBy(id) : [];
        deleteLink(db, config.dataDir, id);
        push.badges(badgesChange);
        return json({ ok: true });
      }),
    },
    "/api/links/:id/comments": {
      GET: route<WithId>((req, me) => json({ comments: commentsFor(linkId(req, me), me) })),
      POST: route<WithId>(async (req, me) => {
        const id = linkId(req, me);
        const body = commentBody((await readJson(req)).body);
        const comment = asUser(me, () => {
          stillSees(id, me);
          const at = now();
          const { lastInsertRowid } = db.run("INSERT INTO comments (link_id, person, body, created_at) VALUES (?, ?, ?, ?)", [id, me, body, at]);
          // Replying means they've seen it. No "saw your link" push: the comment alert covers it.
          const nowSeen = db.run("INSERT OR IGNORE INTO seen (link_id, person, seen_at) VALUES (?, ?, ?)", [id, me, at]).changes > 0;
          const row = db.query("SELECT * FROM comments WHERE id = ?").get(lastInsertRowid) as CommentRow;
          return { row, leftToWatch: nowSeen && (db.query("SELECT added_by FROM links WHERE id = ?").get(id) as { added_by: string }).added_by !== me };
        });
        if (comment.leftToWatch) push.badges([me]);
        if (push.enabled) track(Promise.resolve().then(() => push.newComment(comment.row.id)));
        return json({ comment: comment.row }, 201);
      }),
    },
    "/api/comments/:id": {
      PATCH: route<WithId>(async (req, me) => {
        const body = commentBody((await readJson(req)).body);
        const comment = asUser(me, () => {
          const row = commentOf(req.params.id, me);
          if (row.person !== me) throw new AuthError("Only the author can change a comment.", 403);
          db.run("UPDATE comments SET body = ?, edited_at = ? WHERE id = ?", [body, now(), row.id]);
          return commentOf(req.params.id, me);
        });
        return json({ comment });
      }),
      DELETE: route<WithId>((req, me) => {
        const row = commentOf(req.params.id, me);
        if (row.person !== me) throw new AuthError("Only the author can delete a comment.", 403);
        db.run("DELETE FROM comments WHERE id = ?", [row.id]);
        return json({ ok: true });
      }),
    },
    "/api/links/:id/refresh": {
      POST: route<WithId>((req, me) => {
        const id = linkId(req, me);
        const row = db.query("SELECT * FROM links WHERE id = ?").get(id) as LinkRow;
        if (row.meta !== "pending") {
          db.run("UPDATE links SET meta = 'pending' WHERE id = ?", [id]);
          startMetadataFetch(id, row.url, row.platform);
        }
        return json({ link: getLink(id, me) });
      }),
    },
    "/api/links/:id/nudge": {
      POST: route<WithId>(async (req, me) => {
        const id = linkId(req, me);
        const { people } = await readJson(req);
        if (people !== undefined && (!Array.isArray(people) || people.some((p) => typeof p !== "string"))) {
          throw new BadRequest("Choose people to nudge.");
        }
        const nudged = asUser(me, () => {
          stillSees(id, me);
          if (sender(id) !== me) throw new AuthError("Only the person who sent a link can nudge someone.", 403);
          const link = db.query("SELECT group_id FROM links WHERE id = ?").get(id) as { group_id: number };
          const candidates = db.query(`SELECT m.user_id, n.nudged_at FROM group_members m
            LEFT JOIN nudges n ON n.link_id = ?1 AND n.person = m.user_id
            WHERE m.group_id = ?2 AND m.user_id != ?3
              AND NOT EXISTS (SELECT 1 FROM seen WHERE link_id = ?1 AND person = m.user_id)
              AND NOT EXISTS (SELECT 1 FROM reports WHERE link_id = ?1 AND reporter = m.user_id)
              AND NOT EXISTS (SELECT 1 FROM blocks WHERE
                (blocker = ?3 AND blocked = m.user_id) OR (blocker = m.user_id AND blocked = ?3))`)
            .all(id, link.group_id, me) as { user_id: string; nudged_at: number | null }[];
          const requested = candidates.filter((p) => !people?.length || people.includes(p.user_id));
          const at = now();
          const eligible = requested.filter((p) => p.nudged_at === null || p.nudged_at <= at - 86400);
          if (!eligible.length) {
            if (requested.length) throw new AuthError("You've already nudged them. Try again after 24 hours.", 429);
            throw new BadRequest("There's nobody to nudge right now.");
          }
          for (const p of eligible) db.run(`INSERT INTO nudges (link_id, person, nudged_at) VALUES (?, ?, ?)
            ON CONFLICT(link_id, person) DO UPDATE SET nudged_at = excluded.nudged_at`, [id, p.user_id, at]);
          return eligible.map((p) => p.user_id);
        });
        if (push.enabled) track(Promise.resolve().then(() => push.nudge(id, nudged)));
        return json({ nudged, link: getLink(id, me) });
      }),
    },
    "/api/links/:id/seen": {
      POST: route<WithId>(async (req, me) => {
        const id = linkId(req, me);
        const seen = (await readJson(req)).seen ?? true;
        const watched = asUser(me, () => {
          stillSees(id, me);
          if (seen) {
            return db.run("INSERT OR IGNORE INTO seen (link_id, person, seen_at) VALUES (?, ?, ?)", [id, me, now()]).changes > 0;
          }
          db.run("DELETE FROM seen WHERE link_id = ? AND person = ?", [id, me]);
          return false;
        });
        push.badges([me]);
        if (watched) push.activity(id, me, "watched");
        return json({ link: getLink(id, me) });
      }),
    },
    "/api/links/:id/react": {
      POST: route<WithId>(async (req, me) => {
        const id = linkId(req, me);
        const emoji = (await readJson(req)).emoji;
        const changed = asUser(me, () => {
          stillSees(id, me);
          if (typeof emoji === "string" && EMOJIS.has(emoji)) {
            const before = db.query("SELECT emoji FROM reactions WHERE link_id = ? AND person = ?").get(id, me) as { emoji: string } | null;
            db.run("INSERT OR REPLACE INTO reactions (link_id, person, emoji) VALUES (?, ?, ?)", [id, me, emoji]);
            return before?.emoji !== emoji;
          }
          db.run("DELETE FROM reactions WHERE link_id = ? AND person = ?", [id, me]);
          return false;
        });
        if (changed) push.activity(id, me, "reacted");
        return json({ link: getLink(id, me) });
      }),
    },

    // Public like /l/:token/image: only people shown the photo's random address can load it, and
    // AsyncImage sends no session. A new photo gets a new address, so this one never changes.
    "/photos/:token": {
      GET: route<Request & { params: { token: string } }>(async (req) => {
        const token = req.params.token;
        if (!TOKEN.test(token) || !accounts.photoOwner(token)) throw new NotFound("Not found");
        const file = Bun.file(accounts.photoPath(token));
        if (!(await file.exists())) throw new NotFound("Not found");
        const bytes = await file.bytes();
        return new Response(bytes, { headers: { "Content-Type": photoType(bytes) ?? "application/octet-stream",
          "Cache-Control": "public, max-age=31536000, immutable",
          "Content-Security-Policy": "default-src 'none'; sandbox", "X-Content-Type-Options": "nosniff" } });
      }, pub),
    },
    "/thumbs/:id": { GET: route<WithId>(serveThumb) },
    // The version only changes the URL, so phones re-download a replaced thumbnail.
    "/thumbs/:id/:v": { GET: route<WithId>(serveThumb) },
  };

  function serveThumb(req: WithId, me: string) {
    const id = linkId(req, me);
    const row = db.query("SELECT thumb_type FROM links WHERE id = ?").get(id) as { thumb_type: string | null };
    const file = Bun.file(join(config.dataDir, "thumbs", String(id)));
    if (!row.thumb_type) throw new NotFound("Not found");
    return file.exists().then((exists) => {
      if (!exists) throw new NotFound("Not found");
      return new Response(file, { headers: { "Content-Type": row.thumb_type!, "Cache-Control": "private, max-age=2592000",
        "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; sandbox", "X-Content-Type-Options": "nosniff" } });
    });
  }

  function publicLink(token: string): LinkRow | null {
    if (!TOKEN.test(token)) return null;
    return db.query("SELECT * FROM links WHERE share_token = ?").get(token) as LinkRow | null;
  }

  /** Resolves once in-flight preview fetches and pushes finish (tests use this). */
  const idle = async () => { while (pending.size) await Promise.all([...pending]); };

  return {
    db,
    accounts,
    routes,
    push,
    idle,
    /** Shutting down: sends the pushes still waiting, then waits for in-flight work, up to `timeoutMs`. */
    drain: async (timeoutMs: number) => {
      push.flush();
      await Promise.race([idle(), Bun.sleep(timeoutMs)]);
    },
    fallback: route(() => { throw new NotFound("Not found"); }, pub),
  };
}

export function startServer(config: Config, opts: AppOptions = {}) {
  const app = createApp(config, opts);
  const named = new Set((app.db.query("SELECT photo FROM users WHERE photo <> ''").all() as { photo: string }[]).map((r) => r.photo));
  const evidence = new Set((app.db.query("SELECT json_extract(snapshot, '$.photo_copy') AS copy FROM reports WHERE json_extract(snapshot, '$.photo_copy') IS NOT NULL")
    .all() as { copy: string }[]).map((r) => r.copy));
  const photos = readdirSync(join(config.dataDir, "photos"), { withFileTypes: true })
    .filter((f) => f.isFile() && (f.name.endsWith(".part") || !named.has(f.name))).map((f) => f.name);
  const reported = readdirSync(join(config.dataDir, "report-photos"), { withFileTypes: true })
    .filter((f) => f.isFile() && !evidence.has(join("report-photos", f.name))).map((f) => f.name);
  for (const f of photos) rmSync(join(config.dataDir, "photos", f));
  for (const f of reported) rmSync(join(config.dataDir, "report-photos", f));
  if (photos.length || reported.length) console.log(`removed ${photos.length} orphaned profile photo(s) and ${reported.length} report photo(s)`);
  const server = Bun.serve({
    port: config.port,
    hostname: config.hostname,
    // Outlast Caddy's 2m upstream keep-alive and URLSession reuse: an expired connection
    // loses non-idempotent requests (502 through Caddy, "connection lost" directly).
    idleTimeout: 255,
    // JSON bodies stop at readJson's 64 KB; only PUT /api/me/photo takes more.
    maxRequestBodySize: MAX_PHOTO_BYTES + 65536,
    routes: app.routes,
    fetch: app.fallback,
  });
  return { app, server };
}
