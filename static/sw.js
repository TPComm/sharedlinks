// Minimal service worker: keeps the app shell available offline and makes the app installable.
const CACHE = "links-v1";
const SHELL = ["/", "/app.css", "/app.js", "/manifest.webmanifest", "/icon-192.png"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin || !SHELL.includes(url.pathname)) return;
  // Network first so updates show up immediately; fall back to cache when offline.
  e.respondWith(fetch(e.request)
    .then((res) => { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(url.pathname, copy)); return res; })
    .catch(() => caches.match(url.pathname)));
});
