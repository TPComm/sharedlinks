import type { Config } from "./config.ts";

const escapeHtml = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

/** Public, static introduction. Keep it self-contained so the compiled server needs no web assets. */
export function landingPage(config: Pick<Config, "appScheme" | "appStoreId" | "publicUrl">): string {
  const appUrl = `${config.appScheme}://inbox`;
  const store = config.appStoreId
    ? `<a class="store-link" href="https://apps.apple.com/app/id${escapeHtml(encodeURIComponent(config.appStoreId))}">Get Links for iPhone <span aria-hidden="true">↗</span></a>`
    : "";
  const banner = config.appStoreId
    ? `<meta name="apple-itunes-app" content="app-id=${escapeHtml(config.appStoreId)}, app-argument=${escapeHtml(appUrl)}">`
    : "";
  const arrow = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true"><path d="M5 12h14m-6-6 6 6-6 6"/></svg>';
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Links — good finds, kept together.</title>
<meta name="description" content="A little shared inbox for the links you send each other. Save articles, videos, recipes and more, and catch up in your own time.">
<meta name="theme-color" content="#f6f7f2">
<meta property="og:title" content="Links — good finds, kept together.">
<meta property="og:description" content="A little shared inbox for the links you send each other. For your people, not your followers.">
<meta property="og:type" content="website">
<meta property="og:image" content="${escapeHtml(config.publicUrl)}/icon.png">
<link rel="icon" type="image/png" href="/icon.png">
${banner}
<style>
  :root{color-scheme:light;--paper:#f6f7f2;--ink:#202c27;--muted:#58655c;--green:#2d6246;--line:#dce2d7}
  *{box-sizing:border-box}
  html{scroll-behavior:smooth}
  body{margin:0;background:var(--paper);color:var(--ink);font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;-webkit-font-smoothing:antialiased}
  a{color:inherit;text-underline-offset:4px}
  a:focus-visible{outline:3px solid var(--green);outline-offset:6px}
  .wrap{max-width:1120px;margin:auto;padding:0 40px}
  header{display:flex;align-items:center;justify-content:space-between;padding-top:30px;padding-bottom:24px}
  .brand{display:flex;align-items:center;gap:10px;font-weight:700;font-size:22px;letter-spacing:-.8px;text-decoration:none}
  .brand img{display:block;width:37px;height:37px}
  nav{display:flex;align-items:center;gap:30px;font-size:14px;font-weight:500}
  nav a{text-decoration:none}
  nav a:hover,footer a:hover{color:var(--green);text-decoration:underline}
  .hero{display:grid;grid-template-columns:1.12fr 1fr;align-items:center;gap:68px;padding-top:66px;padding-bottom:80px}
  .eyebrow{display:flex;align-items:center;gap:9px;color:var(--green);font-size:11px;font-weight:700;letter-spacing:1.8px;text-transform:uppercase}
  .dot{width:7px;height:7px;border-radius:50%;background:#538663}
  h1{font-size:clamp(44px,5.7vw,68px);line-height:1.05;font-weight:650;letter-spacing:-3.5px;margin:23px 0}
  h1 em{font:italic 1.07em/1.05 Georgia,"Times New Roman",serif;color:var(--green);letter-spacing:-3px}
  .intro{max-width:410px;font-size:18px;line-height:1.7;color:var(--muted);margin-bottom:28px}
  .actions{display:flex;align-items:center;gap:22px;flex-wrap:wrap}
  .button{display:inline-flex;align-items:center;justify-content:center;gap:24px;min-height:50px;background:var(--green);color:white;padding:12px 22px;border-radius:9px;font-size:14px;font-weight:600;text-decoration:none;transition:background .15s}
  .button:hover{background:#214c35}
  .button svg{width:19px;height:19px}
  .store-link{font-size:13px;font-weight:600}
  .availability{max-width:370px;font-size:12px;line-height:1.8;color:var(--muted);margin:16px 0 0}
  .preview{position:relative;padding:31px 25px 25px;border:1px solid #dce4d7;border-radius:26px;background:#e9eee3;transform:rotate(2deg)}
  .preview:before{content:"";position:absolute;inset:14px -12px -12px 12px;border:1px solid #d8dfd0;border-radius:26px;z-index:-1}
  .inbox{background:#fff;border:1px solid #e2e6dd;border-radius:17px;padding:24px 19px 14px;box-shadow:0 14px 32px #273d2510;transform:rotate(-2deg)}
  .inbox-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:16px}
  .inbox-title{font-size:23px;font-weight:700;letter-spacing:-.9px}
  .avatar{display:grid;place-items:center;background:#ede7d9;color:#716242;width:29px;height:29px;border-radius:50%;font-size:10px;font-weight:700}
  .tabs{display:flex;border-bottom:1px solid #edf0e9;padding-bottom:12px;gap:23px;font-size:11px;color:#748071}
  .selected{color:var(--green);font-weight:700}
  .count{display:inline-block;background:#e7eee2;border-radius:4px;padding:0 5px;margin-left:3px}
  .sample{display:flex;align-items:center;gap:12px;padding:17px 0;border-bottom:1px solid #edf0e9}
  .sample:last-of-type{border:0}
  .art{display:grid;place-items:center;flex-shrink:0;width:66px;height:72px;border-radius:8px;overflow:hidden}
  .art svg{width:100%;height:100%}
  .sample-text{min-width:0}
  .source{font-size:8px;font-weight:700;letter-spacing:1px;text-transform:uppercase;color:#6b7867}
  .sample h2{font-size:12px;line-height:1.5;letter-spacing:-.15px;margin:3px 0 5px;font-weight:650}
  .from{font-size:9px;color:#64705f}
  .from strong{color:#4b6045;font-weight:600}
  .note{background:#f5f6f0;border-radius:5px;padding:5px 7px;font-size:9px;color:#64705f;margin-top:6px}
  .inbox-bottom{display:flex;align-items:center;justify-content:center;gap:6px;color:#6b7867;font-size:9px;padding-top:14px;border-top:1px solid #edf0e9}
  .inbox-bottom svg{width:12px;height:12px}
  figcaption{text-align:center;color:#64705f;font-size:10px;margin-top:20px;letter-spacing:.3px}
  figure{margin:0}
  .how{padding-top:33px;padding-bottom:43px;border-top:1px solid var(--line)}
  .section-label{font-size:11px;letter-spacing:1.7px;text-transform:uppercase;font-weight:600;color:var(--muted);margin:0 0 27px}
  .features{display:grid;grid-template-columns:repeat(3,1fr);gap:48px}
  .number{display:block;font:italic 18px Georgia,serif;color:#6b866e;margin-bottom:12px}
  h3{font-size:16px;letter-spacing:-.3px;font-weight:650;margin:0 0 6px}
  .features p{font-size:13px;line-height:1.8;color:var(--muted);margin:0}
  footer{display:flex;justify-content:space-between;align-items:center;gap:20px;border-top:1px solid var(--line);padding:23px 0 28px;font-size:11px;color:var(--muted)}
  footer p{margin:0}
  footer div{display:flex;gap:22px}
  footer a{text-decoration:none;display:inline-block;padding:8px 0}
  .skip{position:absolute;top:-100px;left:20px;background:white;padding:10px;z-index:2}
  .skip:focus{top:10px}
  @media(max-width:800px){.wrap{padding:0 25px}.hero{gap:35px;padding-top:44px;padding-bottom:60px}h1{font-size:49px;letter-spacing:-2.8px}.intro{font-size:16px}.preview{padding:23px 14px 20px}.inbox{padding:20px 13px 12px}.sample{gap:9px}.art{width:51px;height:62px}.features{gap:24px}}
  @media(max-width:600px){header{padding-top:20px}nav{gap:21px;font-size:12px}.hero{grid-template-columns:1fr;gap:45px;padding-top:35px;padding-bottom:55px}h1{font-size:54px;max-width:360px}.intro{max-width:350px}.preview{max-width:360px;width:100%;justify-self:center;padding:26px 21px 20px}.inbox{padding:22px 18px 14px}.art{width:64px;height:70px}.sample h2{font-size:13px}.source{font-size:9px}.from,.note{font-size:10px}.tabs{font-size:12px}.inbox-bottom{font-size:10px}.features{grid-template-columns:1fr;gap:25px}.number{margin-bottom:5px}.features p{max-width:360px;font-size:14px}footer{align-items:flex-start}.how{padding-bottom:32px}}
  @media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}.button{transition:none}}
</style>
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<div class="wrap">
  <header>
    <a class="brand" href="/" aria-label="Links home"><img src="/icon.png" width="37" height="37" alt="">Links</a>
    <nav aria-label="Main navigation"><a href="#how-it-works">How it works</a><a href="/support">Support <span aria-hidden="true">↗</span></a></nav>
  </header>
  <main id="main">
    <section class="hero" aria-labelledby="headline">
      <div>
        <div class="eyebrow"><span class="dot" aria-hidden="true"></span>A little less lost in the chat</div>
        <h1 id="headline">Good finds.<br>Better <em>together.</em></h1>
        <p class="intro">The recipe. That video. The article you’d love.<br>A little shared inbox for the links you send each other, ready when you are.</p>
        <div class="actions"><a class="button" href="${escapeHtml(appUrl)}">Open in Links ${arrow}</a>${store}</div>
        <p class="availability">Made for iPhone. Already have the app? Open it above.<br>New here? Links is invite-only. Ask a friend who uses it for an invite.</p>
      </div>
      <figure class="preview" aria-label="An illustrative Links inbox with example links">
        <div class="inbox">
          <div class="inbox-header"><span class="inbox-title">Your links</span><span class="avatar" aria-hidden="true">YO</span></div>
          <div class="tabs" aria-hidden="true"><span class="selected">Queue <span class="count">3</span></span><span>Seen</span><span>Sent</span></div>
          <div class="sample">
            <div class="art" aria-hidden="true"><svg viewBox="0 0 66 72"><rect width="66" height="72" fill="#e9e2d0"/><ellipse cx="33" cy="40" rx="28" ry="23" fill="#faf6e9"/><ellipse cx="33" cy="40" rx="21" ry="17" fill="#b5bf71"/><g fill="none" stroke="#e6bf6e" stroke-width="3"><path d="M18 30q31-7 28 9T20 48t24-15M22 27q-9 23 17 22t3-19M18 40q26-17 30 2"/></g><g fill="#4c7345"><ellipse cx="29" cy="29" rx="4" ry="7" transform="rotate(-30 29 29)"/><ellipse cx="41" cy="45" rx="4" ry="6" transform="rotate(35 41 45)"/></g></svg></div>
            <div class="sample-text"><div class="source">A recipe worth keeping</div><h2>Sunday calls for lemon pasta</h2><div class="from">From <strong>Alex</strong> · Just now</div><div class="note">“Let’s make this this weekend”</div></div>
          </div>
          <div class="sample">
            <div class="art" aria-hidden="true"><svg viewBox="0 0 66 72"><rect width="66" height="72" fill="#cad9d6"/><circle cx="49" cy="17" r="8" fill="#f8edd0"/><path d="m-10 60 30-37 25 37 12-21 23 33H-10" fill="#7b9683"/><path d="m-5 72 31-33 28 33" fill="#3d6657"/><path d="m26 72 8-20 7 20" fill="#d9dfbe"/></svg></div>
            <div class="sample-text"><div class="source">A place to go</div><h2>The long way home</h2><div class="from">From <strong>Sam</strong> · 12 min ago</div></div>
          </div>
          <div class="sample">
            <div class="art" aria-hidden="true"><svg viewBox="0 0 66 72"><rect width="66" height="72" fill="#e8cbb6"/><rect x="12" y="13" width="42" height="49" rx="3" fill="#fbf4e5" transform="rotate(-8 33 36)"/><path d="M23 26h23M22 32h20M21 38h24M20 44h15" stroke="#a9ac89" stroke-width="2"/><circle cx="48" cy="55" r="11" fill="#b16b4d"/><path d="m46 51 6 4-6 4z" fill="#fff8e9"/></svg></div>
            <div class="sample-text"><div class="source">A new perspective</div><h2>A small idea for a slower day</h2><div class="from">From <strong>Jamie</strong> · 1 hr ago</div></div>
          </div>
          <div class="inbox-bottom"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" aria-hidden="true"><rect x="4" y="7" width="8" height="7" rx="2"/><path d="M5.5 7V4a2.5 2.5 0 0 1 5 0v3"/></svg> Just you and your people</div>
        </div>
        <figcaption>A few made-up finds. Imagine yours here.</figcaption>
      </figure>
    </section>
    <section class="how" id="how-it-works" aria-labelledby="how-title">
      <h2 class="section-label" id="how-title">Less scrolling back. More catching up.</h2>
      <div class="features">
        <div><span class="number" aria-hidden="true">01 /</span><h3>Find it. Share it.</h3><p>See something they’d love? Send it to Links from your iPhone’s share sheet, with a little note if you like.</p></div>
        <div><span class="number" aria-hidden="true">02 /</span><h3>A place for “later”.</h3><p>Articles, videos, recipes, gift ideas. They’re all in your Queue, not buried in a conversation.</p></div>
        <div><span class="number" aria-hidden="true">03 /</span><h3>Stay in the loop.</h3><p>Catch up in your own time. React, leave a comment, and see when your friends have seen what you sent.</p></div>
      </div>
    </section>
  </main>
  <footer><p>For your people. Not your followers.</p><div><a href="/privacy">Privacy</a><a href="/support">Support</a></div></footer>
</div>
</body>
</html>`;
}
