"use strict";

const $ = (sel) => document.querySelector(sel);
const EMOJIS = ["❤️", "😂", "🔥", "😮", "😭", "👎"];
const PLATFORM = {
  tiktok: { label: "TikTok", glyph: "♪", noun: "TikTok" },
  instagram: { label: "Instagram", glyph: "◎", noun: "Instagram post" },
  youtube: { label: "YouTube", glyph: "▶", noun: "YouTube video" },
  x: { label: "X", glyph: "𝕏", noun: "Post on X" },
  reddit: { label: "Reddit", glyph: "r/", noun: "Reddit post" },
  facebook: { label: "Facebook", glyph: "f", noun: "Facebook post" },
  web: { label: "Link", glyph: "🔗", noun: "Link" },
};
const COLORS = ["#ff9500", "#34c759", "#5856d6", "#ff2d55", "#00c7be", "#af52de", "#007aff", "#ff3b30"];
const ICON = {
  check: '<svg viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  sent: '<svg viewBox="0 0 24 24"><path d="M7 17L17 7M9 7h8v8" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  more: '<svg viewBox="0 0 24 24"><circle cx="5" cy="12" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="19" cy="12" r="2"/></svg>',
  play: '<svg viewBox="0 0 10 12"><path d="M0 0l10 6-10 6z"/></svg>',
};

// ------------------------------------------------------------ storage

const store = {
  get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { v == null ? localStorage.removeItem(k) : localStorage.setItem(k, v); } catch {} },
};

const state = {
  me: store.get("me"),
  key: store.get("key"),
  filter: store.get("filter") || "unseen",
  query: "",
  people: [],
  links: [],
  lastJson: "",
};

// ------------------------------------------------------------ api

async function api(path, { method = "GET", body } = {}) {
  const headers = { "Content-Type": "application/json" };
  if (state.key) headers["X-Key"] = state.key;
  const res = await fetch(path, { method, headers, body: body && JSON.stringify(body), keepalive: method !== "GET" });
  const data = await res.json().catch(() => ({}));
  if (res.status === 401) { openSheet("#lockSheet"); throw new Error("locked"); }
  if (!res.ok) throw new Error(data.error || "Something went wrong.");
  return data;
}

async function load() {
  try {
    const data = await api("/api/state");
    setStatus("");
    const json = JSON.stringify(data);
    if (json === state.lastJson) return data;
    state.lastJson = json;
    state.people = data.people;
    state.links = data.links;
    render();
    return data;
  } catch (e) {
    if (e.message !== "locked") setStatus("Offline");
  }
}

function patchLink(link) {
  const i = state.links.findIndex((l) => l.id === link.id);
  if (i >= 0) state.links[i] = link; else state.links.unshift(link);
  state.lastJson = "";
  render();
}

// ------------------------------------------------------------ helpers

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const isMine = (l) => l.added_by === state.me;
const seenByMe = (l) => state.me in l.seen;
const others = (names) => names.filter((n) => n !== state.me);

function colorFor(name) {
  let h = 0;
  for (const ch of name) h = (h * 31 + ch.codePointAt(0)) >>> 0;
  return COLORS[h % COLORS.length];
}

function avatar(name, cls = "") {
  const initials = name.split(/\s+/).map((w) => [...w][0] || "").join("").slice(0, 2).toUpperCase();
  return `<span class="avatar ${cls}" style="--c:${colorFor(name)}">${esc(initials)}</span>`;
}

function ago(ts) {
  const s = Date.now() / 1000 - ts;
  if (s < 60) return "now";
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  const d = new Date(ts * 1000);
  const days = Math.floor(s / 86400);
  if (days < 2) return "Yesterday";
  if (days < 7) return d.toLocaleDateString(undefined, { weekday: "short" });
  return d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

function list(names) {
  return names.length <= 2 ? names.join(" & ") : `${names.slice(0, -1).join(", ")} & ${names.at(-1)}`;
}

function fallbackTitle(l) {
  const p = PLATFORM[l.platform] || PLATFORM.web;
  if (l.platform === "web") { try { return new URL(l.url).hostname.replace(/^www\./, ""); } catch {} }
  if (l.platform === "instagram" && l.url.includes("/reel/")) return "Instagram reel";
  return p.noun;
}

let toastTimer;
function toast(msg) {
  const el = $("#toast");
  el.textContent = msg;
  el.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("show"), 2400);
}

function setStatus(text) { $("#status").textContent = text; }

// ------------------------------------------------------------ render

function matches(l) {
  if (state.filter === "unseen" && (isMine(l) || seenByMe(l))) return false;
  if (state.filter === "seen" && (isMine(l) || !seenByMe(l))) return false;
  if (state.filter === "sent" && !isMine(l)) return false;
  if (!state.query) return true;
  const hay = [l.title, l.author, l.note, l.added_by, l.url, PLATFORM[l.platform]?.label].join(" ").toLowerCase();
  return state.query.toLowerCase().split(/\s+/).every((w) => hay.includes(w));
}

