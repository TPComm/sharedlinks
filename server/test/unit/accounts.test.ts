import type { Database } from "bun:sqlite";
import { existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, setSystemTime, spyOn, test } from "bun:test";
import { Accounts, AuthError, cleanName, publicUser } from "../../src/accounts.ts";
import { configFromEnv, type Config } from "../../src/config.ts";
import { openDatabase } from "../../src/db.ts";
import { BadRequest } from "../../src/links.ts";
import { closedPort, stubServer, tempDir } from "./helpers.ts";

const sha256 = (s: string) => new Bun.CryptoHasher("sha256").update(s).digest("hex");
const T0 = 1_700_000_000;
const DAY = 86400;
const TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;

let tmp: ReturnType<typeof tempDir>;
let db: Database;
beforeEach(() => {
  tmp = tempDir();
  db = openDatabase(tmp.dir);
});
afterEach(() => {
  setSystemTime();
  db.close();
  tmp.cleanup();
});

const accounts = (over: Partial<Config> = {}) => new Accounts(db, { ...configFromEnv({}), ...over });
const at = (seconds: number) => setSystemTime(new Date(seconds * 1000));
const addUser = (id: string, email: string | null = null, name = "N", createdAt = 1) =>
  db.run("INSERT INTO users (id, email, name, created_at) VALUES (?, ?, ?, ?)", [id, email, name, createdAt]);
const rows = (sql: string) => db.query(sql).all();
const count = (table: string) => (db.query(`SELECT COUNT(*) AS n FROM ${table}`).get() as { n: number }).n;

describe("emailAllowed", () => {
  test.each([
    ["friend@example.com", true],
    ["FRIEND@Example.COM", true],
    ["jane@team.test", true],
    ["JANE@TEAM.TEST", true],
    ["evilfriend@example.com", false],
    ["friend@example.com.evil", false],
    ["friend@example.co", false],
    ["jane@evilteam.test", false],
    ["jane@sub.team.test", false],
    ["team.test", false],
    ["", false],
    [null, false],
    [undefined, false],
  ])("%p -> %p", (email, want) => {
    expect(accounts({ allowedEmails: ["friend@example.com", "@team.test"] }).emailAllowed(email)).toBe(want);
  });

  test("an empty list lets everyone in", () => {
    for (const email of ["anyone@anywhere.test", "", null]) expect(accounts().emailAllowed(email)).toBe(true);
  });
});

describe("names", () => {
  test.each([
    ["  Sammy   J  ", "Sammy J"],
    ["x".repeat(40), "x".repeat(30)],
    [123, "123"],
  ])("cleanName(%p) = %p", (name, want) => {
    expect(cleanName(name)).toBe(want);
  });

  test.each([[""], ["   "], [null], [undefined]])("cleanName(%p) is refused", (name) => {
    expect(() => cleanName(name)).toThrow(BadRequest);
  });

  test("publicUser leaves out the email", () => {
    expect(publicUser({ id: "u", email: "a@x.com", name: "A", avatar: null, created_at: 1 })).toEqual({ id: "u", name: "A", avatar: null });
  });

  test("upsertUser creates once, then keeps the chosen name and refreshes email and avatar", () => {
    const a = accounts();
    const user = () => db.query("SELECT email, name, avatar FROM users WHERE id = 'u1'").get();
    a.upsertUser("u1", "a@x.com", "  Riley   R ", "https://cdn/1.png");
    expect(user()).toEqual({ email: "a@x.com", name: "Riley R", avatar: "https://cdn/1.png" });
    a.rename("u1", " Rye ");
    a.upsertUser("u1", "new@x.com", "Riley", null);
    expect(user()).toEqual({ email: "new@x.com", name: "Rye", avatar: "https://cdn/1.png" }); // no picture: keep the old one
    a.upsertUser("u1", "new@x.com", "Riley", "https://cdn/2.png");
    expect(user()).toMatchObject({ avatar: "https://cdn/2.png" });
    expect(() => a.rename("u1", "   ")).toThrow(BadRequest);
    expect(user()).toMatchObject({ name: "Rye" });
  });
});

