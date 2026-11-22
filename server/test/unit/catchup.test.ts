import { afterEach, beforeEach, expect, setSystemTime, spyOn, test } from "bun:test";
import { Accounts } from "../../src/accounts.ts";
import { configFromEnv } from "../../src/config.ts";
import { defaultGroup, openDatabase } from "../../src/db.ts";
import { Pusher } from "../../src/push.ts";
import { tempDir } from "./helpers.ts";

let tmp: ReturnType<typeof tempDir>;
let db: ReturnType<typeof openDatabase>;
let accounts: Accounts;
let push: Pusher;
let bodies: any[];
let group: number;
beforeEach(() => {
  tmp = tempDir();
  db = openDatabase(tmp.dir);
  const config = configFromEnv({ APNS_TEAM_ID: "team", APNS_TOPIC: "topic", APNS_KEY_ID: "key",
    APNS_KEY_FILE: "/unused", CATCHUP_INTERVAL_MS: "0" });
  accounts = new Accounts(db, config);
  push = new Pusher(db, config, accounts, () => {});
  bodies = [];
  spyOn(push, "devices").mockImplementation((user_id) => [{ token: user_id, user_id, env: "production", updated_at: 1 }]);
  spyOn(push, "send").mockImplementation(async (_device, _type, body) => { bodies.push(JSON.parse(body)); });
  group = defaultGroup(db);
  for (const name of ["Maya", "Alex", "Kim", "Sam", "Reader", "Other"]) {
    db.run("INSERT INTO users (id, name, created_at, member) VALUES (?, ?, 1, 1)", [name, name]);
    db.run("INSERT INTO group_members (group_id, user_id, joined_at) VALUES (?, ?, 1)", [group, name]);
    const session = accounts.newSession(name);
    db.run("INSERT INTO device_tokens (token, user_id, session_hash, env, created_at, updated_at) VALUES (?, ?, ?, 'production', 1, 1)",
      [name, name, accounts.sessionHash(session)]);
  }
});
afterEach(() => { setSystemTime(); push.close(); db.close(); tmp.cleanup(); });
const add = (sender: string) => {
  const result = db.run("INSERT INTO links (url, platform, added_by, added_at, group_id) VALUES (?, 'web', ?, ?, ?)",
    [`https://example.com/${crypto.randomUUID()}`, sender, Date.now() / 1000, group]);
  return Number(result.lastInsertRowid);
};
const enable = (user = "Reader", zone = "UTC", minute = 480) =>
  db.run("UPDATE users SET catchup_minute = ?, catchup_tz = ?, catchup_sent_on = NULL WHERE id = ?", [minute, zone, user]);

test("new links keep badges but suppress alerts for catch-up recipients", async () => {
  enable();
  const badge = spyOn(push, "badges");
  await push.newLink(add("Maya"));
  expect(badge).toHaveBeenCalledWith(["Reader"]);
  expect(push.send).not.toHaveBeenCalledWith(expect.objectContaining({ user_id: "Reader" }), "alert", expect.any(String));
  expect(bodies.filter((b) => b.link_id && b.aps.alert).length).toBeGreaterThan(0);
});

test("summaries count links and list distinct senders newest first, only once per local day", async () => {
  enable();
  add("Alex"); add("Maya"); add("Maya");
  await push.catchUp(new Date("2026-03-08T07:59:00Z"));
  expect(bodies).toHaveLength(0);
  await push.catchUp(new Date("2026-03-08T08:00:00Z"));
  expect(bodies).toEqual([{ aps: { alert: { title: "Daily Catch-Up", body: "3 new links from Maya and Alex" },
    badge: 3, sound: "default", "thread-id": "catchup" }, open: "queue" }]);
  await push.catchUp(new Date("2026-03-08T20:00:00Z"));
  expect(bodies).toHaveLength(1);
  add("Kim"); add("Sam");
  await push.catchUp(new Date("2026-03-09T08:00:00Z"));
  expect(bodies[1].aps.alert.body).toBe("5 new links from Sam, Kim and 2 others");
});