function rowHtml(l) {
  const p = PLATFORM[l.platform] || PLATFORM.web;
  const mine = isMine(l);
  const seen = seenByMe(l);
  const seenOthers = others(Object.keys(l.seen)).filter((n) => n !== l.added_by);

  const check = mine
    ? `<span class="check sent" title="You sent this">${ICON.sent}</span>`
    : `<button class="check ${seen ? "on" : ""}" data-act="toggle" aria-label="${seen ? "Mark as not watched" : "Mark as watched"}">${ICON.check}</button>`;

  const thumb = l.thumb
    ? `<img src="${esc(l.thumb)}" alt="" loading="lazy" onerror="this.remove()"><span class="play">${ICON.play}</span>`
    : `<span class="glyph">${esc(p.glyph)}</span>`;

  const title = l.meta === "pending"
    ? `<span class="title loading"></span>`
    : `<a class="title" href="${esc(l.url)}" target="_blank" rel="noopener" data-act="open">${esc(l.title || fallbackTitle(l))}</a>`;

  let receipt = "";
  if (mine) {
    receipt = seenOthers.length
      ? `<span class="receipt seen">✓ Seen by ${esc(list(seenOthers))}</span>`
      : `<span class="receipt">Not seen yet</span>`;
  } else if (seenOthers.length) {
    receipt = `<span class="receipt">Also seen by ${esc(list(seenOthers))}</span>`;
  }
  const reactions = Object.entries(l.reactions)
    .map(([who, e]) => `<span class="reaction ${who === state.me ? "mine" : ""}">${e} ${esc(who === state.me ? "You" : who)}</span>`)
    .join("");

  return `
    <article class="row ${!mine && !seen ? "unseen" : ""}" data-id="${l.id}">
      ${check}
      <a class="thumb ph-${esc(l.platform)}" href="${esc(l.url)}" target="_blank" rel="noopener" data-act="open" aria-label="Open">${thumb}</a>
      <div class="body">
        <div class="meta">
          <span class="pill ${esc(l.platform)}">${esc(p.label)}</span>
          <span class="from">${mine ? "You" : esc(l.added_by)}${l.author ? ` · ${esc(l.author)}` : ""}</span>
          <span class="time">${ago(l.added_at)}</span>
          <button class="more" data-act="more" aria-label="More">${ICON.more}</button>
        </div>
        ${title}
        ${l.note ? `<div class="note">${esc(l.note)}</div>` : ""}
        ${receipt || reactions ? `<div class="footer-line">${receipt}${reactions}</div>` : ""}
      </div>
    </article>`;
}

function render() {
  const unseen = state.links.filter((l) => !isMine(l) && !seenByMe(l)).length;
  $("#unseenCount").textContent = unseen || "";
  document.title = unseen ? `Links (${unseen})` : "Links";
  if (navigator.setAppBadge) (unseen ? navigator.setAppBadge(unseen) : navigator.clearAppBadge()).catch(() => {});

  for (const b of document.querySelectorAll("#filters button")) b.setAttribute("aria-selected", b.dataset.filter === state.filter);
  $("#whoBtn").innerHTML = state.me ? avatar(state.me) : "";

  const shown = state.links.filter(matches);
  $("#list").innerHTML = shown.map(rowHtml).join("");

  const empty = $("#empty");
  empty.hidden = shown.length > 0;
  if (!shown.length) {
    const [big, h, p] = state.query ? ["🔍", "No Results", `Nothing matches “${state.query}”.`]
      : !state.links.length ? ["🎬", "No Links Yet", "Tap New Link to share your first reel or TikTok."]
      : { unseen: ["🎉", "All Caught Up", "You've watched everything you were sent."],
          seen: ["🍿", "Nothing Watched Yet", "Links you've watched will show up here."],
          sent: ["📤", "Nothing Sent Yet", "Links you share will show up here, with who's seen them."],
          all: ["🎬", "No Links Yet", ""] }[state.filter];
    empty.innerHTML = `<div class="big">${big}</div><h3>${esc(h)}</h3><p>${esc(p)}</p>`;
  }
}

// ------------------------------------------------------------ actions

async function setSeen(link, seen, { quiet = false } = {}) {
  if (seen === seenByMe(link)) return;
  const row = document.querySelector(`.row[data-id="${link.id}"]`);
  const leaves = (state.filter === "unseen" && seen) || (state.filter === "seen" && !seen);
  if (seen) link.seen[state.me] = Date.now() / 1000; else delete link.seen[state.me];
  if (row && leaves && !quiet) {
    row.querySelector(".check")?.classList.toggle("on", seen);
    row.classList.add("leaving");
    setTimeout(render, 330);
  } else {
    render();
  }
  try {
    patchLink((await api(`/api/links/${link.id}/seen`, { method: "POST", body: { by: state.me, seen } })).link);
  } catch (e) { toast(e.message); load(); }
}