describe("sessions", () => {
  test("the token is returned once; only its SHA-256 is stored", () => {
    addUser("u1");
    const a = accounts();
    const token = a.newSession("u1");
    expect(token).toMatch(TOKEN_RE);
    const stored = rows("SELECT * FROM sessions") as { token_hash: string }[];
    expect(stored).toHaveLength(1);
    expect(stored[0]!.token_hash).toBe(sha256(token));
    expect(JSON.stringify(stored)).not.toContain(token);
    expect(a.sessionUser(token)).toBe("u1");
    expect(a.sessionUser(stored[0]!.token_hash)).toBeNull(); // the hash itself is not a token
  });

  test("every session gets its own token", () => {
    addUser("u1");
    const a = accounts();
    expect(new Set(Array.from({ length: 20 }, () => a.newSession("u1"))).size).toBe(20);
  });

  test.each([[null], [""], ["nope"]])("no user for token %p", (token) => {
    expect(accounts().sessionUser(token)).toBeNull();
  });

  test.each([[90], [7]])("expires after sessionDays (%p) without use, and is deleted", (days) => {
    addUser("u1");
    const a = accounts({ sessionDays: days });
    at(T0);
    const kept = a.newSession("u1");
    const lost = a.newSession("u1");
    at(T0 + days * DAY);
    expect(a.sessionUser(kept)).toBe("u1");
    at(T0 + days * DAY + 1);
    expect(a.sessionUser(lost)).toBeNull();
    expect(db.query("SELECT 1 FROM sessions WHERE token_hash = ?").get(sha256(lost))).toBeNull();
    expect(a.sessionUser(kept)).toBe("u1"); // used a second ago
  });

  test("the default is 90 days", () => {
    addUser("u1");
    at(T0);
    const token = accounts().newSession("u1");
    at(T0 + 89 * DAY);
    expect(accounts().sessionUser(token)).toBe("u1");
    at(T0 + 89 * DAY + 90 * DAY + 1);
    expect(accounts().sessionUser(token)).toBeNull();
  });

  test("use slides the expiry, writing last_used at most once an hour", () => {
    addUser("u1");
    const a = accounts({ sessionDays: 7 });
    const lastUsed = () => (db.query("SELECT last_used FROM sessions").get() as { last_used: number }).last_used;
    at(T0);
    const token = a.newSession("u1");
    at(T0 + 3600);
    expect(a.sessionUser(token)).toBe("u1");
    expect(lastUsed()).toBe(T0);
    at(T0 + 3601);
    expect(a.sessionUser(token)).toBe("u1");
    expect(lastUsed()).toBe(T0 + 3601);
    at(T0 + 3601 + 7 * DAY); // more than 7 days after sign-in, but not after the last use
    expect(a.sessionUser(token)).toBe("u1");
  });

  test("a session stops working while its email is off the guest list", () => {
    addUser("u1", "Friend@Example.com");
    const token = accounts().newSession("u1");
    expect(accounts({ allowedEmails: ["friend@example.com"] }).sessionUser(token)).toBe("u1");
    expect(accounts({ allowedEmails: ["other@example.com"] }).sessionUser(token)).toBeNull();
    expect(accounts({ allowedEmails: ["@example.com"] }).sessionUser(token)).toBe("u1"); // not deleted
  });

  test("endSession ends only that session", () => {
    addUser("u1");
    const a = accounts();
    const [one, two] = [a.newSession("u1"), a.newSession("u1")];
    a.endSession(one);
    expect(a.sessionUser(one)).toBeNull();
    expect(a.sessionUser(two)).toBe("u1");
    expect(count("sessions")).toBe(1);
  });
});

