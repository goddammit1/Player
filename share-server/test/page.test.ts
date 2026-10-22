import { describe, expect, it } from "vitest";

import { PAGE_TRACK_LIMIT } from "../src/limits";
import { call, payload, track, upload } from "./helpers";

async function share(body: unknown): Promise<string> {
  const res = await upload(body);
  expect(res.status).toBe(201);
  return (await res.json<{ id: string }>()).id;
}

describe("GET /p/:id", () => {
  it("renders the playlist with OG tags and app link", async () => {
    const id = await share(payload());
    const res = await call(`/p/${id}`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
    expect(res.headers.get("content-security-policy")).toContain("default-src 'none'");

    const html = await res.text();
    expect(html).toContain('<meta property="og:title" content="Road trip">');
    expect(html).toContain('<meta property="og:description" content="2 tracks · Artist 1, Artist 2">');
    expect(html).toContain('<meta property="og:image" content="https://img.example/1.jpg">');
    expect(html).toContain(`href="playerapp://p/${id}"`);
    expect(html).toContain("Song 2");
    expect(html).toContain("3:00");
  });

  it("escapes user-provided text", async () => {
    const id = await share(
      payload('<script>alert(1)</script>"', [
        track(1, { title: "<img src=x onerror=alert(1)>", artwork_url: 'https://x.example/a.jpg"><script>' }),
      ]),
    );
    const html = await (await call(`/p/${id}`)).text();
    expect(html).not.toContain("<script>alert");
    expect(html).not.toContain("<img src=x");
    expect(html).toContain("&lt;script&gt;alert(1)&lt;/script&gt;&quot;");
    expect(html).toContain('https://x.example/a.jpg&quot;&gt;&lt;script&gt;');
  });

  it("shows at most PAGE_TRACK_LIMIT tracks", async () => {
    const tracks = Array.from({ length: PAGE_TRACK_LIMIT + 5 }, (_, i) => track(i));
    const id = await share(payload("Big", tracks));
    const html = await (await call(`/p/${id}`)).text();
    expect(html.match(/<li>/g)).toHaveLength(PAGE_TRACK_LIMIT);
    expect(html).toContain("and 5 more tracks");
  });

  it("returns a 404 page for unknown ids", async () => {
    const res = await call("/p/AAAAAAAAAA");
    expect(res.status).toBe(404);
    expect(res.headers.get("content-type")).toContain("text/html");
    expect(await res.text()).toContain("Playlist not found");
  });
});