async function react(link, emoji) {
  const next = link.reactions[state.me] === emoji ? null : emoji;
  try {
    patchLink((await api(`/api/links/${link.id}/react`, { method: "POST", body: { by: state.me, emoji: next } })).link);
  } catch (e) { toast(e.message); }
}

async function addLink(text, note = "") {
  try {
    const { link, duplicate } = await api("/api/links", { method: "POST", body: { url: text, note, by: state.me } });
    patchLink(link);
    if (duplicate) {
      toast(link.added_by === state.me ? "You already added this one" : `Already here, ${link.added_by} sent it ${ago(link.added_at)}`);
    } else {
      toast("Added ✓");
      if (state.filter !== "sent" && state.filter !== "all") setFilter("sent");
      pollFast();
    }
    return true;
  } catch (e) {
    toast(e.message);
    return false;
  }
}

function moreActions(link) {
  const mine = isMine(link);
  const seen = seenByMe(link);
  const items = [];
  if (!mine) items.push({ label: seen ? "Mark as Not Watched" : "Mark as Watched", run: () => setSeen(link, !seen) });
  items.push({ label: link.note ? "Edit Note" : "Add Note", run: () => editNote(link) });
  if (navigator.share) items.push({ label: "Share…", run: () => navigator.share({ url: link.url }).catch(() => {}) });
  items.push({ label: "Copy Link", run: () => navigator.clipboard.writeText(link.url).then(() => toast("Copied"), () => toast("Couldn't copy")) });
  items.push({ label: "Delete", destructive: true, run: () => deleteLink(link) });

  actionSheet({
    head: `<b>${esc(link.title || fallbackTitle(link))}</b>${mine ? "Sent by you" : `From ${esc(link.added_by)}`} · ${ago(link.added_at)}`,
    emojis: { current: link.reactions[state.me], pick: (e) => react(link, e) },
    items,
  });
}

async function editNote(link) {
  const note = prompt("Note", link.note);
  if (note === null) return;
  try { patchLink((await api(`/api/links/${link.id}`, { method: "PATCH", body: { note } })).link); }
  catch (e) { toast(e.message); }
}

async function deleteLink(link) {
  if (!confirm(`Delete this ${fallbackTitle(link).toLowerCase()} for everyone?`)) return;
  try {
    await api(`/api/links/${link.id}`, { method: "DELETE" });
    state.links = state.links.filter((l) => l.id !== link.id);
    render();
    toast("Deleted");
  } catch (e) { toast(e.message); }
}

function setFilter(f) {
  state.filter = f;
  store.set("filter", f);
  render();
}

// ------------------------------------------------------------ sheets

function openSheet(sel) {
  const el = $(sel);
  el.classList.remove("closing");
  el.hidden = false;
}

function closeSheet(el) {
  if (typeof el === "string") el = $(el);
  if (el.hidden || el.classList.contains("closing")) return;
  el.classList.add("closing");
  setTimeout(() => { el.hidden = true; el.classList.remove("closing"); }, 190);
}

function actionSheet({ head, emojis, items }) {
  const el = $("#actionSheet");
  el.innerHTML = `
    <div class="actions">
      <div class="action-group">
        <div class="action-head">${head}</div>
        <div class="emoji-row">${EMOJIS.map((e) => `<button data-emoji="${e}" class="${emojis.current === e ? "mine" : ""}">${e}</button>`).join("")}</div>
        ${items.map((it, i) => `<button class="action ${it.destructive ? "destructive" : ""}" data-i="${i}">${esc(it.label)}</button>`).join("")}
      </div>
      <div class="action-group cancel"><button class="action" data-cancel>Cancel</button></div>
    </div>`;
  el.onclick = (ev) => {
    const btn = ev.target.closest("button");
    if (!btn && ev.target.closest(".actions")) return;
    closeSheet(el);
    if (btn?.dataset.emoji) emojis.pick(btn.dataset.emoji);
    else if (btn?.dataset.i) setTimeout(() => items[+btn.dataset.i].run(), 200);
  };
  openSheet("#actionSheet");
}

function openAddSheet(prefill = "") {
  $("#urlInput").value = prefill;
  $("#noteInput").value = "";
  $("#saveBtn").disabled = !prefill;
  openSheet("#addSheet");
  $("#urlInput").focus();
}

function openNameSheet() {
  const people = state.people.length ? state.people : [];
  $("#peopleList").innerHTML = people.map((n) =>
    `<button type="button" class="person" data-name="${esc(n)}">${avatar(n)}<span>${esc(n)}</span>${n === state.me ? '<span class="tick">✓</span>' : ""}</button>`).join("");
  $("#peopleList").hidden = !people.length;
  $("#nameInput").value = "";
  $("#nameBtn").disabled = true;
  openSheet("#nameSheet");
}