describe("claimLegacy", () => {
  function setup() {
    addUser("user_A", "a@x.com", "Riley", 5);
    addUser("user_B", "b@x.com", "Bo", 6);
    addUser("legacy:Sam", null, "Sam", 1);
    addUser("legacy:Alex", null, "Alex", 2);
    db.exec(`
      INSERT INTO links (id, url, platform, added_by, added_at) VALUES
        (1, 'https://a.com/1', 'web', 'legacy:Sam', 1), (2, 'https://a.com/2', 'web', 'legacy:Alex', 1),
        (3, 'https://a.com/3', 'web', 'user_A', 1);
      INSERT INTO seen VALUES (1, 'legacy:Sam', 5), (2, 'legacy:Sam', 6), (2, 'user_A', 7), (2, 'legacy:Alex', 8);
      INSERT INTO reactions VALUES (1, 'legacy:Sam', '🔥'), (3, 'legacy:Sam', '😂'), (3, 'user_A', '❤️'), (1, 'legacy:Alex', '😮');
    `);
    return accounts();
  }

  test("moves links, receipts and reactions to the account, which takes the name", () => {
    setup().claimLegacy("user_A", "legacy:Sam");
    expect(rows("SELECT id, added_by FROM links ORDER BY id")).toEqual([
      { id: 1, added_by: "user_A" }, { id: 2, added_by: "legacy:Alex" }, { id: 3, added_by: "user_A" },
    ]);
    // Where both had seen or reacted to a link, the account's own mark wins.
    expect(rows("SELECT * FROM seen ORDER BY link_id, person")).toEqual([
      { link_id: 1, person: "user_A", seen_at: 5 },
      { link_id: 2, person: "legacy:Alex", seen_at: 8 },
      { link_id: 2, person: "user_A", seen_at: 7 },
    ]);
    expect(rows("SELECT * FROM reactions ORDER BY link_id, person")).toEqual([
      { link_id: 1, person: "legacy:Alex", emoji: "😮" },
      { link_id: 1, person: "user_A", emoji: "🔥" },
      { link_id: 3, person: "user_A", emoji: "❤️" },
    ]);
    expect(rows("SELECT id, name FROM users ORDER BY id")).toEqual([
      { id: "legacy:Alex", name: "Alex" }, { id: "user_A", name: "Sam" }, { id: "user_B", name: "Bo" },
    ]);
  });

  test("keeps the blocks and reports on the legacy person, skipping a block of themselves", () => {
    const a = setup();
    db.exec(`
      INSERT INTO blocks VALUES ('user_B', 'legacy:Sam', 1), ('legacy:Sam', 'user_A', 2), ('user_A', 'legacy:Sam', 3);
      INSERT INTO reports (reporter, user_id, reason, snapshot, created_at) VALUES ('user_B', 'legacy:Sam', 'spam', '{}', 1);
      INSERT INTO reports (reporter, link_id, reason, snapshot, created_at) VALUES ('legacy:Sam', 2, 'other', '{}', 2);
    `);
    a.claimLegacy("user_A", "legacy:Sam");
    expect(rows("SELECT blocker, blocked FROM blocks ORDER BY created_at")).toEqual([{ blocker: "user_B", blocked: "user_A" }]);
    expect(rows("SELECT reporter, link_id, user_id FROM reports ORDER BY created_at")).toEqual([
      { reporter: "user_B", link_id: null, user_id: "user_A" },
      { reporter: "user_A", link_id: 2, user_id: null },
    ]);
  });

  test("a name with a listed word is refused when renaming, not at sign-in", () => {
    addUser("user_A");
    const a = accounts();
    expect(() => a.rename("user_A", "the faggot")).toThrow(BadRequest);
    a.upsertUser("user_C", "c@x.com", "Faggot", null); // sign-in keeps WorkOS's name rather than failing
    a.rename("user_A", "Scunthorpe Fan");
    expect(rows("SELECT name FROM users WHERE id = 'user_A'")).toEqual([{ name: "Scunthorpe Fan" }]);
  });

  test("refuses a second claim, a real account, or nobody", () => {
    const a = setup();
    a.claimLegacy("user_A", "legacy:Sam");
    for (const id of ["legacy:Sam", "user_B", "legacy:Nobody", ""]) {
      expect(() => a.claimLegacy("user_A", id)).toThrow(BadRequest);
    }
    expect(rows("SELECT id, name FROM users WHERE id = 'user_B'")).toEqual([{ id: "user_B", name: "Bo" }]);
    expect(rows("SELECT name FROM users WHERE id = 'user_A'")).toEqual([{ name: "Sam" }]);
  });

  test("mePayload: the account with its email, and who's left to claim, oldest first", () => {
    const a = setup();
    expect(a.mePayload("user_A")).toEqual({
      user: { id: "user_A", name: "Riley", avatar: null, email: "a@x.com" },
      claimable: [{ id: "legacy:Sam", name: "Sam", avatar: null }, { id: "legacy:Alex", name: "Alex", avatar: null }],
    });
    a.claimLegacy("user_A", "legacy:Sam");
    expect(a.mePayload("user_A").claimable).toEqual([{ id: "legacy:Alex", name: "Alex", avatar: null }]);
  });
});

