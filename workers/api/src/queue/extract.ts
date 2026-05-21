import type { PostHog } from "posthog-node";

import { createLogger } from "@plotday/worker-util";
import { sql } from "kysely";

import { createDb } from "../db";
import { type Bindings, type ExtractMessage } from "../env";
import {
  type ExtractResult,
  MIN_MARKDOWN_LENGTH,
  PARTIAL_CONVERSION_PREFIX,
  extractMarkdown,
} from "../extract/extractor";
import {
  BrowserRenderingError,
  getBrowserBinding,
  renderHtmlWithBrowser,
} from "../extract/browser";

/** Cap on the raw HTML response we'll buffer in memory before parsing. */
const MAX_HTML_BYTES = 5 * 1024 * 1024;

/** Browser-y UA — many sites return empty bodies to bot-y user agents. */
const USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";

type FailCode =
  | "fetch_failed"
  | "response_too_large"
  | "content_too_short"
  | "partial_conversion"
  | "parse_error"
  | "browser_render_failed"
  | "http_401"
  | "http_403";

/**
 * What terminal status a thrown `ExtractionFailure` should land the row in.
 * Defaults to `failed` for unexpected failures; access-restricted detections
 * raise an `auth_required` terminal status so the UI knows it's a known
 * gating outcome rather than an extractor bug.
 */
type TerminalStatus = "failed" | "auth_required";

export type RenderedWith = "raw" | "browser";

class ExtractionFailure extends Error {
  constructor(
    readonly code: FailCode,
    message: string,
    readonly terminalStatus: TerminalStatus = "failed"
  ) {
    super(message);
    this.name = "ExtractionFailure";
  }
}

async function readBodyCapped(
  res: Response,
  limit: number
): Promise<{ ok: true; html: string } | { ok: false }> {
  if (!res.body) return { ok: true, html: await res.text() };
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    if (!value) continue;
    total += value.byteLength;
    if (total > limit) {
      try {
        reader.cancel();
      } catch {
        // ignore — we already know we're abandoning this stream
      }
      return { ok: false };
    }
    chunks.push(value);
  }
  let out = "";
  const decoder = new TextDecoder();
  for (let i = 0; i < chunks.length; i++) {
    out += decoder.decode(chunks[i], { stream: i < chunks.length - 1 });
  }
  return { ok: true, html: out };
}

async function fetchRawHtml(url: string): Promise<string> {
  let res: Response;
  try {
    res = await fetch(url, {
      headers: { "User-Agent": USER_AGENT, Accept: "text/html,*/*" },
      redirect: "follow",
    });
  } catch (e) {
    throw new ExtractionFailure(
      "fetch_failed",
      e instanceof Error ? e.message : String(e)
    );
  }
  if (res.status === 401 || res.status === 403) {
    throw new ExtractionFailure(
      res.status === 401 ? "http_401" : "http_403",
      `fetch returned HTTP ${res.status}`,
      "auth_required"
    );
  }
  if (!res.ok) {
    throw new ExtractionFailure(
      "fetch_failed",
      `fetch returned HTTP ${res.status}`
    );
  }
  const read = await readBodyCapped(res, MAX_HTML_BYTES);
  if (!read.ok) {
    throw new ExtractionFailure(
      "response_too_large",
      `response exceeded ${MAX_HTML_BYTES} bytes`
    );
  }
  return read.html;
}

/**
 * Run defuddle on the given HTML and validate the resulting Markdown. Throws
 * `ExtractionFailure` if the output is unusable. Pure — no I/O — so it's
 * cheap to invoke twice (once for raw HTML, once for the browser-rendered
 * fallback).
 */
function extractAndValidate(url: string, html: string): ExtractResult {
  let result: ExtractResult;
  try {
    result = extractMarkdown(url, html);
  } catch (e) {
    throw new ExtractionFailure(
      "parse_error",
      e instanceof Error ? e.message : String(e)
    );
  }
  if (result.md.startsWith(PARTIAL_CONVERSION_PREFIX)) {
    throw new ExtractionFailure(
      "partial_conversion",
      "defuddle reported a partial Turndown conversion"
    );
  }
  if (result.md.length < MIN_MARKDOWN_LENGTH) {
    throw new ExtractionFailure(
      "content_too_short",
      `markdown length ${result.md.length} < ${MIN_MARKDOWN_LENGTH} — likely JS-rendered or bot-blocked`
    );
  }
  return result;
}

/**
 * Try the raw-HTML extraction first. If that fails with `content_too_short` —
 * the JS-rendered-page / bot-interstitial signal — and Browser Rendering is
 * configured, retry against the browser-rendered HTML. Returns the successful
 * `ExtractResult` along with the path that produced it, or re-throws the last
 * `ExtractionFailure`.
 */
