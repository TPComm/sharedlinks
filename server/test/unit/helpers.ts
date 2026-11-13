import { spyOn } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/** A fresh temp directory and a function that deletes it. */
export function tempDir(prefix = "links-unit-") {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  return { dir, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

/**
 * Swap global fetch for `handler`, so code that talks to real hosts (tiktok.com, a public IP) runs
 * offline. With allowPrivateNetwork, safeFetch skips DNS, so the handler sees the URL as written.
 */
export function fakeFetch(handler: (url: string, init: RequestInit) => Response | Promise<Response>) {
  const calls: { url: string; headers: Headers; init: RequestInit & { tls?: { serverName?: string } } }[] = [];
  const spy = spyOn(globalThis, "fetch").mockImplementation((async (input: string | URL | Request, init?: RequestInit) => {
    const url = input instanceof Request ? input.url : String(input);
    calls.push({ url, headers: new Headers(init?.headers), init: init ?? {} });
    return handler(url, init ?? {});
  }) as typeof fetch);
  return { calls, restore: () => spy.mockRestore() };
}

export const redirect = (location: string, status = 302) =>
  new Response(null, { status, headers: { Location: location } });

/** A local HTTP server that logs every request's path and query. Unknown paths are 404s. */
export function stubServer(routes: Record<string, (req: Request) => Response | Promise<Response>>) {
  const requests: string[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(req) {
      const url = new URL(req.url);
      requests.push(url.pathname + url.search);
      const route = routes[url.pathname];
      return route ? route(req) : new Response("not found", { status: 404 });
    },
  });
  return { origin: `http://127.0.0.1:${server.port}`, requests, stop: () => server.stop(true) };
}

/** A local port nothing listens on (connections are refused at once). */
export function closedPort(): number {
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response() });
  const port = server.port;
  server.stop(true);
  return port!;
}

/** 1x1 PNG */
export const PNG = Uint8Array.from(
  atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="),
  (c) => c.charCodeAt(0),
);
