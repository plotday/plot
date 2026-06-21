import { PostHog } from "posthog-node";
import { type Kysely, sql } from "kysely";

import type { DB } from "../../db";
import type { Bindings } from "../../env";

export const MIN_ENGAGEMENT_HISTORY = 3;
const ENGAGEMENT_WINDOW_DAYS = 120;

export type EngagementCounts = {
  priorThreads: number;
  readCount: number;
  archivedUnreadCount: number;
  replyCount: number;
};

export type SenderEngagement = {
  priorThreads: number;
  readRate: number | null;
  archivedUnreadRate: number | null;
  replyRate: number | null;
};

/** Pure: derive rates from raw counts. Rates are null until history is stable. */
export function computeEngagement(c: EngagementCounts): SenderEngagement {
  if (c.priorThreads < MIN_ENGAGEMENT_HISTORY) {
    return {
      priorThreads: c.priorThreads,
      readRate: null,
      archivedUnreadRate: null,
      replyRate: null,
    };
  }
  return {
    priorThreads: c.priorThreads,
    readRate: c.readCount / c.priorThreads,
    archivedUnreadRate: c.archivedUnreadCount / c.priorThreads,
    replyRate: c.replyCount / c.priorThreads,
  };
}

const ZERO_HISTORY: SenderEngagement = {
  priorThreads: 0,
  readRate: null,
  archivedUnreadRate: null,
  replyRate: null,
};

/**
 * How the recipient has historically treated mail from this sender. Best-effort
 * enrichment for the importance prompt: on any failure we degrade to
 * zero-history (the LLM then treats the sender as unknown) and capture only
 * unexpected errors. Optional `cache` memoizes per (recipient, sender) so a
 * batch of notes from the same sender issues the aggregate once.
 */
export async function getSenderEngagement(
  db: Kysely<DB>,
  recipientUserId: string,
  senderContactId: string,
  currentThreadId: string,
  env: Bindings,
  cache?: Map<string, Promise<SenderEngagement>>,
): Promise<SenderEngagement> {
  const key = `${recipientUserId}:${senderContactId}`;
  const cached = cache?.get(key);
  if (cached) return cached;

  const pending = (async (): Promise<SenderEngagement> => {
    try {
      const result = await sql<EngagementCounts>`
        WITH prior AS (
          SELECT
            (ts.read_at IS NOT NULL) AS was_read,
            (ts.read_at IS NULL AND tp.archived_at IS NOT NULL) AS archived_unread,
            EXISTS (
              SELECT 1 FROM note n
              WHERE n.thread_id = t.id
                AND n.draft = FALSE
                AND n.author_id = ANY("user".user_contact_ids(${recipientUserId}::uuid))
            ) AS replied
          FROM thread t
          JOIN thread_state ts
            ON ts.thread_id = t.id AND ts.user_id = ${recipientUserId}::uuid
          LEFT JOIN thread_priority tp
            ON tp.thread_id = t.id AND tp.user_id = ${recipientUserId}::uuid
          WHERE t.author_id = ${senderContactId}::uuid
            AND t.id <> ${currentThreadId}::uuid
            AND t.created_at > now() - make_interval(days => ${ENGAGEMENT_WINDOW_DAYS})
        )
        SELECT
          count(*)::int AS "priorThreads",
          count(*) FILTER (WHERE was_read)::int AS "readCount",
          count(*) FILTER (WHERE archived_unread)::int AS "archivedUnreadCount",
          count(*) FILTER (WHERE replied)::int AS "replyCount"
        FROM prior
      `.execute(db);

      const row = result.rows[0];
      if (!row) return ZERO_HISTORY;
      return computeEngagement(row);
    } catch (error) {
      // Best-effort: degrade silently to zero-history, but flag unexpected
      // failures so a broken query/permission doesn't disappear.
      const postHog = new PostHog(env.POSTHOG_API_KEY, {
        host: env.POSTHOG_HOST,
        flushAt: 1,
        flushInterval: 0,
      });
      postHog.captureException(error as Error, recipientUserId, {
        context: "importance:getSenderEngagement",
        sender_contact_id: senderContactId,
      });
      await postHog.shutdown();
      return ZERO_HISTORY;
    }
  })();

  cache?.set(key, pending);
  return pending;
}
