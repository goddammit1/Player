import { describe, expect, it } from "vitest";

import { MAX_DECOMPRESSED_BYTES } from "../src/limits";
import { BASE, call, freshIp, gunzipText, gzipBytes, payload, track, upload } from "./helpers";

describe("health", () => {
  it("responds ok", async () => {
    const res = await call("/health");
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("ok");
  });
});

describe("POST /api/p + GET /api/p/:id", () => {
  it("round-trips a playlist", async () => {
    const res = await upload(payload());
    expect(res.status).toBe(201);
    const { id, url } = await res.json<{ id: string; url: string }>();
    expect(id).toMatch(/^[0-9A-Za-z]{10}$/);
    expect(url).toBe(`${BASE}/p/${id}`);

    const got = await call(`/api/p/${id}`);
    expect(got.status).toBe(200);
    expect(got.headers.get("content-type")).toBe("application/gzip");
    expect(got.headers.get("cache-control")).toContain("immutable");
    expect(JSON.parse(await gunzipText(await got.arrayBuffer()))).toEqual(payload());
  });

  it("returns the same id for the same playlist, regardless of key order", async () => {
    const a = await (await upload(payload())).json<{ id: string }>();
    const reordered = {
      playlist: { tracks: [track(1), track(2)], name: "Road trip" },
      version: 1,
      format: "player_playlist_share",
    };
    const b = await (await upload(reordered)).json<{ id: string }>();
    expect(b.id).toBe(a.id);
  });

  it("gives different playlists different ids", async () => {
    const a = await (await upload(payload("A"))).json<{ id: string }>();
    const b = await (await upload(payload("B"))).json<{ id: string }>();
    expect(a.id).not.toBe(b.id);
  });

  it("strips unknown fields, nulls and local artwork paths", async () => {
    const res = await upload(
      payload("x", [
        {
          ...track(1),
          artwork_url: "C:\\covers\\1.jpg",
          quality_label: null,
          secret: "nope",
          extra: { streamUrl: "https://m.example/1.mp3", n: 1, ok: true, none: null },
        },
      ]),
    );
    const { id } = await res.json<{ id: string }>();
    const stored = JSON.parse(await gunzipText(await (await call(`/api/p/${id}`)).arrayBuffer()));
    const t = stored.playlist.tracks[0];
    expect(t.secret).toBeUndefined();
    expect(t.artwork_url).toBeUndefined();
    expect("quality_label" in t).toBe(false);
    expect(t.extra).toEqual({ streamUrl: "https://m.example/1.mp3", n: 1, ok: true, none: null });
  });

  it("keeps nested extra (Soulseek alternates, SoundCloud transcodings)", async () => {
    const extra = {
      peerUsername: "alice",
      alternates: [{ peerUsername: "bob", remoteFilename: "a\\b.flac", sizeBytes: 123 }],
      transcodings: [{ url: "https://api.example/t/1", format: { protocol: "progressive" } }],
    };
    const { id } = await (await upload(payload("n", [track(1, { extra })]))).json<{ id: string }>();
    const stored = JSON.parse(await gunzipText(await (await call(`/api/p/${id}`)).arrayBuffer()));
    expect(stored.playlist.tracks[0].extra).toEqual(extra);
  });

  it.each([
    ["wrong format", { ...payload(), format: "player_playlists_backup" }],
    ["unsupported version", { ...payload(), version: 2 }],
    ["empty name", payload("   ")],
    ["empty playlist", payload("x", [])],
    ["track without id", payload("x", [{ ...track(1), id: "" }])],
    ["too deeply nested extra", payload("x", [track(1, { extra: { a: [[[{ b: 1 }]]] } })])],
    ["oversized extra", payload("x", [track(1, { extra: { a: Array.from({ length: 30 }, () => Array(30).fill(1)) } })])],
    ["extra that is not an object", payload("x", [track(1, { extra: [1] })])],
    ["negative duration", payload("x", [track(1, { duration_ms: -5 })])],
  ])("rejects %s with 400", async (_, body) => {
    const res = await upload(body);
    expect(res.status).toBe(400);
    expect((await res.json<{ error: string }>()).error).toBeTruthy();
  });

  it("rejects invalid JSON with 400", async () => {
    expect((await upload("{not json")).status).toBe(400);
  });

  it("rejects a body that is not gzip with 415", async () => {
    const res = await call("/api/p", {
      method: "POST",
      headers: { "cf-connecting-ip": freshIp() },
      body: JSON.stringify(payload()),
    });
    expect(res.status).toBe(415);
  });

  it("stops a zip bomb with 413", async () => {
    // ~20 МБ пробелов сжимаются в десятки КБ.
    const bomb = await gzipBytes(" ".repeat(MAX_DECOMPRESSED_BYTES + 1));
    expect(bomb.length).toBeLessThan(200_000);
    const res = await call("/api/p", {
      method: "POST",
      headers: { "cf-connecting-ip": freshIp() },
      body: bomb,
    });
    expect(res.status).toBe(413);
  });

  it("rate-limits uploads per IP with 429", async () => {
    const ip = freshIp();
    const statuses: number[] = [];
    for (let i = 0; i < 21; i++) statuses.push((await upload(payload(`p${i}`), ip)).status);
    expect(statuses.slice(0, 20).every((s) => s === 201)).toBe(true);
    expect(statuses[20]).toBe(429);
    // Другой IP не затронут.
    expect((await upload(payload("other"))).status).toBe(201);
  });

  it("returns 404 for unknown and malformed ids", async () => {
    expect((await call("/api/p/AAAAAAAAAA")).status).toBe(404);
    expect((await call("/api/p/..%2F..%2Fx")).status).toBe(404);
  });

  it("returns 405 for wrong methods", async () => {
    expect((await call("/api/p")).status).toBe(405);
    expect((await call("/api/p/AAAAAAAAAA", { method: "DELETE" })).status).toBe(405);
  });
});
