// Files TestFlight feedback (screenshot comments and crash reports) as GitHub issues.
// Run by .github/workflows/testflight-feedback.yml; needs ASC_ISSUER_ID, ASC_KEY_ID, ASC_KEY_P8,
// GITHUB_TOKEN and GITHUB_REPOSITORY. DRY_RUN=1 prints the issues instead of filing them.
//
// The repo is public, so issues leave out the tester's name, email and time zone. Apple's
// screenshot URLs expire after a week, so screenshots are copied to the ASSETS_BRANCH first.
// That branch also records each filed submission as <id>/issue.txt: GitHub's issue list can lag
// a fresh issue by minutes, so the markers in issue bodies alone could refile it.

const ASC_API = "https://api.appstoreconnect.apple.com";
const GITHUB_API = "https://api.github.com";
export const ASSETS_BRANCH = "testflight-feedback";
export const LABEL = "testflight";
const MARKER = /<!-- testflight-feedback:([\w-]+) -->/g;
// GitHub rejects issue bodies over 65,536 characters.
const MAX_BODY = 60_000;

export type Kind = "screenshot" | "crash";

export interface Feedback {
  id: string;
  kind: Kind;
  createdDate: string;
  comment: string | null;
  build: string | null;
  deviceModel: string | null;
  osVersion: string | null;
  locale: string | null;
  connectionType: string | null;
  batteryPercentage: number | null;
  diskBytesAvailable: number | null;
  appUptimeInMilliseconds: number | null;
  screenshots: string[];
  crashLog: string | null;
}

export function truncate(text: string, max: number): string {
  return text.length <= max ? text : `${text.slice(0, max - 1).trimEnd()}…`;
}

export function issueTitle(f: Feedback): string {
  const firstLine = (f.comment ?? "").trim().split("\n")[0]!.trim();
  const prefix = f.kind === "crash" ? "TestFlight crash" : "TestFlight";
  if (firstLine) return `${prefix}: ${truncate(firstLine, 80)}`;
  return `${prefix} on ${f.build ?? "an unknown build"}`;
}

function quote(text: string): string {
  return text
    .trim()
    .split("\n")
    .map((line) => `> ${line}`)
    .join("\n");
}

function gigabytes(bytes: number): string {
  return `${(bytes / 1e9).toFixed(1)} GB`;
}

function minutes(ms: number): string {
  return `${Math.round(ms / 60_000)} min`;
}

export function issueBody(f: Feedback, screenshotUrls: string[]): string {
  const parts: string[] = [];
  parts.push(f.comment?.trim() ? quote(f.comment) : "_No comment._");
  if (screenshotUrls.length) {
    parts.push(screenshotUrls.map((url) => `<img src="${url}" width="320">`).join(" "));
  }
  const rows: [string, string | null][] = [
    ["Sent", f.createdDate],
    ["Build", f.build],
    ["Device", f.deviceModel],
    ["iOS", f.osVersion],
    ["Locale", f.locale],
    ["Connection", f.connectionType],
    ["Battery", f.batteryPercentage == null ? null : `${f.batteryPercentage}%`],
    ["Free disk", f.diskBytesAvailable == null ? null : gigabytes(f.diskBytesAvailable)],
    ["App uptime", f.appUptimeInMilliseconds == null ? null : minutes(f.appUptimeInMilliseconds)],
  ];
  parts.push(
    ["| | |", "| --- | --- |", ...rows.filter(([, v]) => v != null).map(([k, v]) => `| ${k} | ${v} |`)].join("\n"),
  );
  const footer = `Filed from TestFlight feedback by \`.github/workflows/testflight-feedback.yml\`.\n<!-- testflight-feedback:${f.id} -->`;
  if (f.crashLog) {
    const used = parts.join("\n\n").length + footer.length + 200;
    const log = truncate(f.crashLog.replaceAll("```", "ʼʼʼ"), Math.max(1000, MAX_BODY - used));
    parts.push(`<details><summary>Crash log</summary>\n\n\`\`\`\n${log}\n\`\`\`\n\n</details>`);
  }
  parts.push(footer);
  return parts.join("\n\n");
}

/** Submission ids already filed, read from the markers in existing issue bodies. */
export function filedIds(bodies: (string | null | undefined)[]): Set<string> {
  const ids = new Set<string>();
  for (const body of bodies) for (const m of (body ?? "").matchAll(MARKER)) ids.add(m[1]!);
  return ids;
}

/** Submission ids recorded on the assets branch, from its file paths. */
export function recordedIds(paths: string[]): Set<string> {
  const ids = new Set<string>();
  for (const path of paths) {
    const m = path.match(/^([\w-]+)\/issue\.txt$/);
    if (m) ids.add(m[1]!);
  }
  return ids;
}

// --- App Store Connect ---

