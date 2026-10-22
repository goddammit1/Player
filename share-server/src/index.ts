import { gunzipLimited } from "./gzip";
import { HttpError, errorJson, json } from "./http";
import { ID_PATTERN } from "./id";
import { MAX_COMPRESSED_BYTES, MAX_DECOMPRESSED_BYTES } from "./limits";
import { htmlResponse, renderNotFoundPage, renderPlaylistPage } from "./page";
import { loadSnapshot, loadSnapshotGzip, saveSnapshot } from "./storage";
import { validatePayload } from "./validate";

export interface Env {
  PLAYLISTS: KVNamespace;
  UPLOAD_LIMITER: RateLimit;
  /** Публичный адрес сервиса без `/` в конце; пусто — origin запроса. */
  PUBLIC_BASE_URL: string;
  DOWNLOAD_URL: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (e) {
      if (e instanceof HttpError) return errorJson(e.status, e.message);
      console.error(e);
      return errorJson(500, "Internal error");
    }
  },
} satisfies ExportedHandler<Env>;

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname;

  if (path === "/health") return new Response("ok");

  if (path === "/api/p") {
    if (request.method !== "POST") return methodNotAllowed("POST");
    return createSnapshot(request, env, url);
  }

  const api = path.match(/^\/api\/p\/([^/]+)$/);
  if (api) {
    if (request.method !== "GET") return methodNotAllowed("GET");
    return getSnapshot(api[1], env);
  }

  const page = path.match(/^\/p\/([^/]+)$/);
  if (page) {
    if (request.method !== "GET" && request.method !== "HEAD") return methodNotAllowed("GET");
    return getPage(page[1], env, url);
  }

  return errorJson(404, "Not found");
}

async function createSnapshot(request: Request, env: Env, url: URL): Promise<Response> {
  const ip = request.headers.get("cf-connecting-ip") ?? "local";
  const { success } = await env.UPLOAD_LIMITER.limit({ key: ip });
  if (!success) throw new HttpError(429, "Too many uploads, try again in a minute");

  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > MAX_COMPRESSED_BYTES) throw new HttpError(413, "Playlist is too large");

  const body = new Uint8Array(await request.arrayBuffer());
  if (body.length > MAX_COMPRESSED_BYTES) throw new HttpError(413, "Playlist is too large");

  const raw = await gunzipLimited(body, MAX_DECOMPRESSED_BYTES);
  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(raw));
  } catch {
    throw new HttpError(400, "Body is not valid JSON");
  }

  const id = await saveSnapshot(env.PLAYLISTS, validatePayload(parsed));
  return json({ id, url: `${baseUrl(env, url)}/p/${id}` }, 201);
}

async function getSnapshot(id: string, env: Env): Promise<Response> {
  if (!ID_PATTERN.test(id)) return errorJson(404, "Playlist not found");
  const data = await loadSnapshotGzip(env.PLAYLISTS, id);
  if (data === null) return errorJson(404, "Playlist not found");
  // Снимки неизменяемы — кэшировать можно навсегда.
  return new Response(data, {
    headers: {
      "content-type": "application/gzip",
      "cache-control": "public, max-age=31536000, immutable",
    },
  });
}

async function getPage(id: string, env: Env, url: URL): Promise<Response> {
  const payload = ID_PATTERN.test(id) ? await loadSnapshot(env.PLAYLISTS, id) : null;
  if (payload === null) return htmlResponse(renderNotFoundPage(env.DOWNLOAD_URL), 404, false);
  const pageUrl = `${baseUrl(env, url)}/p/${id}`;
  return htmlResponse(renderPlaylistPage(payload, { id, pageUrl, downloadUrl: env.DOWNLOAD_URL }));
}

function baseUrl(env: Env, url: URL): string {
  return (env.PUBLIC_BASE_URL || url.origin).replace(/\/+$/, "");
}

function methodNotAllowed(allow: string): Response {
  return new Response(JSON.stringify({ error: "Method not allowed" }), {
    status: 405,
    headers: { allow, "content-type": "application/json; charset=utf-8" },
  });
}