async function extractWithFallback(
  env: Bindings,
  url: string,
  logger: ReturnType<typeof createLogger>
): Promise<{ result: ExtractResult; renderedWith: RenderedWith }> {
  let rawFailure: ExtractionFailure | undefined;
  try {
    const html = await fetchRawHtml(url);
    return { result: extractAndValidate(url, html), renderedWith: "raw" };
  } catch (e) {
    if (!(e instanceof ExtractionFailure)) throw e;
    rawFailure = e;
  }

  // Only `content_too_short` benefits from a browser render (the typical SPA
  // / bot-interstitial signal). Hard fetch failures, oversized bodies, and
  // defuddle crashes are unlikely to improve and would just burn a session.
  if (rawFailure.code !== "content_too_short") throw rawFailure;

  const browser = getBrowserBinding(env);
  if (!browser) {
    logger.info("extract: browser rendering not configured, skipping fallback", {
      url,
    });
    throw rawFailure;
  }

  logger.info("extract: falling back to browser rendering", { url });
  let renderedHtml: string;
  try {
    renderedHtml = await renderHtmlWithBrowser(browser, url);
  } catch (e) {
    const message =
      e instanceof BrowserRenderingError || e instanceof Error
        ? e.message
        : String(e);
    throw new ExtractionFailure(
      "browser_render_failed",
      `after content_too_short on raw HTML: ${message}`
    );
  }

  try {
    return {
      result: extractAndValidate(url, renderedHtml),
      renderedWith: "browser",
    };
  } catch (e) {
    if (e instanceof ExtractionFailure) {
      throw new ExtractionFailure(
        e.code,
        `via browser rendering: ${e.message}`
      );
    }
    throw e;
  }
}

async function runOne(
  env: Bindings,
  message: ExtractMessage,
  logger: ReturnType<typeof createLogger>
): Promise<void> {
  const { id, url, urlHash } = message;
  const db = createDb(env);
  try {
    // Atomically claim the job: bump attempts and flip pending/failed -> extracting.
    // If the row is already in flight or completed, leave it alone — duplicate
    // messages are normal in queue land.
    const claim = await db
      .updateTable("extracted_url")
      .set({
        status: "extracting",
        attempts: sql`attempts + 1`,
        last_attempt_at: sql`now()`,
      })
      .where("id", "=", String(id))
      .where("status", "in", ["pending", "failed"])
      .returning(["id"])
      .executeTakeFirst();
    if (!claim) {
      logger.info("extract: skipping non-claimable row", { id, url_hash: urlHash });
      return;
    }

    const { result, renderedWith } = await extractWithFallback(env, url, logger);

    const r2Key = `${urlHash}.md`;
    const bodyBytes = new TextEncoder().encode(result.md);
    await env.ARTICLES_BUCKET.put(r2Key, bodyBytes, {
      httpMetadata: { contentType: "text/markdown; charset=utf-8" },
      customMetadata: { url, extractorVersion: "1", renderedWith },
    });

    await db
      .updateTable("extracted_url")
      .set({
        status: "completed",
        r2_key: r2Key,
        title: result.title || null,
        author: result.author || null,
        description: result.description || null,
        byte_size: bodyBytes.byteLength,
        error_code: null,
        error_message: null,
        extracted_at: sql`now()`,
      })
      .where("id", "=", String(id))
      .execute();
  } catch (error) {
    const code: FailCode =
      error instanceof ExtractionFailure ? error.code : "parse_error";
    const terminalStatus: TerminalStatus =
      error instanceof ExtractionFailure ? error.terminalStatus : "failed";
    const message = error instanceof Error ? error.message : String(error);
    try {
      await db
        .updateTable("extracted_url")
        .set({
          status: terminalStatus,
          error_code: code,
          error_message: message.slice(0, 1000),
          // Auth-restricted outcomes are terminal — stamp extracted_at so
          // callers can treat them like any other completed row.
          ...(terminalStatus !== "failed"
            ? { extracted_at: sql`now()` }
            : {}),
        })
        .where("id", "=", String(id))
        .execute();
    } catch (dbError) {
      logger.error("extract: failed to record failure", dbError as Error, {
        id,
        url_hash: urlHash,
        code,
      });
    }
    // Re-throw so the batch handler can decide whether to capture to PostHog
    // (only unexpected errors — soft extraction failures are expected).
    if (!(error instanceof ExtractionFailure)) throw error;
  } finally {
    await db.destroy();
  }
}

export async function processExtractions(
  batch: MessageBatch<ExtractMessage>,
  env: Bindings,
  _ctx: ExecutionContext,
  postHog: PostHog
): Promise<void> {
  const logger = createLogger({
    queue: batch.queue,
    batch_size: batch.messages.length,
  });

  const handle = async (msg: Message<ExtractMessage>) => {
    try {
      await runOne(env, msg.body, logger);
      msg.ack();
    } catch (error) {
      logger.error("extract: unexpected error", error as Error, {
        id: msg.body.id,
        url_hash: msg.body.urlHash,
      });
      postHog.captureException(error as Error, undefined, {
        queue: batch.queue,
        id: msg.body.id,
        url_hash: msg.body.urlHash,
      });
      // The row's already been marked failed by runOne; ack so we don't
      // retry the same broken URL indefinitely. v1 has no auto-retry.
      msg.ack();
    }
  };

  await Promise.allSettled(batch.messages.map(handle));
}
