import { afterEach, describe, expect, test } from "bun:test";
import { isAbsolute, join } from "node:path";
import { configFromEnv } from "../../src/config.ts";

describe("configFromEnv", () => {
  test("defaults", () => {
    expect(configFromEnv({})).toEqual({
      port: 8000,
      hostname: "0.0.0.0",
      dataDir: join(process.cwd(), "data"),
      publicUrl: "http://localhost:8000",
      appScheme: "sharedlinks",
      sessionDays: 90,
      workosClientId: "",
      workosApiKey: "",
      workosApi: "https://api.workos.com",
      allowedEmails: [],
      allowPrivateNetwork: false,
      logRequests: true,
      previewBackfillMs: 5000,
    });
  });

  test("passes strings through", () => {
    expect(configFromEnv({
      HOST: "127.0.0.1", APP_SCHEME: "links-dev", WORKOS_CLIENT_ID: "client_1", WORKOS_API_KEY: "sk_test_1",
    })).toMatchObject({ hostname: "127.0.0.1", appScheme: "links-dev", workosClientId: "client_1", workosApiKey: "sk_test_1" });
  });

  test("PORT and SESSION_DAYS are numbers; the default PUBLIC_URL follows PORT", () => {
    expect(configFromEnv({ PORT: "9000", SESSION_DAYS: "7" })).toMatchObject({
      port: 9000, sessionDays: 7, publicUrl: "http://localhost:9000",
    });
    expect(configFromEnv({ SESSION_DAYS: "0.5" }).sessionDays).toBe(0.5);
  });

  test.each([
    ["https://links.example.com", "https://links.example.com"],
    ["https://links.example.com/", "https://links.example.com"],
    ["https://links.example.com///", "https://links.example.com"],
    ["https://example.com/links/", "https://example.com/links"],
  ])("PUBLIC_URL %p -> %p", (value, want) => {
    expect(configFromEnv({ PUBLIC_URL: value, PORT: "1234" }).publicUrl).toBe(want);
  });

  test.each([
    ["https://api.workos.com/", "https://api.workos.com"],
    ["http://127.0.0.1:9999//", "http://127.0.0.1:9999"],
  ])("WORKOS_API %p -> %p", (value, want) => {
    expect(configFromEnv({ WORKOS_API: value }).workosApi).toBe(want);
  });

  test.each([
    [" Friend@Example.com , ,@Team.Test,,  ", ["friend@example.com", "@team.test"]],
    ["one@x.com", ["one@x.com"]],
    ["", []],
    [" , , ", []],
  ])("ALLOWED_EMAILS %p -> %p", (value, want) => {
    expect(configFromEnv({ ALLOWED_EMAILS: value }).allowedEmails).toEqual(want);
  });

  test.each([
    ["data", join(process.cwd(), "data")],
    ["rel/dir/", join(process.cwd(), "rel/dir")],
    ["/srv/links/", "/srv/links"],
    ["/srv/../var/links", "/var/links"],
  ])("DATA_DIR %p is resolved to %p", (value, want) => {
    const { dataDir } = configFromEnv({ DATA_DIR: value });
    expect(isAbsolute(dataDir)).toBe(true);
    expect(dataDir).toBe(want);
  });

  test("private-network fetches can't be turned on from the environment", () => {
    expect(configFromEnv({ ALLOW_PRIVATE_NETWORK: "1", allowPrivateNetwork: "true" }).allowPrivateNetwork).toBe(false);
  });

  describe("reads process.env by default", () => {
    const saved = process.env.APP_SCHEME;
    afterEach(() => {
      if (saved === undefined) delete process.env.APP_SCHEME;
      else process.env.APP_SCHEME = saved;
    });

    test("APP_SCHEME", () => {
      process.env.APP_SCHEME = "from-process-env";
      expect(configFromEnv().appScheme).toBe("from-process-env");
    });
  });
});