function env(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is not set`);
  return value;
}

async function ascToken(): Promise<string> {
  const der = Buffer.from(env("ASC_KEY_P8").replace(/-----[^-]+-----|\s+/g, ""), "base64");
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const part = (o: object) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  const input = `${part({ alg: "ES256", kid: env("ASC_KEY_ID"), typ: "JWT" })}.${part({
    iss: env("ASC_ISSUER_ID"),
    iat: now,
    exp: now + 15 * 60,
    aud: "appstoreconnect-v1",
  })}`;
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input));
  return `${input}.${Buffer.from(sig).toString("base64url")}`;
}

type Resource = { id: string; attributes: Record<string, any>; relationships?: Record<string, any> };

async function asc(token: string, pathOrUrl: string): Promise<any> {
  const url = pathOrUrl.startsWith("http") ? pathOrUrl : `${ASC_API}${pathOrUrl}`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (!res.ok) throw new Error(`App Store Connect ${res.status} for ${new URL(url).pathname}: ${await res.text()}`);
  return res.json();
}

async function ascAll(token: string, path: string): Promise<Resource[]> {
  const out: Resource[] = [];
  let next: string | undefined = path;
  while (next) {
    const page: any = await asc(token, next);
    out.push(...page.data);
    next = page.links?.next;
  }
  return out;
}

async function fetchFeedback(token: string, appId: string): Promise<Feedback[]> {
  const builds = new Map<string, string>();
  const buildName = async (id: string | undefined): Promise<string | null> => {
    if (!id) return null;
    if (!builds.has(id)) {
      const res = await asc(token, `/v1/builds/${id}?include=preReleaseVersion&fields[builds]=version,preReleaseVersion&fields[preReleaseVersions]=version`);
      const marketing = res.included?.[0]?.attributes?.version;
      const number = res.data.attributes.version;
      builds.set(id, marketing ? `${marketing} (${number})` : `build ${number}`);
    }
    return builds.get(id)!;
  };

  const feedback: Feedback[] = [];
  for (const kind of ["screenshot", "crash"] as const) {
    const type = kind === "crash" ? "betaFeedbackCrashSubmissions" : "betaFeedbackScreenshotSubmissions";
    // The build relationship only comes back when it's included.
    for (const r of await ascAll(token, `/v1/apps/${appId}/${type}?limit=200&include=build&fields[builds]=version`)) {
      const a = r.attributes;
      feedback.push({
        id: r.id,
        kind,
        createdDate: a.createdDate,
        comment: a.comment ?? null,
        build: await buildName(r.relationships?.build?.data?.id),
        deviceModel: a.deviceModel ?? null,
        osVersion: a.osVersion ?? null,
        locale: a.locale ?? null,
        connectionType: a.connectionType ?? null,
        batteryPercentage: a.batteryPercentage ?? null,
        diskBytesAvailable: a.diskBytesAvailable ?? null,
        appUptimeInMilliseconds: a.appUptimeInMilliseconds ?? null,
        screenshots: (a.screenshots ?? []).map((s: { url: string }) => s.url),
        crashLog: null,
      });
    }
  }
  return feedback.sort((x, y) => x.createdDate.localeCompare(y.createdDate));
}

async function crashLog(token: string, id: string): Promise<string | null> {
  try {
    const res = await asc(token, `/v1/betaFeedbackCrashSubmissions/${id}/crashLog`);
    return res.data?.attributes?.logText ?? null;
  } catch (e) {
    console.warn(`No crash log for ${id}: ${e}`);
    return null;
  }
}

// --- GitHub ---

async function github(method: string, path: string, body?: unknown): Promise<Response> {
  return fetch(`${GITHUB_API}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${env("GITHUB_TOKEN")}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

async function githubOk(method: string, path: string, body?: unknown): Promise<any> {
  const res = await github(method, path, body);
  if (!res.ok) throw new Error(`GitHub ${res.status} for ${method} ${path}: ${await res.text()}`);
  return res.json();
}

async function existingIssueBodies(repo: string): Promise<string[]> {
  const bodies: string[] = [];
  // Every issue, whatever its label or state, so a closed or relabelled one is never refiled.
  for (let page = 1; ; page++) {
    const issues: { body: string | null }[] = await githubOk("GET", `/repos/${repo}/issues?state=all&per_page=100&page=${page}`);
    bodies.push(...issues.map((i) => i.body ?? ""));
    if (issues.length < 100) return bodies;
  }
}

async function ensureAssetsBranch(repo: string): Promise<void> {
  if ((await github("GET", `/repos/${repo}/git/ref/heads/${ASSETS_BRANCH}`)).ok) return;
  // An orphan branch, so screenshots never touch main's history.
  const readme = "Screenshots from TestFlight feedback, linked from the issues `.github/workflows/testflight-feedback.yml` files. Not code.\n";
  const tree = await githubOk("POST", `/repos/${repo}/git/trees`, {
    tree: [{ path: "README.md", mode: "100644", type: "blob", content: readme }],
  });
  const commit = await githubOk("POST", `/repos/${repo}/git/commits`, {
    message: "Start the TestFlight feedback screenshots branch",
    tree: tree.sha,
    parents: [],
  });
  await githubOk("POST", `/repos/${repo}/git/refs`, { ref: `refs/heads/${ASSETS_BRANCH}`, sha: commit.sha });
}

async function assetsBranchPaths(repo: string): Promise<string[]> {
  const res = await github("GET", `/repos/${repo}/git/trees/${ASSETS_BRANCH}?recursive=1`);
  if (res.status === 404) return [];
  if (!res.ok) throw new Error(`GitHub ${res.status} reading the ${ASSETS_BRANCH} branch: ${await res.text()}`);
  const tree = (await res.json()) as { tree: { path: string }[]; truncated: boolean };
  if (tree.truncated) console.warn(`The ${ASSETS_BRANCH} branch's file list was truncated; relying on issue markers too`);
  return tree.tree.map((t) => t.path);
}

async function putFile(repo: string, path: string, content: Buffer, message: string): Promise<void> {
  await githubOk("PUT", `/repos/${repo}/contents/${path}`, {
    message,
    content: content.toString("base64"),
    branch: ASSETS_BRANCH,
  });
}

async function storeScreenshot(repo: string, path: string, sourceUrl: string): Promise<string> {
  const url = `https://raw.githubusercontent.com/${repo}/${ASSETS_BRANCH}/${path}`;
  if ((await github("GET", `/repos/${repo}/contents/${path}?ref=${ASSETS_BRANCH}`)).ok) return url;
  const res = await fetch(sourceUrl);
  if (!res.ok) throw new Error(`Screenshot download ${res.status} for ${path}`);
  await putFile(repo, path, Buffer.from(await res.arrayBuffer()), `Add TestFlight feedback screenshot ${path}`);
  return url;
}

async function ensureLabel(repo: string): Promise<void> {
  const res = await github("POST", `/repos/${repo}/labels`, {
    name: LABEL,
    color: "0a84ff",
    description: "Feedback from TestFlight testers",
  });
  // 422: it already exists.
  if (!res.ok && res.status !== 422) throw new Error(`GitHub ${res.status} creating the ${LABEL} label: ${await res.text()}`);
}

async function main(): Promise<void> {
  const dryRun = process.env.DRY_RUN === "1" || process.env.DRY_RUN === "true";
  const repo = env("GITHUB_REPOSITORY");
  const bundleId = process.env.ASC_BUNDLE_ID || "com.tpcomm.links";
  const token = await ascToken();

  const apps = await asc(token, `/v1/apps?filter[bundleId]=${bundleId}&fields[apps]=bundleId`);
  const appId: string | undefined = apps.data.find((a: Resource) => a.attributes.bundleId === bundleId)?.id;
  if (!appId) throw new Error(`No App Store Connect app with bundle id ${bundleId}`);

  const filed = new Set([...filedIds(await existingIssueBodies(repo)), ...recordedIds(await assetsBranchPaths(repo))]);
  const pending = (await fetchFeedback(token, appId)).filter((f) => !filed.has(f.id));
  console.log(`${pending.length} new TestFlight feedback submission(s) for ${bundleId}`);
  if (!pending.length) return;
  if (!dryRun) {
    await ensureLabel(repo);
    await ensureAssetsBranch(repo);
  }

  let failures = 0;
  for (const f of pending) {
    try {
      if (f.kind === "crash") f.crashLog = await crashLog(token, f.id);
      const urls: string[] = [];
      for (const [i, src] of f.screenshots.entries()) {
        const path = `${f.id}/${i + 1}.jpg`;
        urls.push(dryRun ? `https://raw.githubusercontent.com/${repo}/${ASSETS_BRANCH}/${path}` : await storeScreenshot(repo, path, src));
      }
      const title = issueTitle(f);
      const body = issueBody(f, urls);
      if (dryRun) {
        console.log(`\n--- ${title}\n${body}`);
        continue;
      }
      const issue = await githubOk("POST", `/repos/${repo}/issues`, { title, body, labels: [LABEL] });
      console.log(`Filed ${f.kind} ${f.id} as ${issue.html_url}`);
      await putFile(repo, `${f.id}/issue.txt`, Buffer.from(`${issue.html_url}\n`), `Record TestFlight feedback ${f.id} as #${issue.number}`);
    } catch (e) {
      failures++;
      console.error(`::error::Couldn't file ${f.kind} feedback ${f.id}: ${e}`);
    }
  }
  if (failures) process.exit(1);
}

if (import.meta.main) await main();
