import { Hono } from "hono";

import type { Bindings } from "../env";

const TIMEOUT_MS = 5000;
const MAX_BODY = 1024 * 1024; // 1MB
const USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
  "AppleWebKit/537.36 (KHTML, like Gecko) " +
  "Chrome/121.0.0.0 Safari/537.36 Plot/1.0";

const linkMetadata = new Hono<{ Bindings: Bindings }>();

type Metadata = { title: string | null; favicon: string | null };

/**
 * Returns `{ title, favicon }` for a public URL.
 *
 * Tries site-specific handlers (oEmbed for Reddit, YouTube, Twitter/X, Vimeo,
 * Spotify) before falling back to a generic HTML scrape. Always responds 200
 * with `{ title, favicon }`; either field may be null. Used by the Flutter
 * client which can't fetch arbitrary cross-origin pages from the browser.
 */
linkMetadata.get("/metadata", async (c) => {
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

  const result = await fetchMetadata(parsed);
  return c.json(result, 200, {
    "Cache-Control": "public, max-age=86400",
  });
});

async function fetchMetadata(url: URL): Promise<Metadata> {
  const handler = handlers[normalizeHost(url.hostname)];
  if (handler) {
    try {
      const result = await handler(url);
      if (result) return result;
    } catch {
      // Fall through to the generic scrape.
    }
  }
  return await fetchHtmlMetadata(url);
}

function normalizeHost(host: string): string {
  const lower = host.toLowerCase();
  for (const prefix of ["www.", "m.", "old.", "np."]) {
    if (lower.startsWith(prefix)) return lower.slice(prefix.length);
  }
  return lower;
}

type Handler = (url: URL) => Promise<Metadata | null>;

const handlers: Record<string, Handler> = {
  "reddit.com": (url) =>
    oembed({
      endpoint: "https://www.reddit.com/oembed",
      url,
      favicon:
        "https://www.redditstatic.com/desktop2x/img/favicon/favicon-32x32.png",
    }),
  "youtube.com": (url) =>
    oembed({
      endpoint: "https://www.youtube.com/oembed?format=json",
      url,
      favicon: "https://www.youtube.com/s/desktop/favicon.ico",
    }),
  "youtu.be": (url) =>
    oembed({
      endpoint: "https://www.youtube.com/oembed?format=json",
      url,
      favicon: "https://www.youtube.com/s/desktop/favicon.ico",
    }),
  "twitter.com": (url) => twitterOembed(url),
  "x.com": (url) => twitterOembed(url),
  "vimeo.com": (url) =>
    oembed({
      endpoint: "https://vimeo.com/api/oembed.json",
      url,
      favicon: "https://vimeo.com/favicon.ico",
    }),
  "open.spotify.com": (url) =>
    oembed({
      endpoint: "https://open.spotify.com/oembed",
      url,
      favicon: "https://open.spotify.com/favicon.ico",
    }),
};

/** Generic oEmbed call. Returns `{ title, favicon }` or null on any failure. */
async function oembed(args: {
  endpoint: string;
  url: URL;
  favicon: string;
}): Promise<Metadata | null> {
  const endpoint = new URL(args.endpoint);
  endpoint.searchParams.set("url", args.url.toString());

  const response = await fetch(endpoint.toString(), {
    signal: AbortSignal.timeout(TIMEOUT_MS),
    headers: {
      "User-Agent": USER_AGENT,
      Accept: "application/json",
    },
  });
  if (!response.ok) return null;

  const decoded = (await response.json().catch(() => null)) as
    | Record<string, unknown>
    | null;
  if (!decoded) return null;

  const title =
    typeof decoded.title === "string" ? decoded.title.trim() : null;
  return {
    title: title && title.length > 0 ? title : null,
    favicon: args.favicon,
  };
}

/**
 * Twitter's oEmbed returns `author_name` plus an `html` blockquote with the
 * tweet text. Build a usable title from those.
 */
async function twitterOembed(url: URL): Promise<Metadata | null> {
  const endpoint = new URL("https://publish.twitter.com/oembed");
  endpoint.searchParams.set("omit_script", "true");
  endpoint.searchParams.set("url", url.toString());

  const response = await fetch(endpoint.toString(), {
    signal: AbortSignal.timeout(TIMEOUT_MS),
    headers: {
      "User-Agent": USER_AGENT,
      Accept: "application/json",
    },
  });
  if (!response.ok) return null;

  const decoded = (await response.json().catch(() => null)) as
    | Record<string, unknown>
    | null;
  if (!decoded) return null;

  const author =
    typeof decoded.author_name === "string"
      ? decoded.author_name.trim()
      : null;
  const html = typeof decoded.html === "string" ? decoded.html : "";
  const text = decodeHtmlEntities(html.replace(/<[^>]+>/g, " "))
    .replace(/\s+/g, " ")
    .trim();

  let title: string | null = null;
  if (author && text) {
    const snippet = text.length > 140 ? `${text.slice(0, 140)}…` : text;
    title = `${author} on X: "${snippet}"`;
  } else if (text) {
    title = text;
  } else if (author) {
    title = `${author} on X`;
  }

  return {
    title,
    favicon: "https://abs.twimg.com/favicons/twitter.3.ico",
  };
}

/**
 * Generic HTML scrape: parses `<title>` and the first matching `<link rel>`
 * favicon. Falls back to `/favicon.ico` if no link tag is present. The
 * desktop User-Agent unblocks sites that 403 default fetch UAs.
 */
async function fetchHtmlMetadata(url: URL): Promise<Metadata> {
  try {
    const response = await fetch(url.toString(), {
      signal: AbortSignal.timeout(TIMEOUT_MS),
      headers: { "User-Agent": USER_AGENT },
    });
    if (!response.ok) return { title: null, favicon: null };

    const reader = response.body?.getReader();
    if (!reader) return { title: null, favicon: null };
    const chunks: Uint8Array[] = [];
    let received = 0;
    while (received < MAX_BODY) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      received += value.byteLength;
    }
    try {
      await reader.cancel();
    } catch {
      // Reader already closed.
    }
    const merged = new Uint8Array(received);
    let offset = 0;
    for (const chunk of chunks) {
      merged.set(chunk.subarray(0, Math.min(chunk.byteLength, received - offset)), offset);
      offset += chunk.byteLength;
      if (offset >= received) break;
    }
    const body = new TextDecoder("utf-8", { fatal: false }).decode(merged);

    let title: string | null = null;
    const titleMatch = body.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
    if (titleMatch) {
      const raw = titleMatch[1].trim();
      if (raw) {
        title = decodeHtmlEntities(raw).replace(/\s+/g, " ").trim();
        if (!title) title = null;
      }
    }

    let favicon: string | null = null;
    const linkRel =
      body.match(
        /<link[^>]*\brel\s*=\s*["'](?:icon|shortcut icon|apple-touch-icon)["'][^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*\/?>/i,
      ) ??
      body.match(
        /<link[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*\brel\s*=\s*["'](?:icon|shortcut icon|apple-touch-icon)["'][^>]*\/?>/i,
      );
    if (linkRel) {
      const href = linkRel[1];
      if (href) {
        try {
          favicon = new URL(href, url).toString();
        } catch {
          favicon = null;
        }
      }
    }
    if (!favicon) {
      favicon = new URL("/favicon.ico", url).toString();
    }

    return { title, favicon };
  } catch {
    return { title: null, favicon: null };
  }
}

function decodeHtmlEntities(input: string): string {
  return input
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&#x27;/g, "'")
    .replace(/&nbsp;/g, " ");
}

export default linkMetadata;