describe("mintSession", () => {
  test("reuses an account by email, in any case, and keeps its name", () => {
    addUser("user_A", "Friend@Example.com", "Riley");
    const a = accounts();
    expect(a.sessionUser(a.mintSession("friend@example.COM", "Ignored"))).toBe("user_A");
    expect(rows("SELECT name FROM users WHERE id = 'user_A'")).toEqual([{ name: "Riley" }]);
  });

  test("creates a local account named after the email or the given name", () => {
    const a = accounts();
    const id = a.sessionUser(a.mintSession("sam@x.com"));
    expect(id).toMatch(/^local_[0-9a-f]{16}$/);
    expect(rows("SELECT email, name FROM users")).toEqual([{ email: "sam@x.com", name: "Sam" }]);
    expect(a.sessionUser(a.mintSession("sam@x.com", "Other"))).toBe(id!);
    const named = a.sessionUser(a.mintSession("jo@x.com", "Jo Jo"));
    expect(rows(`SELECT name FROM users WHERE id = '${named}'`)).toEqual([{ name: "Jo Jo" }]);
  });

  test("never signs in as a legacy person", () => {
    addUser("legacy:Sam", "sam@x.com", "Sam");
    const a = accounts();
    expect(a.sessionUser(a.mintSession("sam@x.com"))).toMatch(/^local_/);
  });
});

