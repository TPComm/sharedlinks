/**
 * Runs the compiled server the way the VPS does: its own process, env, data dir and port, driven
 * over HTTP and its CLI. Used by the *.e2e.ts suites, which plain `bun test` (what deploy.sh runs
 * before every deploy) doesn't pick up; `bun run test:e2e` runs them.
 */
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { join, resolve } from "node:path";

export const SERVER_ROOT = resolve(import.meta.dir, "../..");

/**
 * The binary under test: LINKS_BINARY if set (CI points it at the x64 build deploy.sh ships),
 * otherwise a fresh build for this machine with the flags of package.json's build scripts.
 */
export async function locateBinary(outDir: string): Promise<string> {
  if (process.env.LINKS_BINARY) {
    const path = resolve(process.env.LINKS_BINARY);
    if (!existsSync(path)) throw new Error(`LINKS_BINARY=${process.env.LINKS_BINARY}: no such file`);
    return path;
  }
  const script = String((await Bun.file(join(SERVER_ROOT, "package.json")).json()).scripts["build:x64"]);
  // "bun build src/main.ts --compile ... --target=... --outfile dist/..." minus the target and outfile.
  const words = script.split(/\s+/).slice(1);
  const flags: string[] = [];
  for (let i = 0; i < words.length; i++) {
    if (words[i] === "--outfile" || words[i] === "--target") i++;
    else if (!/^--(outfile|target)=/.test(words[i]!)) flags.push(words[i]!);
  }
  if (flags[0] !== "build" || !flags.includes("--compile")) throw new Error(`Unexpected build:x64 script: ${script}`);
  const binary = join(outDir, "links-server");
  const build = await runProcess("bun build", [process.execPath, ...flags, "--outfile", binary], {
    cwd: SERVER_ROOT, env: { PATH: process.env.PATH ?? "/usr/bin:/bin" }, timeoutMs: 120_000,
  });
  if (build.code !== 0) throw new Error(`bun build failed (${build.code})\n${build.logs()}`);
  return binary;
}

const children = new Set<Child>();

/** A child process whose stdout and stderr are collected as they arrive (so the pipes never fill). */
export class Child {
  stdout = "";
  stderr = "";
  private readonly drained: Promise<unknown>;

  constructor(readonly name: string, readonly proc: Bun.Subprocess<"ignore", "pipe", "pipe">) {
    this.drained = Promise.all([this.drain(proc.stdout, "stdout"), this.drain(proc.stderr, "stderr")]);
    children.add(this);
  }

  private async drain(stream: ReadableStream<Uint8Array>, key: "stdout" | "stderr") {
    const decoder = new TextDecoder();
    for await (const chunk of stream) this[key] += decoder.decode(chunk, { stream: true });
  }

  get running(): boolean {
    return this.proc.exitCode === null && this.proc.signalCode === null;
  }

  /** Exit code (or signal name) once the process ends and its output is read, or null on timeout. */
  async exit(timeoutMs: number): Promise<number | string | null> {
    const ended = await Promise.race([this.proc.exited.then(() => true), Bun.sleep(timeoutMs).then(() => false)]);
    if (!ended) return null;
    await this.drained;
    return this.proc.signalCode ?? this.proc.exitCode;
  }

  logs(): string {
    const tail = (s: string) => (s.length > 4000 ? `...${s.slice(-4000)}` : s) || "(empty)";
    return `--- ${this.name} stdout ---\n${tail(this.stdout)}\n--- ${this.name} stderr ---\n${tail(this.stderr)}`;
  }
}

type Env = Record<string, string | undefined>;

