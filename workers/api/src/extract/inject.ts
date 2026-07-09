/**
 * Deliver extracted article Markdown as a Plot-authored note.
 *
 * Pairs the global, URL-keyed extraction cache (`extracted_url` + R2
 * `ARTICLES_BUCKET`) with the `extracted_url_injection` bookkeeping table so a
 * thread that references a public article link gets the article's Markdown
 * added as a note once extraction completes — even if that is after the thread
 * was created.
 */

import { createLogger } from "@plotday/worker-util";
import type { Kysely } from "kysely";

import type { DB } from "../db-types";
import type { Bindings } from "../env";
import { getPlotTwistInstanceId } from "../utils/trial";
import { requestExtraction } from "./request";
import { isPublicHttpUrl } from "./url-guard";

/** Max bytes of Markdown stored on a single injected note (synced to clients). */
export const MAX_ARTICLE_CONTENT_BYTES = 100_000;

/** Cap on how many article links per first note we act on. */
export const MAX_ARTICLE_URLS_PER_NOTE = 3;

/** Pull http(s) article URLs out of a note's `actions` jsonb. */
export function extractArticleUrlsFromActions(actions: unknown): string[] {
  if (!Array.isArray(actions)) return [];
  const urls: string[] = [];
  for (const action of actions) {
    if (
      action &&
      typeof action === "object" &&
      (action as { type?: unknown }).type === "external" &&
      typeof (action as { url?: unknown }).url === "string" &&
      /^https?:\/\//i.test((action as { url: string }).url)
    ) {
      urls.push((action as { url: string }).url);
    }
  }
  return urls;
}

/** Byte-cap Markdown so an injected note never syncs megabytes. */
export function capArticleContent(md: string): string {
  const bytes = new TextEncoder().encode(md);
  if (bytes.byteLength <= MAX_ARTICLE_CONTENT_BYTES) return md;
  const slice = new TextDecoder("utf-8", { fatal: false }).decode(
    bytes.slice(0, MAX_ARTICLE_CONTENT_BYTES)
  );
  return `${slice}\n\n… (truncated)`;
}

/** Record that `threadId` wants the article for `urlHash` once it's ready. */
export async function registerArticleInjection(
  db: Kysely<DB>,
  args: {
    urlHash: string;
    threadId: string;
    priorityId: string;
    requestedBy: string;
  }
): Promise<void> {
  await db
    .insertInto("extracted_url_injection")
    .values({
      url_hash: args.urlHash,
      thread_id: args.threadId,
      priority_id: args.priorityId,
      requested_by: args.requestedBy,
      status: "pending",
    })
    .onConflict((oc) => oc.columns(["thread_id", "url_hash"]).doNothing())
    .execute();
}

/**
 * Insert the extracted article Markdown as a note authored by the user's Plot
 * twist instance (so it renders as "Plot"). Idempotent via note.key; a NULL
 * link_id means the partial unique index can't ON CONFLICT, so we pre-check
 * (same as addTrialNote). Returns a 3-way result distinguishing "no note
 * created because there's no Plot author" from "already delivered" from
 * "created now" — callers need to know which, since only the first should
 * leave the injection row pending instead of marking it fulfilled.
 */
export async function insertArticleNote(
  db: Kysely<DB>,
  args: {
    threadId: string;
    priorityId: string;
    urlHash: string;
    markdown: string;
  }
): Promise<"inserted" | "exists" | "no_author"> {
  const plotTwistInstanceId = await getPlotTwistInstanceId(db, args.priorityId);
  if (!plotTwistInstanceId) return "no_author";

  const key = `article:${args.urlHash}`;
  const existing = await db
    .selectFrom("note")
    .select("id")
    .where("thread_id", "=", args.threadId)
    .where("key", "=", key)
    .where("link_id", "is", null)
    .executeTakeFirst();
  if (existing) return "exists";

  await db
    .insertInto("note")
    .values({
      thread_id: args.threadId,
      content: capArticleContent(args.markdown),
      created_by: plotTwistInstanceId,
      author_id: plotTwistInstanceId,
      key,
    })
    .execute();
  return "inserted";
}

const TERMINAL_FAILURE: ReadonlyArray<string> = [
  "failed",
  "auth_required",
  "paywalled",
];

/** Best-effort SYNC_NOTIFY poke so a freshly-inserted note appears live. */
async function pingSyncNotify(env: Bindings, priorityId: string): Promise<void> {
  try {
    const id = env.SYNC_NOTIFY.idFromName(priorityId);
    await env.SYNC_NOTIFY.get(id).fetch(
      new Request("http://do/notify", {
        method: "POST",
        body: JSON.stringify({ id: priorityId }),
      })
    );
  } catch (error) {
    createLogger({ operation: "pingSyncNotify" }).error(
      "Failed to notify sync for article note",
      error as Error
    );
  }
}

/**
 * Drain every thread waiting on `urlHash`. On `completed`, insert the article
 * note per thread and mark it fulfilled; on a terminal failure, mark waiting
 * rows skipped; otherwise no-op. Per-thread errors are logged and left pending
 * (the cron drain retries) so one bad thread never blocks the rest.
 */
