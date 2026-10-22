import { exports } from "cloudflare:workers";

export const BASE = "http://share.test";

let ipCounter = 0;

/** Уникальный IP на вызов: rate limiter не мешает несвязанным тестам. */
export function freshIp(): string {
  ipCounter++;
  return `10.0.${Math.floor(ipCounter / 250)}.${ipCounter % 250}`;
}

export function call(path: string, init?: RequestInit): Promise<Response> {
  return exports.default.fetch(new Request(BASE + path, init));
}

export async function gzipBytes(text: string): Promise<Uint8Array> {
  const stream = new Blob([text]).stream().pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

export async function gunzipText(data: ArrayBuffer): Promise<string> {
  const stream = new Blob([data]).stream().pipeThrough(new DecompressionStream("gzip"));
  return new Response(stream).text();
}

export function track(n: number, extra: Record<string, unknown> = {}) {
  return {
    id: `t${n}`,
    source_id: "youtube",
    title: `Song ${n}`,
    artist: `Artist ${n}`,
    duration_ms: 180_000 + n,
    artwork_url: `https://img.example/${n}.jpg`,
    ...extra,
  };
}

export function payload(name = "Road trip", tracks: unknown[] = [track(1), track(2)]) {
  return { format: "player_playlist_share", version: 1, playlist: { name, tracks } };
}

export async function upload(body: unknown, ip = freshIp()): Promise<Response> {
  return call("/api/p", {
    method: "POST",
    headers: { "content-type": "application/gzip", "cf-connecting-ip": ip },
    body: await gzipBytes(typeof body === "string" ? body : JSON.stringify(body)),
  });
}