function spawn<C extends Child>(Kind: new (name: string, proc: Bun.Subprocess<"ignore", "pipe", "pipe">) => C,
                                name: string, cmd: string[], opts: { cwd: string; env: Env }): C {
  // Only the env given (undefined drops a key): a developer's own WORKOS_CLIENT_ID or DATA_DIR must not leak in.
  const env = Object.fromEntries(Object.entries(opts.env).filter(([, v]) => v !== undefined)) as Record<string, string>;
  return new Kind(name, Bun.spawn({ cmd, cwd: opts.cwd, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" }));
}

export async function runProcess(name: string, cmd: string[], opts: { cwd: string; env: Env; timeoutMs?: number }) {
  const child = spawn(Child, name, cmd, opts);
  const code = await child.exit(opts.timeoutMs ?? 15_000);
  if (code === null) {
    child.proc.kill("SIGKILL");
    throw new Error(`${name} didn't finish within ${opts.timeoutMs ?? 15_000} ms\n${child.logs()}`);
  }
  return { code, stdout: child.stdout, stderr: child.stderr, logs: () => child.logs() };
}

/** A running `links-server`, ready (it printed its address and /healthz answers). */
export class Server extends Child {
  url = "";

  /** Signal it and wait; returns how it exited and how long that took. */
  async stop(signal: "SIGTERM" | "SIGINT" = "SIGTERM", timeoutMs = 5000) {
    const started = performance.now();
    this.proc.kill(signal);
    const code = await this.exit(timeoutMs);
    if (code === null) {
      this.proc.kill("SIGKILL");
      throw new Error(`${this.name} was still running ${timeoutMs} ms after ${signal}\n${this.logs()}`);
    }
    return { code, ms: performance.now() - started };
  }
}

export async function startServer(name: string, binary: string, opts: { cwd: string; env: Env }): Promise<Server> {
  const server = spawn(Server, name, [binary], opts);
  const notRunning = () => {
    if (!server.running) throw new Error(`${name} exited (${server.proc.signalCode ?? server.proc.exitCode}) before it was ready\n${server.logs()}`);
  };
  // PORT=0 lets the OS pick a free port; the startup line says which.
  server.url = await until(`${name} to print its address`, () => {
    notRunning();
    return server.stdout.match(/Links API running on (http:\/\/[^\s/]+)\//)?.[1];
  }, 15_000, server);
  await until(`${name} /healthz`, async () => {
    notRunning();
    return (await fetch(`${server.url}/healthz`).catch(() => null))?.status === 200;
  }, 10_000, server);
  return server;
}

/** Poll until `check` returns something truthy (not a fixed sleep). */
export async function until<T>(what: string, check: () => T | null | undefined | false | Promise<T | null | undefined | false>,
                               timeoutMs = 10_000, child?: Child): Promise<T> {
  const deadline = performance.now() + timeoutMs;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (performance.now() > deadline) {
      throw new Error(`Timed out after ${timeoutMs} ms waiting for ${what}${child ? `\n${child.logs()}` : ""}`);
    }
    await Bun.sleep(25);
  }
}

/** Kill anything still running (afterAll, and after a failed test). */
export function killAll() {
  for (const child of children) if (child.running) child.proc.kill("SIGKILL");
}

/** Every child's output, for failure messages. */
export function allLogs(): string {
  return [...children].filter((c) => c.stdout || c.stderr).map((c) => c.logs()).join("\n");
}

/** Run a test body and, if it fails, put the processes' output in the failure message. */
export async function withLogs(fn: () => unknown, extra: () => string = () => "") {
  try {
    await fn();
  } catch (e) {
    const logs = [`\n\n${allLogs()}`, extra()].filter(Boolean).join("\n");
    if (e instanceof Error) e.message += logs;
    else throw new Error(`${String(e)}${logs}`);
    throw e;
  }
}

/**
 * Everything the binary fetches from the internet goes through this "proxy", which refuses it,
 * so the suite never depends on (or touches) tiktok.com. Only the stubs on 127.0.0.1 are reached
 * directly. (DNS lookups for a preview's host still happen; their result doesn't matter.)
 */
export function startEgressTrap() {
  const attempts: string[] = [];
  const listener = Bun.listen({
    hostname: "127.0.0.1",
    port: 0,
    socket: {
      data(socket, data) {
        attempts.push(data.toString().split("\r\n")[0]!);
        socket.end("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
      },
    },
  });
  const proxy = `http://127.0.0.1:${listener.port}`;
  return {
    attempts,
    env: { HTTP_PROXY: proxy, HTTPS_PROXY: proxy, NO_PROXY: "127.0.0.1,localhost" },
    stop: () => listener.stop(true),
  };
}

export const s256 = (verifier: string) => createHash("sha256").update(verifier).digest("base64url");

/** A PKCE pair, as the iOS app makes one. */
export function pkce() {
  const verifier = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
  return { verifier, challenge: s256(verifier) };
}

export interface Reply {
  status: number;
  data: any;
  text: string;
  headers: Headers;
}

export async function request(base: string, path: string,
                              opts: { method?: string; token?: string; body?: unknown; headers?: Record<string, string> } = {}): Promise<Reply> {
  const res = await fetch(base + path, {
    method: opts.method ?? (opts.body === undefined ? "GET" : "POST"),
    redirect: "manual",
    headers: {
      ...(opts.token ? { Authorization: `Bearer ${opts.token}` } : {}),
      ...(opts.body === undefined ? {} : { "Content-Type": "application/json" }),
      ...opts.headers,
    },
    body: opts.body === undefined ? undefined : typeof opts.body === "string" ? opts.body : JSON.stringify(opts.body),
  });
  const text = await res.text();
  let data: any = text;
  try {
    data = JSON.parse(text);
  } catch {}
  return { status: res.status, data, text, headers: res.headers };
}
