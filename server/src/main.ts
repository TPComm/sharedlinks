#!/usr/bin/env bun
/**
 * Links API: the backend for the Links iOS app.
 *
 *   links-server                                    start the server (http://localhost:8000)
 *   links-server mint-session you@example.com [Name]   print a session token (admin / Simulator)
 *   links-server delete-user you@example.com         delete an account (its links stay, from "Deleted user")
 *   links-server backup [dir]                        snapshot the database (keeps the newest 14)
 *   links-server reports                             list open reports (what was reported, by whom)
 *   links-server reports resolve <id> [--remove]     mark one handled; --remove deletes the link for everyone
 *   links-server version                             print the git commit it was built from (also on /version)
 *
 * In development, `bun src/main.ts ...` does the same as the compiled `links-server`.
 *
 * Env: WORKOS_CLIENT_ID (required for sign-in), WORKOS_API_KEY (optional with PKCE),
 *      PUBLIC_URL, ALLOWED_EMAILS, SUPPORT_EMAIL, APP_SCHEME, PORT, HOST, DATA_DIR, SESSION_DAYS
 */
import { mkdirSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { Accounts } from "./accounts.ts";
import { startServer } from "./app.ts";
import { configFromEnv } from "./config.ts";
import { openDatabase } from "./db.ts";
import { BadRequest } from "./links.ts";
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
  const db = openDatabase(config.dataDir);
  console.log(new Accounts(db, config).mintSession(email, name.join(" ") || undefined));
  db.close();
} else if (command === "delete-user") {
  // What the app's Delete Account does, for someone who asks by email instead.
  const [email, ...extra] = rest;
  if (!email || extra.length) {
    console.error("usage: links-server delete-user <email>");
    process.exit(1);
  }
  const db = openDatabase(config.dataDir);
  const accounts = new Accounts(db, config);
  const users = accounts.usersWithEmail(email);
  for (const user of users) {
    const { links, workos } = await accounts.deleteUser(user.id);
    console.log(`deleted ${user.name} (${user.id}); ${links} sent link${links === 1 ? "" : "s"} kept as "Deleted user"; WorkOS user: ${workos}`);
  }
  db.close();
  if (!users.length) {
    console.error(`no account with the email ${email}`);
    process.exit(1);
  }
} else if (command === "backup") {
  // A consistent copy even while the server is running (VACUUM INTO reads a snapshot).
  const dir = rest[0] ?? join(config.dataDir, "backups");
  mkdirSync(dir, { recursive: true });
  const file = join(dir, `links-${new Date().toISOString().slice(0, 10)}.db`);
  rmSync(file, { force: true });
  const db = openDatabase(config.dataDir);
  db.run("VACUUM INTO ?", [file]);
  db.close();
  const old = readdirSync(dir).filter((f) => /^links-\d{4}-\d{2}-\d{2}\.db$/.test(f)).sort().slice(0, -14);
  for (const f of old) rmSync(join(dir, f));
  console.log(`backed up to ${file}`);
} else if (command === "reports") {
  // App Store guideline 1.2: "timely responses" to reports. Each new one is also logged (journalctl -u links).
  const db = openDatabase(config.dataDir);
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
      const report = resolveReport(db, config.dataDir, Number(id), remove);
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
  if (!config.allowedEmails.length) {
    console.warn("warning: ALLOWED_EMAILS isn't set, so anyone who can sign in to your AuthKit can see and add links.");
  }
  const { server } = startServer(config);
  console.log(`Links API running on ${server.url} (sign-in redirect: ${config.publicUrl}/auth/callback)`);
  for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.on(signal, () => {
      server.stop();
      process.exit(0);
    });
  }
}
