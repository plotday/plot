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

    // Some servers return HTML error pages or other garbage with an
    // image-ish Content-Type. Sniff the actual bytes so the Flutter client
    // never tries to parse non-SVG content as SVG (which throws
    // XmlParserException from inside an isolate).
    const bytes = new Uint8Array(body);
    const lowerUrl = url.toLowerCase();
    const isSvg =
      contentType.includes("svg") ||
      lowerUrl.endsWith(".svg") ||
      lowerUrl.includes(".svg?");
    if (isSvg) {
      if (!looksLikeSvg(bytes)) {
        return c.json({ error: "Not a valid SVG" }, 502);
      }
    } else if (!looksLikeImage(bytes)) {
      return c.json({ error: "Not a recognized image format" }, 502);
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

/**
 * SVG sniff: bytes start with `<` (after BOM/whitespace) and contain `<svg`
 * within the first ~512 bytes (some SVGs lead with `<?xml`, doctypes, or
 * comments before the `<svg>` element).
 */
function looksLikeSvg(bytes: Uint8Array): boolean {
  let i = 0;
  if (
    bytes.length >= 3 &&
    bytes[0] === 0xef &&
    bytes[1] === 0xbb &&
    bytes[2] === 0xbf
  ) {
    i = 3;
  }
  while (i < bytes.length) {
    const b = bytes[i];
    if (b !== 0x20 && b !== 0x09 && b !== 0x0a && b !== 0x0d) break;
    i++;
  }
  if (i >= bytes.length || bytes[i] !== 0x3c /* < */) return false;
  const end = Math.min(i + 512, bytes.length - 3);
  for (let j = i; j < end; j++) {
    if (
      bytes[j] === 0x3c /* < */ &&
      bytes[j + 1] === 0x73 /* s */ &&
      bytes[j + 2] === 0x76 /* v */ &&
      bytes[j + 3] === 0x67 /* g */
    ) {
      return true;
    }
  }
  return false;
}

/** Magic-byte check for the raster/icon formats Flutter can decode. */
function looksLikeImage(bytes: Uint8Array): boolean {
  if (bytes.length < 4) return false;
  // PNG: 89 50 4E 47
  if (
    bytes[0] === 0x89 &&
    bytes[1] === 0x50 &&
    bytes[2] === 0x4e &&
    bytes[3] === 0x47
  ) {
    return true;
  }
  // JPEG: FF D8 FF
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return true;
  // GIF: 47 49 46 38
  if (
    bytes[0] === 0x47 &&
    bytes[1] === 0x49 &&
    bytes[2] === 0x46 &&
    bytes[3] === 0x38
  ) {
    return true;
  }
  // WebP: RIFF....WEBP
  if (
    bytes.length >= 12 &&
    bytes[0] === 0x52 &&
    bytes[1] === 0x49 &&
    bytes[2] === 0x46 &&
    bytes[3] === 0x46 &&
    bytes[8] === 0x57 &&
    bytes[9] === 0x45 &&
    bytes[10] === 0x42 &&
    bytes[11] === 0x50
  ) {
    return true;
  }
  // ICO: 00 00 01 00
  if (
    bytes[0] === 0x00 &&
    bytes[1] === 0x00 &&
    bytes[2] === 0x01 &&
    bytes[3] === 0x00
  ) {
    return true;
  }
  // BMP: 42 4D
  if (bytes[0] === 0x42 && bytes[1] === 0x4d) return true;
  return false;
}

export default favicon;
