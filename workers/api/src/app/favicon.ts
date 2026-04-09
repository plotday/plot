import { Hono } from "hono";

import type { Bindings } from "../env";

const MAX_SIZE = 1024 * 1024; // 1MB

const favicon = new Hono<{ Bindings: Bindings }>();

/**
 * Favicon proxy — fetches an external favicon and returns it with CORS headers.
 * Used by the Flutter web app where direct cross-origin favicon fetches are blocked.
 */
favicon.get("/favicon", async (c) => {
  const url = c.req.query("url");
  if (!url) {
    return c.json({ error: "Missing url parameter" }, 400);
  }

  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return c.json({ error: "Invalid URL" }, 400);
  }

  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    return c.json({ error: "URL must be http or https" }, 400);
  }

  try {
    const upstream = await fetch(url, {
      signal: AbortSignal.timeout(5000),
      headers: { "User-Agent": "Plot/1.0 (favicon proxy)" },
    });

    if (!upstream.ok) {
      return c.json({ error: "Upstream returned " + upstream.status }, 502);
    }

    const contentType = upstream.headers.get("Content-Type") ?? "";
    if (
      !contentType.startsWith("image/") &&
      contentType !== "application/octet-stream"
    ) {
      return c.json({ error: "Not an image" }, 502);
    }

    const body = await upstream.arrayBuffer();
    if (body.byteLength > MAX_SIZE) {
      return c.json({ error: "Response too large" }, 502);
    }

    return new Response(body, {
      headers: {
        "Content-Type": contentType,
        "Cache-Control": "public, max-age=86400",
      },
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "Fetch failed";
    return c.json({ error: message }, 502);
  }
});

export default favicon;