describe("deleteUser", () => {
  const workosCalls: { method: string; path: string; auth: string | null }[] = [];
  let workosStatus = 200;
  // Not stubServer, which routes by exact path: this one's path carries the user id.
  const deletes = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(req) {
      workosCalls.push({ method: req.method, path: new URL(req.url).pathname, auth: req.headers.get("authorization") });
      return new Response(workosStatus < 300 ? null : "nope", { status: workosStatus });
    },
  });
  let consoleError: ReturnType<typeof spyOn>;
  beforeAll(() => {
    consoleError = spyOn(console, "error").mockImplementation(() => {});
  });
  beforeEach(() => {
    workosCalls.length = 0;
    workosStatus = 200;
  });
  afterAll(() => {
    consoleError.mockRestore();
    deletes.stop(true);
  });

  const thumb = (id: number) => join(tmp.dir, "thumbs", String(id));

  function setup(over: Partial<Config> = {}) {
    addUser("user_A", "a@x.com", "Riley");
    addUser("user_B", "b@x.com", "Bo");
    db.exec(`
      INSERT INTO links (id, url, platform, thumb_type, added_by, added_at) VALUES
        (1, 'https://a.com/1', 'web', 'image/png', 'user_A', 1), (2, 'https://a.com/2', 'web', NULL, 'user_A', 1),
        (3, 'https://a.com/3', 'web', 'image/png', 'user_B', 1);
      INSERT INTO seen VALUES (1, 'user_B', 5), (3, 'user_A', 6), (3, 'user_B', 7);
      INSERT INTO reactions VALUES (1, 'user_B', '🔥'), (3, 'user_A', '😂'), (3, 'user_B', '❤️');
    `);
    for (const id of [1, 3]) writeFileSync(thumb(id), "png");
    const a = accounts({ workosApi: `http://127.0.0.1:${deletes.port}`, dataDir: tmp.dir, ...over });
    for (const user of ["user_A", "user_A", "user_B"]) a.newSession(user);
    return a;
  }

  test("deletes the account, its sessions, marks, reactions, and the links it sent with their thumbnails", async () => {
    expect(await setup().deleteUser("user_A")).toEqual({ links: 2, workos: "skipped" });
    expect(rows("SELECT id FROM users")).toEqual([{ id: "user_B" }]);
    expect(rows("SELECT user_id FROM sessions")).toEqual([{ user_id: "user_B" }]);
    expect(rows("SELECT id, added_by FROM links ORDER BY id")).toEqual([{ id: 3, added_by: "user_B" }]);
    expect([existsSync(thumb(1)), existsSync(thumb(3))]).toEqual([false, true]);
    // Everyone else's marks and reactions on her links went with them; on other links they stay.
    expect(rows("SELECT link_id, person FROM seen ORDER BY link_id")).toEqual([{ link_id: 3, person: "user_B" }]);
    expect(rows("SELECT link_id, person FROM reactions ORDER BY link_id")).toEqual([{ link_id: 3, person: "user_B" }]);
    expect(workosCalls).toEqual([]); // no API key
  });

  test("an account made later with the same id starts empty", async () => {
    const a = setup();
    await a.deleteUser("user_A");
    a.upsertUser("user_A", "a@x.com", "Riley", null); // signing in again with the same WorkOS user
    expect(rows("SELECT id FROM links WHERE added_by = 'user_A'")).toEqual([]);
    expect(a.mePayload("user_A").claimable).toEqual([]);
  });

  test("deleting everyone leaves nothing behind", async () => {
    const a = setup();
    await a.deleteUser("user_A");
    await a.deleteUser("user_B");
    expect([count("users"), count("sessions"), count("links"), count("seen"), count("reactions")]).toEqual([0, 0, 0, 0, 0]);
    expect(existsSync(thumb(3))).toBe(false);
  });

  test("an id with nothing tied to it is a no-op", async () => {
    const a = setup();
    expect(await a.deleteUser("user_Nobody")).toEqual({ links: 0, workos: "skipped" });
    expect([count("users"), count("sessions"), count("links"), count("seen"), count("reactions")]).toEqual([2, 3, 3, 3, 3]);
  });

  test("with an API key, deletes the WorkOS user too", async () => {
    expect((await setup({ workosApiKey: "sk_test_1" }).deleteUser("user_A")).workos).toBe("deleted");
    expect(workosCalls).toEqual([{ method: "DELETE", path: "/user_management/users/user_A", auth: "Bearer sk_test_1" }]);
  });

  test("a WorkOS user that's already gone counts as deleted", async () => {
    workosStatus = 404;
    expect((await setup({ workosApiKey: "sk_test_1" }).deleteUser("user_A")).workos).toBe("deleted");
  });

  test("a WorkOS failure is logged, and the Links account is gone anyway", async () => {
    workosStatus = 500;
    expect(await setup({ workosApiKey: "sk_test_1" }).deleteUser("user_A")).toEqual({ links: 2, workos: "failed" });
    expect(rows("SELECT id FROM users")).toEqual([{ id: "user_B" }]);
    expect(consoleError).toHaveBeenLastCalledWith(expect.stringContaining("WorkOS delete user user_A failed (500): nope"));

    const unreachable = accounts({ workosApiKey: "sk_test_1", workosApi: `http://127.0.0.1:${closedPort()}` });
    expect((await unreachable.deleteUser("user_B")).workos).toBe("failed");
    expect(count("users")).toBe(0);
  });

  test("never calls WorkOS for people it didn't sign in (mint-session's local_ ids)", async () => {
    const a = setup({ workosApiKey: "sk_test_1" });
    const local = a.sessionUser(a.mintSession("local@x.com"))!;
    expect((await a.deleteUser(local)).workos).toBe("skipped");
    expect(workosCalls).toEqual([]);
  });

  test("usersWithEmail: any case, oldest first, never legacy people", () => {
    addUser("user_A", "Sam@X.com", "Sam", 2);
    addUser("local_1", "sam@x.com", "Sam L", 1);
    addUser("legacy:Sam", "sam@x.com", "Sam", 0);
    addUser("user_B", "other@x.com", "Bo", 3);
    expect(accounts().usersWithEmail("SAM@x.com").map((u) => u.id)).toEqual(["local_1", "user_A"]);
    expect(accounts().usersWithEmail("nobody@x.com")).toEqual([]);
  });
});

