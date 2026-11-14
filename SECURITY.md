# Security policy

Links is a small app (an iOS app and the Bun server in this repository) kept up by two volunteers
in their spare time. Thank you for reporting problems privately.

## Report a vulnerability

Use GitHub's private vulnerability reporting: click **Report a vulnerability** on this
repository's Security tab, or go straight to
https://github.com/TPComm/sharedlinks/security/advisories/new. Only you and the maintainers can see
the report.

Please don't describe the problem in a public issue, pull request or discussion. If you can't use
the form, open an issue that only asks how to reach us privately.

Tell us what's affected (the server, the iOS app or the `deploy/` scripts), how to reproduce it,
and what an attacker could do with it.

## What to expect

- We aim to reply within 7 days, and to tell you within 30 days whether we'll fix it and roughly
  when. Sometimes it will take longer; we'll keep you posted in the report.
- Once a fix ships, we publish a GitHub security advisory and credit you if you'd like. Please keep
  the details private until then, or for 90 days if that comes first, and talk to us if you need a
  different date.
- There's no bug bounty.

## Supported versions

We only fix the latest of each:

- The server: the latest `main`, and the build running at https://links.tpcomm.co
  (`curl https://links.tpcomm.co/version` shows its commit)
- The iOS app: the current App Store and TestFlight build
- The `deploy/` scripts: the latest `main`

Older commits and app builds don't get fixes. If you run your own server from this code, update to
the latest `main`.

## Scope

In scope: the code in this repository and the production server at links.tpcomm.co.

Report these to their owners instead:

- The sign-in pages at auth.tpcomm.co, which WorkOS hosts:
  https://workos.com/security/responsible-disclosure
- Cloudflare, including the human check before sign-in: https://hackerone.com/cloudflare
- iOS, TestFlight and the App Store: https://security.apple.com
- Bun, Caddy, SQLite and the other projects we build on: their own security policies
- Servers other people run from this code: whoever runs them, unless the bug is in our code

Not in scope: denial of service, load or volume testing, spam, social engineering, and scanner
output that doesn't show a real impact.

## Rules for testing

- Use only your own accounts and data. Don't view, change or delete anyone else's links, notes or
  account. If you reach someone else's data by accident, stop, don't keep a copy, and say so in
  your report.
- Don't load test or run high-volume scans against links.tpcomm.co. It's one small server that
  real people use.
- Production only lets in people on its guest list, so test against a local copy instead:
  `cd server && bun install && bun run dev` starts one at http://localhost:8000, and
  `bun run mint-session you@example.com "Your Name"` prints a session token for it without
  WorkOS. Debug builds of the iOS app talk to that local server (see the README).
