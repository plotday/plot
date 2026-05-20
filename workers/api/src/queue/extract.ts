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
  | "parse_error";

class ExtractionFailure extends Error {
  constructor(readonly code: FailCode, message: string) {
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

    let html: string;
    try {
      const res = await fetch(url, {
        headers: { "User-Agent": USER_AGENT, Accept: "text/html,*/*" },
        redirect: "follow",
      });
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
      html = read.html;
    } catch (e) {
      if (e instanceof ExtractionFailure) throw e;
      throw new ExtractionFailure(
        "fetch_failed",
        e instanceof Error ? e.message : String(e)
      );
    }

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

    const r2Key = `${urlHash}.md`;
    const bodyBytes = new TextEncoder().encode(result.md);
    await env.ARTICLES_BUCKET.put(r2Key, bodyBytes, {
      httpMetadata: { contentType: "text/markdown; charset=utf-8" },
      customMetadata: { url, extractorVersion: "1" },
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
    const message = error instanceof Error ? error.message : String(error);
    try {
      await db
        .updateTable("extracted_url")
        .set({
          status: "failed",
          error_code: code,
          error_message: message.slice(0, 1000),
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