describe("authorizeUrl", () => {
  const CHALLENGE = "c".repeat(43);
  const setUp = { workosClientId: "client_1", workosApi: "https://auth.example.com", publicUrl: "https://links.example.com" };

  test("sends the PKCE challenge to AuthKit", () => {
    const url = new URL(accounts(setUp).authorizeUrl(CHALLENGE, "st", "sign-up"));
    expect(url.origin + url.pathname).toBe("https://auth.example.com/user_management/authorize");
    expect(Object.fromEntries(url.searchParams)).toEqual({
      client_id: "client_1", response_type: "code", provider: "authkit",
      redirect_uri: "https://links.example.com/auth/callback", code_challenge: CHALLENGE,
      code_challenge_method: "S256", state: "st", screen_hint: "sign-up",
    });
  });

  test.each([["sign-in", "sign-in"], ["sign-up", "sign-up"], ["signup", null], ["", null], [null, null], [undefined, null]])(
    "screen_hint %p -> %p", (hint, want) => {
      expect(new URL(accounts(setUp).authorizeUrl(CHALLENGE, "", hint)).searchParams.get("screen_hint")).toBe(want);
    });

  test.each([["A".repeat(43)], ["a-_0".repeat(16)], ["x".repeat(128)]])("accepts challenge %p", (challenge) => {
    expect(() => accounts(setUp).authorizeUrl(challenge, "")).not.toThrow();
  });

  test.each([["c".repeat(42)], ["c".repeat(129)], [`${"c".repeat(42)}=`], [`${"c".repeat(42)}/`], [`${"c".repeat(42)}+`], [""]])(
    "rejects challenge %p", (challenge) => {
      expect(() => accounts(setUp).authorizeUrl(challenge, "")).toThrow(BadRequest);
    });

  test("state is capped at 200 characters", () => {
    expect(() => accounts(setUp).authorizeUrl(CHALLENGE, "s".repeat(200))).not.toThrow();
    expect(() => accounts(setUp).authorizeUrl(CHALLENGE, "s".repeat(201))).toThrow(BadRequest);
  });

  test("503 when sign-in isn't set up", () => {
    const e = (() => {
      try {
        accounts().authorizeUrl(CHALLENGE, "");
      } catch (e) {
        return e;
      }
    })();
    expect(e).toBeInstanceOf(AuthError);
    expect((e as AuthError).status).toBe(503);
  });
});