export async function fulfillArticleInjection(
  env: Bindings,
  db: Kysely<DB>,
  urlHash: string
): Promise<void> {
  const logger = createLogger({ operation: "fulfillArticleInjection" });

  const record = await db
    .selectFrom("extracted_url")
    .select(["status", "r2_key"])
    .where("url_hash", "=", urlHash)
    .executeTakeFirst();
  if (!record) return;

  const pending = await db
    .selectFrom("extracted_url_injection")
    .select(["id", "thread_id", "priority_id"])
    .where("url_hash", "=", urlHash)
    .where("status", "=", "pending")
    .execute();
  if (pending.length === 0) return;

  if (TERMINAL_FAILURE.includes(record.status)) {
    await db
      .updateTable("extracted_url_injection")
      .set({ status: "skipped" })
      .where("url_hash", "=", urlHash)
      .where("status", "=", "pending")
      .execute();
    return;
  }

  if (record.status !== "completed") return; // still pending / extracting

  const object = await env.ARTICLES_BUCKET.get(record.r2_key ?? `${urlHash}.md`);
  if (!object) {
    // Completed but the blob is missing — leave pending for the cron to retry.
    logger.error("article blob missing for completed extraction", undefined, {
      url_hash: urlHash,
    });
    return;
  }
  const markdown = await object.text();

  for (const row of pending) {
    try {
      const result = await insertArticleNote(db, {
        threadId: row.thread_id,
        priorityId: row.priority_id,
        urlHash,
        markdown,
      });

      if (result === "no_author") {
        // No Plot twist instance to author the note yet — leave the row
        // pending so it self-heals once the instance appears, instead of
        // silently dropping the article.
        logger.error(
          "no Plot instance to author article note; leaving injection pending",
          undefined,
          {
            url_hash: urlHash,
            thread_id: row.thread_id,
            priority_id: row.priority_id,
          }
        );
        continue;
      }

      await db
        .updateTable("extracted_url_injection")
        .set({ status: "fulfilled" })
        .where("id", "=", row.id)
        .execute();
      if (result === "inserted") await pingSyncNotify(env, row.priority_id);
    } catch (error) {
      // Transient — leave this row pending; the cron drain will retry it.
      logger.error("failed to inject article note", error as Error, {
        url_hash: urlHash,
        thread_id: row.thread_id,
      });
    }
  }
}

/**
 * Cron safety-net: drain injection rows whose extraction has reached a terminal
 * status but were never fulfilled (e.g. a transient fulfillment failure). The
 * caller provides the DB connection (the cron wraps this in `withDb`).
 */
export async function drainPendingArticleInjections(
  env: Bindings,
  db: Kysely<DB>
): Promise<void> {
  const rows = await db
    .selectFrom("extracted_url_injection as i")
    .innerJoin("extracted_url as e", "e.url_hash", "i.url_hash")
    .select("i.url_hash")
    .distinct()
    .where("i.status", "=", "pending")
    .where("e.status", "in", [
      "completed",
      "failed",
      "auth_required",
      "paywalled",
    ])
    .limit(50)
    .execute();

  const logger = createLogger({ operation: "drainPendingArticleInjections" });
  for (const row of rows) {
    try {
      await fulfillArticleInjection(env, db, row.url_hash);
    } catch (error) {
      logger.error("drain fulfill failed", error as Error, {
        url_hash: row.url_hash,
      });
    }
  }
}

/**
 * For the FIRST note of a thread that carries public article links: request
 * extraction of each link, register durable delivery, and fulfill immediately
 * if the article is already cached. Terminal-failed URLs (auth/paywall/failed)
 * are silently skipped (no note, no row). Called from a `waitUntil` after
 * `upsert_note`, so it opens no request-scoped resources.
 */
export async function handleArticleLinksForNewNote(
  env: Bindings,
  db: Kysely<DB>,
  args: {
    noteId: string;
    threadId: string;
    priorityId: string;
    userId: string;
    actions: unknown;
  }
): Promise<void> {
  // Filter out non-public targets (SSRF) before feeding URLs to the fetch
  // pipeline; the same guard runs at the /app/extract endpoint.
  const urls = extractArticleUrlsFromActions(args.actions).filter(
    isPublicHttpUrl
  );
  if (urls.length === 0) return;

  // First note only: bail if the thread already has any other (non-archived) note.
  const earlier = await db
    .selectFrom("note")
    .select("id")
    .where("thread_id", "=", args.threadId)
    .where("id", "!=", args.noteId)
    .where("archived_at", "is", null)
    .limit(1)
    .executeTakeFirst();
  if (earlier) return;

  for (const url of urls.slice(0, MAX_ARTICLE_URLS_PER_NOTE)) {
    const record = await requestExtraction(env, url);
    if (TERMINAL_FAILURE.includes(record.status)) continue; // silent skip

    await registerArticleInjection(db, {
      urlHash: record.url_hash,
      threadId: args.threadId,
      priorityId: args.priorityId,
      requestedBy: args.userId,
    });
    // Fulfill now if already completed; this also closes the race where the
    // extraction finished between requestExtraction and the register above.
    // Otherwise the queue consumer / cron delivers on completion.
    await fulfillArticleInjection(env, db, record.url_hash);
  }
}
