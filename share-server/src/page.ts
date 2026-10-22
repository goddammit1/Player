import { PAGE_TRACK_LIMIT } from "./limits";
import type { SharePayload } from "./validate";

export interface PageContext {
  id: string;
  pageUrl: string;
  downloadUrl: string;
}

/** Схема deep link плеера (см. AndroidManifest.xml и ShareLinkHandler). */
export const APP_SCHEME = "playerapp";

// Скриптов на странице нет, поэтому CSP запрещает их совсем.
const CSP =
  "default-src 'none'; img-src https: http: data:; style-src 'unsafe-inline'; " +
  "base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

export function htmlResponse(body: string, status = 200, cache = true): Response {
  return new Response(body, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "content-security-policy": CSP,
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
      ...(cache ? { "cache-control": "public, max-age=3600" } : {}),
    },
  });
}

export function renderPlaylistPage(payload: SharePayload, ctx: PageContext): string {
  const { name, tracks } = payload.playlist;
  const cover = tracks.find((t) => t.artwork_url)?.artwork_url;
  const artists = [...new Set(tracks.map((t) => t.artist).filter((a) => a.trim()))].slice(0, 4);
  const description =
    `${tracks.length} ${tracks.length === 1 ? "track" : "tracks"}` +
    (artists.length ? ` · ${artists.join(", ")}` : "");

  const shown = tracks.slice(0, PAGE_TRACK_LIMIT);
  const rest = tracks.length - shown.length;
  const rows = shown
    .map(
      (t, i) => `
      <li>
        <span class="n">${i + 1}</span>
        ${t.artwork_url ? `<img src="${esc(t.artwork_url)}" alt="" loading="lazy">` : `<span class="ph"></span>`}
        <span class="meta"><span class="t">${esc(t.title)}</span><span class="a">${esc(t.artist)}</span></span>
        <span class="d">${formatDuration(t.duration_ms)}</span>
      </li>`,
    )
    .join("");

  return layout({
    title: name,
    head: `
  <meta property="og:type" content="music.playlist">
  <meta property="og:title" content="${esc(name)}">
  <meta property="og:description" content="${esc(description)}">
  <meta property="og:url" content="${esc(ctx.pageUrl)}">
  ${cover ? `<meta property="og:image" content="${esc(cover)}">` : ""}
  <meta name="twitter:card" content="summary">
  <meta name="description" content="${esc(description)}">`,
    body: `
  <header>
    ${cover ? `<img class="cover" src="${esc(cover)}" alt="">` : `<div class="cover ph"></div>`}
    <div>
      <p class="kicker">Playlist</p>
      <h1>${esc(name)}</h1>
      <p class="sub">${esc(description)}</p>
      <div class="actions">
        <a class="btn primary" href="${APP_SCHEME}://p/${ctx.id}">Open in Player</a>
        <a class="btn" href="${esc(ctx.downloadUrl)}">Download Player</a>
      </div>
    </div>
  </header>
  <ol class="tracks">${rows}</ol>
  ${rest > 0 ? `<p class="more">and ${rest} more ${rest === 1 ? "track" : "tracks"} — open in Player to see all</p>` : ""}`,
  });
}

export function renderNotFoundPage(downloadUrl: string): string {
  return layout({
    title: "Playlist not found",
    head: "",
    body: `
  <header class="empty">
    <div>
      <h1>Playlist not found</h1>
      <p class="sub">The link is broken or the playlist was never shared.</p>
      <div class="actions"><a class="btn" href="${esc(downloadUrl)}">Download Player</a></div>
    </div>
  </header>`,
  });
}

function layout(p: { title: string; head: string; body: string }): string {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${esc(p.title)}</title>${p.head}
  <style>${STYLE}</style>
</head>
<body>
<main>${p.body}
</main>
</body>
</html>`;
}

function formatDuration(ms?: number): string {
  if (ms == null) return "";
  const total = Math.round(ms / 1000);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = String(total % 60).padStart(2, "0");
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${s}` : `${m}:${s}`;
}

const ESCAPES: Record<string, string> = {
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
};

export function esc(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ESCAPES[c]);
}

const STYLE = `
:root{--bg:#f6f6f7;--card:#fff;--text:#111114;--muted:#6b6b76;--line:#e6e6ea;--accent:#111114;--on-accent:#fff}
@media (prefers-color-scheme:dark){:root{--bg:#0e0e11;--card:#17171c;--text:#f2f2f5;--muted:#9a9aa6;--line:#26262d;--accent:#f2f2f5;--on-accent:#0e0e11}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:760px;margin:0 auto;padding:32px 16px 48px}
header{display:flex;gap:24px;align-items:flex-end;margin-bottom:28px}
header.empty{min-height:50vh;align-items:center}
.cover{width:168px;height:168px;flex:none;border-radius:16px;object-fit:cover;background:var(--line)}
.kicker{margin:0;font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
h1{margin:4px 0 6px;font-size:clamp(24px,5vw,36px);line-height:1.1;overflow-wrap:anywhere}
.sub{margin:0;color:var(--muted)}
.actions{display:flex;flex-wrap:wrap;gap:10px;margin-top:18px}
.btn{display:inline-block;padding:10px 18px;border-radius:999px;border:1px solid var(--line);color:var(--text);text-decoration:none;font-weight:600;background:var(--card)}
.btn.primary{background:var(--accent);color:var(--on-accent);border-color:var(--accent)}
.tracks{list-style:none;margin:0;padding:6px;background:var(--card);border:1px solid var(--line);border-radius:16px}
.tracks li{display:flex;align-items:center;gap:12px;padding:8px 10px;border-radius:10px}
.tracks li+li{border-top:1px solid var(--line)}
.n{width:2.2em;flex:none;text-align:right;color:var(--muted);font-variant-numeric:tabular-nums}
.tracks img,.tracks .ph{width:40px;height:40px;flex:none;border-radius:8px;object-fit:cover;background:var(--line)}
.meta{display:flex;flex-direction:column;min-width:0;flex:1}
.t,.a{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.a{color:var(--muted);font-size:13px}
.d{flex:none;color:var(--muted);font-variant-numeric:tabular-nums;font-size:13px}
.more{text-align:center;color:var(--muted)}
@media (max-width:520px){header{flex-direction:column;align-items:flex-start}.cover{width:128px;height:128px}}
`;
