import { describe, expect, test } from "bun:test";
import { type Feedback, filedIds, issueBody, issueTitle, recordedIds, truncate } from "./testflight-feedback.ts";

const base: Feedback = {
  id: "AKXdCD-e-USO7J7PaA0zcN8",
  kind: "screenshot",
  createdDate: "2026-11-14T17:56:34.939Z",
  comment: "the reaction trigger is quite small",
  build: "2.0 (2)",
  deviceModel: "iPhone19_3",
  osVersion: "27.2.1",
  locale: "en-US",
  connectionType: "WIFI",
  batteryPercentage: 85,
  diskBytesAvailable: 212_992_000_000,
  appUptimeInMilliseconds: null,
  screenshots: ["https://tf-feedback.itunes.apple.com/x.jpg"],
  crashLog: null,
};

describe("issueTitle", () => {
  test("uses the comment's first line", () => {
    expect(issueTitle({ ...base, comment: "  first line\nsecond" })).toBe("TestFlight: first line");
    expect(issueTitle({ ...base, kind: "crash", comment: "it closed" })).toBe("TestFlight crash: it closed");
  });

  test("falls back to the build without a comment", () => {
    expect(issueTitle({ ...base, comment: null })).toBe("TestFlight on 2.0 (2)");
    expect(issueTitle({ ...base, kind: "crash", comment: " ", build: null })).toBe("TestFlight crash on an unknown build");
  });

  test("shortens long comments", () => {
    expect(issueTitle({ ...base, comment: "x".repeat(200) }).length).toBe("TestFlight: ".length + 80);
  });
});

describe("issueBody", () => {
  test("quotes the comment, shows screenshots and details, and ends with the marker", () => {
    const body = issueBody(base, ["https://raw.githubusercontent.com/o/r/testflight-feedback/a/1.jpg"]);
    expect(body).toStartWith("> the reaction trigger is quite small");
    expect(body).toContain('<img src="https://raw.githubusercontent.com/o/r/testflight-feedback/a/1.jpg" width="320">');
    expect(body).toContain("| Build | 2.0 (2) |");
    expect(body).toContain("| Free disk | 213.0 GB |");
    expect(body).not.toContain("App uptime");
    expect(filedIds([body])).toEqual(new Set([base.id]));
  });

  test("keeps a huge crash log under GitHub's body limit", () => {
    const body = issueBody({ ...base, kind: "crash", screenshots: [], crashLog: "frame\n".repeat(50_000) }, []);
    expect(body.length).toBeLessThan(65_536);
    expect(body).toContain("<summary>Crash log</summary>");
    expect(filedIds([body])).toEqual(new Set([base.id]));
  });

  test("can't close the crash log's code block early", () => {
    const body = issueBody({ ...base, kind: "crash", crashLog: "a\n```\nb" }, []);
    expect(body.match(/```/g)?.length).toBe(2);
  });
});

test("filedIds reads every marker and ignores bodies without one", () => {
  const ids = filedIds([
    null,
    "plain issue",
    "<!-- testflight-feedback:abc_1 -->\n<!-- testflight-feedback:def-2 -->",
  ]);
  expect(ids).toEqual(new Set(["abc_1", "def-2"]));
});

test("recordedIds reads <id>/issue.txt and nothing else", () => {
  expect(recordedIds(["README.md", "abc_1/1.jpg", "abc_1/issue.txt", "def-2/issue.txt", "x/y/issue.txt"])).toEqual(
    new Set(["abc_1", "def-2"]),
  );
});

test("truncate", () => {
  expect(truncate("short", 10)).toBe("short");
  expect(truncate("a long sentence here", 8)).toBe("a long…");
});