async function chooseName(name) {
  try {
    const { name: saved } = await api("/api/people", { method: "POST", body: { name } });
    state.me = saved;
    store.set("me", saved);
    closeSheet("#nameSheet");
    state.lastJson = "";
    await load();
    render();
    handleIncomingShare();
  } catch (e) { toast(e.message); }
}

// ------------------------------------------------------------ wiring

$("#list").addEventListener("click", (ev) => {
  const target = ev.target.closest("[data-act]");
  if (!target) return;
  const link = state.links.find((l) => l.id === +target.closest(".row").dataset.id);
  if (!link) return;
  const act = target.dataset.act;
  if (act === "toggle") setSeen(link, !seenByMe(link));
  else if (act === "more") moreActions(link);
  else if (act === "open" && !isMine(link)) setTimeout(() => setSeen(link, true, { quiet: true }), 400);
});

$("#filters").addEventListener("click", (ev) => {
  const b = ev.target.closest("button");
  if (b) setFilter(b.dataset.filter);
});

$("#search").addEventListener("input", (ev) => { state.query = ev.target.value.trim(); render(); });
$("#addBtn").addEventListener("click", () => openAddSheet());
$("#whoBtn").addEventListener("click", openNameSheet);

for (const bd of document.querySelectorAll(".backdrop")) {
  bd.addEventListener("click", (ev) => {
    const dismissable = bd.id !== "lockSheet" && !(bd.id === "nameSheet" && !state.me);
    if ((ev.target === bd && dismissable) || ev.target.closest("[data-close]")) closeSheet(bd);
  });
}

$("#urlInput").addEventListener("input", (ev) => { $("#saveBtn").disabled = !ev.target.value.trim(); });
$("#pasteBtn").addEventListener("click", async () => {
  try {
    const text = await navigator.clipboard.readText();
    if (!text) return toast("Clipboard is empty");
    $("#urlInput").value = text;
    $("#saveBtn").disabled = false;
    $("#noteInput").focus();
  } catch { toast("Long-press the field and tap Paste"); $("#urlInput").focus(); }
});
$("#addForm").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  $("#saveBtn").disabled = true;
  if (await addLink($("#urlInput").value, $("#noteInput").value)) closeSheet("#addSheet");
  else $("#saveBtn").disabled = false;
});

$("#peopleList").addEventListener("click", (ev) => {
  const b = ev.target.closest("[data-name]");
  if (b) chooseName(b.dataset.name);
});
$("#nameInput").addEventListener("input", (ev) => { $("#nameBtn").disabled = !ev.target.value.trim(); });
$("#nameForm").addEventListener("submit", (ev) => {
  ev.preventDefault();
  if ($("#nameInput").value.trim()) chooseName($("#nameInput").value.trim());
});

$("#lockForm").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  state.key = $("#keyInput").value.trim();
  store.set("key", state.key);
  closeSheet("#lockSheet");
  if (await load()) start();
});

const nav = $("#nav");
addEventListener("scroll", () => nav.classList.toggle("scrolled", scrollY > 30), { passive: true });

// Live sync: poll while the app is open, faster right after adding (to pick up previews).
let pollTimer;
function schedule(ms) { clearTimeout(pollTimer); pollTimer = setTimeout(tick, ms); }
async function tick() { if (!document.hidden) await load(); schedule(fastUntil > Date.now() ? 1500 : 8000); }
let fastUntil = 0;
function pollFast() { fastUntil = Date.now() + 15000; schedule(1500); }
document.addEventListener("visibilitychange", () => { if (!document.hidden) { load(); schedule(8000); } });

function handleIncomingShare() {
  // Arrived from a share sheet (/add?url=...) or the "added" redirect.
  const params = new URLSearchParams(location.search);
  const hash = new URLSearchParams(location.hash.slice(1));
  if (params.has("key")) { state.key = params.get("key"); store.set("key", state.key); }
  if (params.has("added")) toast(params.get("dup") === "1" ? "That one's already here" : "Added ✓");
  const incoming = hash.get("add");
  if (params.toString() || location.hash) history.replaceState(null, "", "/");
  if (incoming && state.me) addLink(incoming);
}

async function start() {
  const data = await load();
  if (!data) return;
  if (!state.me || !data.people.includes(state.me)) {
    if (state.me) { store.set("me", null); state.me = null; }
    openNameSheet();
  } else {
    handleIncomingShare();
  }
  schedule(8000);
}

if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {});
{
  // Pick up ?key= before the first request so invite links work.
  const k = new URLSearchParams(location.search).get("key");
  if (k) { state.key = k; store.set("key", k); }
}
render();
start();