describe("signIn (WorkOS stub)", () => {
  const VERIFIER = "v".repeat(43);
  const requests: { body: Record<string, any>; headers: Headers }[] = [];
  const USERS: Record<string, object> = {
    good: { id: "user_01", email: "Friend@Example.com", email_verified: true, first_name: "Riley", profile_picture_url: "https://cdn/r.png" },
    team: { id: "user_02", email: "jane.doe@team.test", email_verified: true, first_name: "", profile_picture_url: null },
    upper: { id: "user_03", email: "BOB.SMITH@team.test", email_verified: true },
    stranger: { id: "user_04", email: "stranger@evil.test", email_verified: true },
    unverified: { id: "user_05", email: "friend2@team.test", email_verified: false },
    noemail: { id: "user_06" },
  };
  const workos = stubServer({
    "/user_management/authenticate": async (req) => {
      const body = await req.json() as Record<string, any>;
      requests.push({ body, headers: req.headers });
      if (body.code === "message") return Response.json({ message: "Too many requests." }, { status: 429 });
      if (body.code === "html") return new Response("<html>Bad gateway</html>", { status: 502 });
      if (body.code_verifier !== VERIFIER) {
        return Response.json({ error: "invalid_grant", error_description: "Invalid code verifier." }, { status: 400 });
      }
      const user = USERS[body.code];
      if (!user) return Response.json({ error: "invalid_grant", error_description: "Invalid authorization code." }, { status: 400 });
      return Response.json({ user, access_token: "jwt", refresh_token: "refresh" });
    },
  });
  let consoleError: ReturnType<typeof spyOn>;
  beforeAll(() => {
    consoleError = spyOn(console, "error").mockImplementation(() => {});
  });
  afterAll(() => {
    consoleError.mockRestore();
    workos.stop();
  });

  const signer = (over: Partial<Config> = {}) => accounts({
    workosClientId: "client_1", workosApi: workos.origin, allowedEmails: ["friend@example.com", "@team.test"], ...over,
  });
  const authError = async (p: Promise<unknown>) => {
    const e = await p.then(() => null, (e) => e);
    expect(e).toBeInstanceOf(AuthError);
    return e as AuthError;
  };

  test("exchanges the code and starts a session", async () => {
    const res = await signer().signIn("good", VERIFIER, "Links/1 CFNetwork");
    expect(res.token).toMatch(TOKEN_RE);
    expect(res.user).toEqual({ id: "user_01", name: "Riley", avatar: "https://cdn/r.png", email: "Friend@Example.com" });
    expect(res.claimable).toEqual([]);
    expect(signer().sessionUser(res.token)).toBe("user_01");
    const { body, headers } = requests.at(-1)!;
    expect(body).toEqual({
      client_id: "client_1", grant_type: "authorization_code", code: "good", code_verifier: VERIFIER, user_agent: "Links/1 CFNetwork",
    });
    expect(headers.get("content-type")).toBe("application/json");
  });

  test("sends the API key as client_secret only when set, and caps user_agent", async () => {
    await signer({ workosApiKey: "sk_test_x" }).signIn("good", VERIFIER, "u".repeat(500));
    expect(requests.at(-1)!.body.client_secret).toBe("sk_test_x");
    expect(requests.at(-1)!.body.user_agent).toBe("u".repeat(300));
  });

  test.each([
    ["bad verifier", "good", "w".repeat(43), "Invalid code verifier."],
    ["unknown code", "nope", VERIFIER, "Invalid authorization code."],
    ["message only", "message", VERIFIER, "Too many requests."],
    ["not JSON", "html", VERIFIER, "Sign-in failed. Try again."],
  ])("a WorkOS error (%s) is a 400 with its message", async (_, code, verifier, message) => {
    const e = await authError(signer().signIn(code, verifier, ""));
    expect(e.status).toBe(400); // not 401, which the app reads as "your session ended"
    expect(e.message).toBe(message);
    expect(count("sessions")).toBe(0);
  });

  test("guest list and email verification", async () => {
    let e = await authError(signer().signIn("stranger", VERIFIER, ""));
    expect([e.status, e.message]).toEqual([403, "stranger@evil.test isn't on the guest list for this Links."]);
    e = await authError(signer().signIn("unverified", VERIFIER, ""));
    expect([e.status, e.message]).toEqual([403, "Verify your email address, then sign in again."]);
    e = await authError(signer().signIn("noemail", VERIFIER, ""));
    expect(e.status).toBe(403);
    expect([count("users"), count("sessions")]).toEqual([0, 0]);
    // Without a guest list: anyone AuthKit lets in, verified or not.
    expect((await signer({ allowedEmails: [] }).signIn("unverified", VERIFIER, "")).user.id).toBe("user_05");
  });

  test.each([["team", "Jane Doe"], ["upper", "Bob Smith"]])("with no first name, %s is named from the email: %p", async (code, name) => {
    expect((await signer().signIn(code, VERIFIER, "")).user.name).toBe(name);
  });

  test("with no name or email, 'Someone'", async () => {
    expect((await signer({ allowedEmails: [] }).signIn("noemail", VERIFIER, "")).user).toMatchObject({ name: "Someone", email: "" });
  });

  test("signing in again keeps the name chosen in the app", async () => {
    const a = signer();
    await a.signIn("good", VERIFIER, "");
    a.rename("user_01", "Rye");
    expect((await a.signIn("good", VERIFIER, "")).user.name).toBe("Rye");
    expect([count("users"), count("sessions")]).toEqual([1, 2]);
  });

  test("missing set-up or input fails before calling WorkOS", async () => {
    const before = requests.length;
    expect((await authError(signer({ workosClientId: "" }).signIn("good", VERIFIER, ""))).status).toBe(503);
    expect((await authError(signer().signIn("", VERIFIER, ""))).status).toBe(400);
    expect((await authError(signer().signIn("good", "", ""))).status).toBe(400);
    expect(requests.length).toBe(before);
  });

  test("WorkOS unreachable: fails without starting a session", async () => {
    await expect(signer({ workosApi: `http://127.0.0.1:${closedPort()}` }).signIn("good", VERIFIER, "")).rejects.toThrow();
    expect([count("users"), count("sessions")]).toEqual([0, 0]);
  });
});
