# Server

TypeScript run directly by Bun 1.4.4 (the version CI, `@types/bun` and the shipped binary pin), no
framework, SQLite through `bun:sqlite`. Use Bun's built-ins (`Bun.serve`, `bun:sqlite`, `bun:test`)
over npm packages; the binary must stay self-contained.

```bash
bun install
bun run dev                                   # http://localhost:8000; data in ./data
bun run mint-session you@example.com "Name"   # a session token for /api/*, no WorkOS needed
bun run typecheck && bun test                 # offline
bun run build:x64 && LINKS_BINARY=dist/links-server-linux-x64 bun run test:e2e
```

## Layout

- `src/main.ts`: entry point and the admin CLI (`mint-session`, `delete-user`, `reports`, `backup`)
- `src/app.ts`: routes; auth is checked per route, and anything unmatched is the public 404
- `src/config.ts`: every environment variable, with its default
- `src/db.ts`: schema and migrations
- `src/accounts.ts` (WorkOS, sessions, legacy users, account deletion), `src/links.ts` (URL
  canonicalization), `src/previews.ts` (thumbnails and rich previews), `src/net.ts` (`safeFetch`,
  which blocks private addresses), `src/moderation.ts` (reports, blocks, the word list)

## Rules

- Schema changes are a new `migrateToVn` in `src/db.ts` that bumps `PRAGMA user_version` inside a
  transaction. Never edit a migration that has shipped; the server upgrades production databases
  in place on start.
- Fetch other hosts only through `safeFetch` in `src/net.ts` (SSRF protection).
- A new setting goes in `Config` and `configFromEnv` in `src/config.ts`, in `README.md`, and in
  `deploy/setup.sh` if the VPS needs it.
- Tests stay offline. `test/api.test.ts` drives the real server against a fake WorkOS;
  `test/unit/helpers.ts` has `tempDir`, `fakeFetch` and `stubServer`. `test/e2e/` runs the compiled
  binary as a process.
