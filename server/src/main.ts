#!/usr/bin/env bun
/**
 * Links API: the backend for the Links iOS app.
 *
 *   links-server                                    start the server (http://localhost:8000)
 *   links-server mint-session you@example.com [Name]   print a session token (admin / Simulator)
 *   links-server invite [friend@example.com]         print an invite link (the first one on a new server)
 *   links-server delete-user you@example.com         delete an account and the links it sent
 *   links-server claim [you@example.com Name]        list legacy people, or let that account claim one
 *   links-server backup [dir]                        snapshot the database (keeps the newest 14)
 *   links-server reports                             list open reports (what was reported, by whom)
 *   links-server reports resolve <id> [--remove]     mark one handled; --remove deletes the link for everyone
 *   links-server version                             print the git commit it was built from (also on /version)
 *
 * In development, `bun src/main.ts ...` does the same as the compiled `links-server`.
 *
 * Env: WORKOS_CLIENT_ID (required for sign-in), WORKOS_API_KEY (optional with PKCE),
 *      PUBLIC_URL, SUPPORT_EMAIL, APPLE_APP_IDS, APP_STORE_ID, APP_SCHEME, PORT, HOST, DATA_DIR,
 *      SESSION_DAYS, APNS_TEAM_ID, APNS_TOPIC (the app's bundle id), APNS_KEY_ID + APNS_KEY_FILE (one
 *      .p8 key for Sandbox and Production); push is off without them
 */
import { mkdirSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { Accounts } from "./accounts.ts";
import { startServer } from "./app.ts";
import { configFromEnv } from "./config.ts";
import { openDatabase } from "./db.ts";
import { BadRequest } from "./links.ts";
import { Pusher, pushEnabled } from "./push.ts";
import { formatReport, openReports, resolveReport } from "./moderation.ts";
import { BUILD_COMMIT } from "./version.ts";

const config = configFromEnv();
const [command, ...rest] = process.argv.slice(2);

if (command === "mint-session") {
  const [email, ...name] = rest;
  if (!email) {
    console.error("usage: links-server mint-session <email> [name]");
    process.exit(1);
  }
  const db = openDatabase(config.dataDir, config.legacyAllowedEmails);
  console.log(new Accounts(db, config).mintSession(email, name.join(" ") || undefined));
  db.close();
} else if (command === "invite") {
  // Invites are the only way in, so this is how the first person (and anyone else, by email) gets one.
  const [email, ...extra] = rest;
  if (extra.length) {
    console.error("usage: links-server invite [email]");
    process.exit(1);
  }
  const db = openDatabase(config.dataDir, config.legacyAllowedEmails);
  try {
    const { invite, token } = new Accounts(db, config).createInvite(null, email);
    const days = Math.round((invite.expires_at - invite.created_at) / 86400);
    console.log(`${config.publicUrl}/invite/${token}`);
    console.error(invite.email
      ? `works for ${days} days; signing in with ${invite.email} (verified) uses it even without the link`
      : `works for ${days} days, once, for whoever signs in with it`);
  } catch (e) {
    if (!(e instanceof BadRequest)) throw e;
    console.error(e.message);
    process.exit(1);
  } finally {
    db.close();
  }
} else if (command === "delete-user") {
  // What the app's Delete Account does, for someone who asks by email instead.
  const [email, ...extra] = rest;
  if (!email || extra.length) {
    console.error("usage: links-server delete-user <email>");
    process.exit(1);
  }
  const db = openDatabase(config.dataDir, config.legacyAllowedEmails);
  const accounts = new Accounts(db, config);
  const users = accounts.usersWithEmail(email);
  // Their links leave others' To Watch; the running server doesn't see this, so badge from here.
  const tasks: Promise<void>[] = [];
  const push = new Pusher(db, config, accounts, (t) => { tasks.push(t); }, { badgeDelayMs: 0 });
  for (const user of users) {
    const unwatched = push.enabled ? push.unwatchedFrom(user.id) : [];
    const { links, workos } = await accounts.deleteUser(user.id);
    push.badges(unwatched);
    console.log(`deleted ${user.name} (${user.id}); ${links} sent link${links === 1 ? "" : "s"} deleted; WorkOS user: ${workos}`);
  }
  await Promise.all(tasks);
  push.close();
  db.close();
  if (!users.length) {
    console.error(`no account with the email ${email}`);
    process.exit(1);
  }
} else if (command === "claim") {
  // A pre-sign-in person's links go only to the account an admin names, never to whoever types the name.
  const [email, ...name] = rest;
  if (email && !name.length) {
    console.error("usage: links-server claim [<email> <legacy name>]");
    process.exit(1);
  }
  const db = openDatabase(config.dataDir, config.legacyAllowedEmails);
  const accounts = new Accounts(db, config);
  try {
    if (!email) {
      const people = accounts.legacyPeople();
      console.log(people.length
        ? people.map((p) => `${p.name}: ${p.links} link${p.links === 1 ? "" : "s"}${p.claimer ? `; ${p.claimer} may claim` : ""}`).join("\n")
        : "no unclaimed legacy people");
    } else {
      const { user, legacy } = accounts.approveClaim(email, name.join(" "));
      console.log(`${user.name} (${user.email}) may now claim ${legacy.name}: in the app, Claim Earlier Links… in the account menu`);
    }
  } catch (e) {
    if (!(e instanceof BadRequest)) throw e;
    console.error(e.message);
    process.exit(1);
  } finally {
    db.close();
  }
} else if (command === "backup") {
  // A consistent copy even while the server is running (VACUUM INTO reads a snapshot).
  const dir = rest[0] ?? join(config.dataDir, "backups");
  mkdirSync(dir, { recursive: true });
  const file = join(dir, `links-${new Date().toISOString().slice(0, 10)}.db`);
  rmSync(file, { force: true });
  const db = openDatabase(config.dataDir, config.legacyAllowedEmails);
  db.run("VACUUM INTO ?", [file]);
  db.close();
  const old = readdirSync(dir).filter((f) => /^links-\d{4}-\d{2}-\d{2}\.db$/.test(f)).sort().slice(0, -14);
  for (const f of old) rmSync(join(dir, f));
  console.log(`backed up to ${file}`);
} else if (command === "reports") {
  // App Store guideline 1.2: "timely responses" to reports. Each new one is also logged (journalctl -u links).
  const db = openDatabase(config.dataDir, config.legacyAllowedEmails);
  try {
    if (!rest.length) {
      const reports = openReports(db);
      console.log(reports.length ? reports.map(formatReport).join("\n\n") : "no open reports");
    } else {
      const [sub, id, ...flags] = rest;
      const remove = flags.includes("--remove");
      if (sub !== "resolve" || !/^\d+$/.test(id ?? "") || flags.some((f) => f !== "--remove")) {
        console.error("usage: links-server reports [resolve <id> [--remove]]");
        process.exit(1);
      }
      // The running server doesn't see this, so badge the people the link leaves To Watch for from here.
      const tasks: Promise<void>[] = [];
      const push = new Pusher(db, config, new Accounts(db, config), (t) => { tasks.push(t); }, { badgeDelayMs: 0 });
      let unwatched: string[] = [];
      const report = resolveReport(db, config.dataDir, Number(id), remove, (linkId) => {
        if (push.enabled) unwatched = push.unwatchedBy(linkId);
      });
      push.badges(unwatched);
      await Promise.all(tasks);
      push.close();
      console.log(`report #${report.id} resolved: ${report.resolution}${remove ? ` (link ${report.link_id} deleted)` : ""}`);
    }
  } catch (e) {
    if (!(e instanceof BadRequest)) throw e;
    console.error(e.message);
    process.exit(1);
  } finally {
    db.close();
  }
} else if (command === "version") {
  console.log(BUILD_COMMIT);
} else if (command) {
  console.error(`unknown command: ${command}`);
  process.exit(1);
} else {
  if (!config.workosClientId) console.warn("warning: WORKOS_CLIENT_ID isn't set, so nobody can sign in.");
  if (!pushEnabled(config)) {
    console.warn("warning: APNS_TEAM_ID, APNS_TOPIC and an APNs key (APNS_KEY_ID/APNS_KEY_FILE) aren't all set, so push notifications are off.");
  }
  if (config.legacyAllowedEmails.length) {
    console.warn("note: ALLOWED_EMAILS is only read once, to keep those already signed up who are on it; invites are the only way in now, so it can go.");
  }
  const { app, server } = startServer(config);
  if (!app.db.query("SELECT 1 FROM users WHERE member = 1").get()) {
    console.warn("warning: nobody is in yet. Run `links-server invite you@example.com`, then sign in with that email.");
  }
  console.log(`Links API running on ${server.url} (sign-in redirect: ${config.publicUrl}/auth/callback)`);
  let stopping = false;
  for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.on(signal, async () => {
      if (stopping) process.exit(0); // a second signal: stop waiting
      stopping = true;
      server.stop();
      // A deploy restarts the server: pushes still waiting to be merged would otherwise be lost.
      await app.drain(5000);
      process.exit(0);
    });
  }
}
