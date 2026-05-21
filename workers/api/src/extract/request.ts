import { sql, type Selectable } from "kysely";

import type { ExtractedUrl } from "../db-types";
import type { Bindings } from "../env";

import { withDb } from "../db";
import { classifyUrlAccess } from "./access";
import { hashUrl, normalizeUrl } from "./normalize";

type ExtractedUrlRow = Selectable<ExtractedUrl>;

/**
 * The `extracted_url` row shape returned to callers. Mirrors the table
 * (db-types `ExtractedUrl` with `Generated<T>` resolved to plain T) but
 * uses ISO date strings for timestamps so the result is JSON-friendly.
 */
export type ExtractedUrlRecord = {
  id: number;
  url_hash: string;
  url: string;
  status:
    | "pending"
    | "extracting"
    | "completed"
    | "failed"
    | "auth_required"
    | "paywalled";
  extractor_version: number;
  r2_key: string | null;
  title: string | null;
  author: string | null;
  description: string | null;
  byte_size: number | null;
  error_code: string | null;
  error_message: string | null;
  attempts: number;
  last_attempt_at: Date | null;
  extracted_at: Date | null;
  created_at: Date;
  updated_at: Date;
};

function asRecord(row: ExtractedUrlRow): ExtractedUrlRecord {
  return row as unknown as ExtractedUrlRecord;
}

/**
 * Internal entry point for the article-extraction pipeline. Normalizes the
 * URL, looks up (or creates) the `extracted_url` row, and — for new rows —
 * enqueues a job for the worker that does the actual fetch + defuddle.
 *
 * Existing rows are returned as-is. For v1 we never auto-requeue failed
 * rows; explicit retry comes when we wire up the API/UI surface.
 *
 * Safe to call concurrently for the same URL: the unique index on
 * `url_hash` collapses races and the loser re-reads the winner's row.
 */
export async function requestExtraction(
  env: Bindings,
  rawUrl: string
): Promise<ExtractedUrlRecord> {
  const url = normalizeUrl(rawUrl);
  const urlHash = await hashUrl(url);

  // Skip the fetch+defuddle pipeline entirely for URLs we know are gated.
  // The row still lands in the DB so callers can surface "this is a Jira
  // ticket" / "this is paywalled" in the UI; we just never spend a fetch
  // (or a Browser Rendering session) on it.
  const access = classifyUrlAccess(url);

  return withDb(env, async (db) => {
    const existing = await db
      .selectFrom("extracted_url")
      .selectAll()
      .where("url_hash", "=", urlHash)
      .executeTakeFirst();
    if (existing) return asRecord(existing);

    // ON CONFLICT covers the race where two concurrent callers both miss the
    // SELECT above; the loser falls through to the post-insert SELECT.
    const inserted = await db
      .insertInto("extracted_url")
      .values(
        access
          ? {
              url,
              url_hash: urlHash,
              status: access,
              error_code: "classified_by_url",
              extracted_at: sql`now()`,
            }
          : { url, url_hash: urlHash, status: "pending" }
      )
      .onConflict((oc) => oc.column("url_hash").doNothing())
      .returningAll()
      .executeTakeFirst();

    if (!inserted) {
      const row = await db
        .selectFrom("extracted_url")
        .selectAll()
        .where("url_hash", "=", urlHash)
        .executeTakeFirstOrThrow();
      return asRecord(row);
    }

    if (!access) {
      await env.EXTRACT_QUEUE.send({
        type: "extract",
        id: Number(inserted.id),
        url: inserted.url,
        urlHash: inserted.url_hash,
      });
    }

    return asRecord(inserted);
  });
}
