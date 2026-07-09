import { Hono } from "hono";

import { createLogger } from "@plotday/worker-util";

import type { Bindings } from "../env";
import { requestExtraction } from "../extract/request";
import { isPublicHttpUrl } from "../extract/url-guard";

const extract = new Hono<{ Bindings: Bindings }>();

/**
 * POST /app/extract — idempotently begin (or reuse) extraction of a URL's
 * article content into the global cache. Fired fire-and-forget by the client
 * at compose time to warm the cache before the thread is committed.
 */
extract.post("/extract", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as { url?: unknown };
  const url = typeof body.url === "string" ? body.url : null;
  // isPublicHttpUrl also rejects private/loopback/link-local targets (SSRF).
  if (!url || !isPublicHttpUrl(url)) {
    return c.json({ error: "invalid url" }, 400);
  }
  try {
    const record = await requestExtraction(c.env, url);
    return c.json({ status: record.status });
  } catch (error) {
    createLogger({ operation: "extract-endpoint" }).error(
      "requestExtraction failed",
      error as Error
    );
    c.var.tracker?.captureException(error as Error);
    // Warm-up is best-effort; the thread-creation hook re-triggers extraction.
    return c.json({ status: "error" });
  }
});

export default extract;
