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
  .preview{width:100%;max-width:306px;justify-self:center}
  .iphone{position:relative;padding:8px;border:1px solid #70736e;border-radius:46px;background:linear-gradient(135deg,#545852,#171a18 35%,#343833 75%,#767b73);box-shadow:inset 0 0 0 1px #a2a69c,0 24px 55px #273d2529,0 5px 12px #17231b1a}
  .iphone::before,.iphone::after{content:"";position:absolute;width:3px;border-radius:2px;background:linear-gradient(90deg,#777c73,#353a34)}
  .iphone::before{left:-3px;top:22%;height:7%;box-shadow:0 54px 0 #4d534b}
  .iphone::after{right:-3px;top:29%;height:11%}
  .phone-display{position:relative;overflow:hidden;border-radius:38px;background:white}
  .phone-display::after{content:"";position:absolute;top:1.9%;left:36%;width:28%;height:3.3%;border-radius:999px;background:#090a09;pointer-events:none}
  .app-screen{display:block;width:100%;height:auto}
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
  @media(max-width:800px){.wrap{padding:0 25px}.hero{gap:35px;padding-top:44px;padding-bottom:60px}h1{font-size:49px;letter-spacing:-2.8px}.intro{font-size:16px}.features{gap:24px}}
  @media(max-width:600px){header{padding-top:20px}nav{gap:21px;font-size:12px}.hero{grid-template-columns:1fr;gap:45px;padding-top:35px;padding-bottom:55px}h1{font-size:54px;max-width:360px}.intro{max-width:350px}.preview{max-width:326px}.features{grid-template-columns:1fr;gap:25px}.number{margin-bottom:5px}.features p{max-width:360px;font-size:14px}footer{align-items:flex-start}.how{padding-bottom:32px}}
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
      <figure class="preview">
        <div class="iphone">
          <div class="phone-display">
            <img class="app-screen" src="/app-preview.png" width="804" height="1748" fetchpriority="high" alt="The Links iPhone app showing a shared inbox with sample links.">
          </div>
        </div>
        <figcaption>The real Links app. A few made-up finds.</figcaption>
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