test("retained links without senders count towards summaries without inventing names", async () => {
  enable();
  add("deleted"); add("deleted"); add("deleted");
  expect(push.toWatch("Reader")).toBe(3);
  await push.catchUp(new Date("2026-03-08T08:00:00Z"));
  expect(bodies[0].aps.alert.body).toBe("3 new links");
  expect(bodies[0].aps.badge).toBe(3);
  add("Maya");
  await push.catchUp(new Date("2026-03-09T08:00:00Z"));
  expect(bodies[1].aps.alert.body).toBe("4 new links from Maya");
  expect(bodies[1].aps.badge).toBe(4);
});

test("empty queues and muted chats stay silent but record the run", async () => {
  enable();
  await push.catchUp(new Date("2026-03-08T08:00:00Z"));
  expect(bodies).toHaveLength(0);
  expect(db.query("SELECT catchup_sent_on FROM users WHERE id = 'Reader'").get()).toEqual({ catchup_sent_on: "2026-03-08" });
  add("Maya");
  db.run("UPDATE group_members SET muted = 1 WHERE user_id = 'Reader'");
  await push.catchUp(new Date("2026-03-09T08:00:00Z"));
  expect(bodies).toHaveLength(0);
});

test("time zones and a DST transition use the local clock", async () => {
  enable("Reader", "Australia/Sydney");
  enable("Other", "America/New_York");
  add("Maya");
  await push.catchUp(new Date("2026-03-08T11:00:00Z"));
  expect(bodies).toHaveLength(1);
  await push.catchUp(new Date("2026-03-08T12:00:00Z"));
  expect(bodies).toHaveLength(2);
  expect(db.query("SELECT catchup_sent_on FROM users WHERE id = 'Other'").get()).toEqual({ catchup_sent_on: "2026-03-08" });
  enable("Reader", "Australia/Sydney");
  enable("Other", "America/New_York");
  bodies = [];
  await push.catchUp(new Date("2026-03-07T21:00:00Z"));
  expect(bodies).toHaveLength(2);
  expect(db.query("SELECT catchup_sent_on FROM users WHERE id = 'Reader'").get()).toEqual({ catchup_sent_on: "2026-03-08" });
  expect(db.query("SELECT catchup_sent_on FROM users WHERE id = 'Other'").get()).toEqual({ catchup_sent_on: "2026-03-07" });
});

test("moving the time later or changing zone preserves today's completed run", async () => {
  setSystemTime(new Date("2026-03-08T07:00:00Z"));
  add("Maya");
  accounts.setNotifications("Reader", { catchup: { time: "08:00", timeZone: "UTC" } });
  setSystemTime(new Date("2026-03-08T09:00:00Z"));
  await push.catchUp(new Date());
  expect(bodies).toHaveLength(1);
  accounts.setNotifications("Reader", { catchup: { time: "18:00", timeZone: "UTC" } });
  await push.catchUp(new Date("2026-03-08T18:00:00Z"));
  expect(bodies).toHaveLength(1);
  accounts.setNotifications("Reader", { catchup: { time: "18:00", timeZone: "Europe/London" } });
  await push.catchUp(new Date("2026-03-08T18:00:00Z"));
  expect(bodies).toHaveLength(1);
  await push.catchUp(new Date("2026-03-09T18:00:00Z"));
  expect(bodies).toHaveLength(2);
});

test("enabling after the chosen time waits until tomorrow; unchanged settings do not reset delivery", async () => {
  setSystemTime(new Date("2026-03-08T12:00:00Z"));
  add("Maya");
  accounts.setNotifications("Reader", { catchup: { time: "08:00", timeZone: "UTC" } });
  await push.catchUp(new Date());
  expect(bodies).toHaveLength(0);
  await push.catchUp(new Date("2026-03-09T08:00:00Z"));
  expect(bodies[0].aps.alert.body).toBe("1 new link from Maya");
  accounts.setNotifications("Reader", { catchup: { time: "08:00", timeZone: "UTC" } });
  await push.catchUp(new Date("2026-03-09T08:00:00Z"));
  expect(bodies).toHaveLength(1);
});
