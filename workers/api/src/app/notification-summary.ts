import { Hono } from "hono";
import { z } from "zod";
import { PostHog } from "posthog-node";
import { sql, type Kysely } from "kysely";

import type { Bindings } from "../env";
import type { DB } from "../db";
import { captureServerError } from "../utils/error-capture";
import { createLogger, exceptionFingerprintBeforeSend } from "@plotday/worker-util";
import { handleValidationError } from "../utils/validation";
import { checkAiLimit, isAiEnabled, recordAiUsage } from "../utils/ai-limits";
import {
  loadNotificationAuthors,
  selectUnsuppressedThreadIds,
  stampThreadsNotified,
} from "../state/notify-candidates";

const notificationSummary = new Hono<{ Bindings: Bindings }>();

const ThreadSchema = z.object({
  id: z.string(),
  title: z.string().nullable(),
  preview: z.string().nullable(),
  has_been_read: z.boolean().optional(),
  original_author_name: z.string().nullable().optional(),
  unread_author_names: z.string().nullable().optional(),
});

export function formatSingleThreadNotification(
  title: string,
  hasBeenRead?: boolean,
  originalAuthorName?: string | null,
  unreadAuthorNames?: string | null
): string {
  if (hasBeenRead) {
    if (unreadAuthorNames) {
      const names = unreadAuthorNames.split(",").map((n) => n.trim()).filter(Boolean);
      if (names.length === 1) {
        return `${names[0]} replied to: ${title}`;
      } else if (names.length === 2) {
        return `${names[0]} and ${names[1]} replied to: ${title}`;
      } else if (names.length > 2) {
        return `${names[0]}, ${names[1]}, and more replied to: ${title}`;
      }
    }
    return `New reply to: ${title}`;
  } else {
    const author = originalAuthorName || unreadAuthorNames;
    if (author) {
      const names = author.split(",").map((n) => n.trim()).filter(Boolean);
      if (names.length > 0) {
        return `${names[0]}: ${title}`;
      }
    }
    return title;
  }
}

/** Split a comma-joined author-name string into trimmed, non-empty names. */
function splitAuthorNames(s?: string | null): string[] {
  return (s ?? "")
    .split(",")
    .map((name) => name.trim())
    .filter(Boolean);
}

/** Join author names for a heading: "A", "A & B", or "A, B & more". */
function joinAuthorNames(names: string[]): string | null {
  if (names.length === 0) return null;
  if (names.length === 1) return names[0];
  if (names.length === 2) return `${names[0]} & ${names[1]}`;
  return `${names[0]}, ${names[1]} & more`;
}

/**
 * Lay out a single-thread PUSH notification: lead with the author (the heading)
 * and use the thread title as the body. The most important information for a
 * thread is who it's from and what it's about; the connection is omitted.
 *
 * For a new thread the heading is the originator; for a new reply to a thread
 * the user already read, it's the replier(s) — so a reply from Stacy on Phil's
 * thread shows "Stacy", not "Phil". When no human author is resolvable (e.g.
 * automated mail), the title leads instead.
 */
export function singleThreadPushNotification(thread: {
  title: string | null;
  preview?: string | null;
  has_been_read?: boolean;
  original_author_name?: string | null;
  unread_author_names?: string | null;
}): { title: string; body: string } {
  const threadTitle = thread.title?.trim() || null;
  const preview = thread.preview?.trim() || null;
  const repliers = joinAuthorNames(splitAuthorNames(thread.unread_author_names));

  const heading = thread.has_been_read
    ? repliers
    : splitAuthorNames(thread.original_author_name)[0] ?? repliers;

  if (heading) {
    return { title: heading, body: threadTitle ?? preview ?? "New message" };
  }
  // No human author — lead with the title (or preview for title-less items).
  return {
    title: threadTitle ?? preview ?? "New message",
    body: threadTitle ? preview ?? "" : "",
  };
}

/**
 * Build the "Role › Focus" label shown in a notification's header (Android
 * subText / iOS subtitle) so the user can tell which focus an update belongs to.
 *
 * The role is prepended only when the user has more than one role — mirroring
 * the Flutter `FocusLabel` rule (`roles.length >= 2`) and using the same ` › `
 * separator (`Priority.separator`). A role-less focus (e.g. FYI) shows the focus
 * alone. The root focus title "Everything" is normalized to "Inbox" to match
 * `Priority.displayTitle`. Returns null when there is no focus title to show, so
 * callers can omit the subtext entirely.
 */
export function buildFocusLabel(
  focusTitle: string | null,
  roleName: string | null,
  roleCount: number
): string | null {
  const focus = focusTitle?.trim();
  if (!focus) return null;
  const normalizedFocus = focus === "Everything" ? "Inbox" : focus;
  const role = roleName?.trim();
  if (roleCount > 1 && role) {
    return `${role} › ${normalizedFocus}`;
  }
  return normalizedFocus;
}

/**
 * Resolve, for a set of focus (first-level priority) ids, the owning role's
 * name, plus how many non-archived roles the user has. Feeds {@link
 * buildFocusLabel}: the role is only prefixed when the user has more than one
 * role, matching the Flutter `FocusLabel` rule.
 */
export async function loadFocusRoles(
  db: Kysely<DB>,
  userId: string,
  focusIds: string[]
): Promise<{
  roleNameByFocusId: Map<string, string | null>;
  roleCount: number;
}> {
  const roleNameByFocusId = new Map<string, string | null>();
  if (focusIds.length > 0) {
    const rows = await sql<{ id: string; role_name: string | null }>`
      SELECT p.id::text AS id, r.name AS role_name
      FROM priority p
      LEFT JOIN role r ON r.id = p.role_id
      WHERE p.id::text = ANY(${focusIds})
    `.execute(db);
    for (const row of rows.rows) {
      roleNameByFocusId.set(row.id, row.role_name);
    }
  }
  const countResult = await sql<{ n: number }>`
    SELECT count(*)::int AS n
    FROM role
    WHERE user_id = ${userId}::uuid AND archived_at IS NULL
  `.execute(db);
  return { roleNameByFocusId, roleCount: countResult.rows[0]?.n ?? 0 };
}

const BatchSchema = z.object({
  first_level_priority_id: z.string(),
  priority_title: z.string().nullable(),
  target_priority_id: z.string(),
  threads: z.array(ThreadSchema).min(1).max(10),
});

const RequestSchema = z.object({
  batches: z.array(BatchSchema).min(1).max(20),
  user_name: z.string().nullable().optional(),
});

// POST /notification-summary - Generate AI summaries for notification batches
notificationSummary.post("/notification-summary", async (c) => {
  try {
    const rawBody = await c.req.json();
    const parseResult = RequestSchema.safeParse(rawBody);
    if (!parseResult.success) {
      return handleValidationError(parseResult.error);
    }

    const { batches, user_name } = parseResult.data;
    const userId = c.var.user.id;
    const db = c.var.db;

    // Per-thread re-notify suppression (mirrors /notification-content). The
    // foreground builds these batches from local data and gates only on the
    // per-focus watermark, which does not follow a thread across a focus move —
    // so a thread the user already saw and re-filed can reappear here. Drop any
    // thread already notified at its current content version before summarizing.
    const allThreadIds = [
      ...new Set(batches.flatMap((b) => b.threads.map((t) => t.id))),
    ];
    const eligible = await selectUnsuppressedThreadIds(db, userId, allThreadIds);

    const filteredBatches = batches
      .map((batch) => ({
        ...batch,
        threads: batch.threads.filter((t) => eligible.has(t.id)),
      }))
      .filter((batch) => batch.threads.length > 0);

    if (filteredBatches.length === 0) {
      return c.json({ summaries: [] });
    }

    // Gate on the free-tier AI limit AND the user's built-in-AI opt-out; either
    // one off ⇒ deterministic fallbackSummary, no model call.
    const [aiAllowed, aiOn] = await Promise.all([
      checkAiLimit(c.env, c.var.db, c.var.user.id, "note_processing"),
      isAiEnabled(c.var.db, userId),
    ]);
    const useAi = aiAllowed.allowed && aiOn;

    // The client builds batches from local data with no author context. Fill
    // in the same author fields /notification-content computes inline, so the
    // foreground push layout matches the background one (author as heading,
    // thread title as body for a single thread).
    const authorsByThread = await loadNotificationAuthors(
      db,
      userId,
      filteredBatches.flatMap((b) => b.threads.map((t) => t.id))
    );
    const enrich = (t: z.infer<typeof ThreadSchema>) => {
      const a = authorsByThread.get(t.id);
      return a ? { ...t, ...a } : t;
    };

    // Resolve the "Role › Focus" label for each batch so the notification can
    // show which focus an update belongs to (header subText / subtitle).
    const { roleNameByFocusId, roleCount } = await loadFocusRoles(
      db,
      userId,
      filteredBatches.map((b) => b.first_level_priority_id)
    );

    const summaries = await Promise.all(
      filteredBatches.map(async (batch) => {
        const focusTitle =
          batch.priority_title === "Everything" ? "Inbox" : batch.priority_title;
        const threads = batch.threads.map(enrich);

        // Single thread → author heading + title body (connection omitted).
        // Multiple → focus heading + summary of the threads.
        let title = focusTitle ?? "Updates";
        let body: string;
        if (threads.length === 1) {
          const single = singleThreadPushNotification(threads[0]);
          title = single.title;
          body = single.body;
        } else {
          body = useAi
            ? await generateSummary(c.env, threads, user_name, focusTitle, c.var.user.id)
            : fallbackSummary(threads);
        }

        return {
          first_level_priority_id: batch.first_level_priority_id,
          title,
          body,
          target_priority_id: batch.target_priority_id,
          thread_ids: threads.map((t) => t.id),
          focus_label: buildFocusLabel(
            batch.priority_title,
            roleNameByFocusId.get(batch.first_level_priority_id) ?? null,
            roleCount
          ),
        };
      })
    );

    if (useAi) {
      recordAiUsage(c.env, c.var.user.id, "note_processing");
    }

    // Record the per-thread high-water mark for the threads we're about to show
    // so they aren't re-announced later (including after a move to another
    // focus). Shared with /notification-content via thread_notify_state.
    await stampThreadsNotified(
      db,
      userId,
      filteredBatches.flatMap((b) => b.threads.map((t) => t.id))
    );

    return c.json({ summaries });
  } catch (error) {
    return captureServerError(c, error, "Error generating notification summary.");
  }
});

export async function generateSummary(
  env: Bindings,
  threads: z.infer<typeof ThreadSchema>[],
  userName?: string | null,
  priorityTitle?: string | null,
  userId?: string
): Promise<string> {
  const ai = env.AI;
  // For a single thread with a title, just use it directly
  if (threads.length === 1 && threads[0].title) {
    return formatSingleThreadNotification(
      threads[0].title,
      threads[0].has_been_read,
      threads[0].original_author_name,
      threads[0].unread_author_names
    );
  }

  // Build a simple description of the updates including author context for the LLM
  const descriptions = threads
    .slice(0, 5)
    .map((t) => {
      const title = t.title || "Untitled";
      const authorCtx = t.has_been_read
        ? (t.unread_author_names ? ` [unread replies from ${t.unread_author_names}]` : "")
        : (t.original_author_name || t.unread_author_names ? ` [by ${t.original_author_name || t.unread_author_names}]` : "");
      const preview = t.preview ? `: ${t.preview.slice(0, 100)}` : "";
      return `- ${title}${authorCtx}${preview}`;
    })
    .join("\n");

  const threadCount = threads.length;

  try {
    const priorityHint = priorityTitle
      ? ` These updates are from the '${priorityTitle}' area.`
      : "";

    const recipientHint = userName
      ? ` The recipient's name is '${userName}'. When their name appears in thread titles, refer to them as 'you' instead. For example, 'Email from ${userName}' should become 'You received an email'.`
      : "";

    const messages = [
      {
        role: "system" as const,
        content:
          "You write push notification bodies for a productivity app. " +
          "Given a list of unread items, write a 1-sentence summary of the most important one. " +
          "ONLY use words and facts that appear in the input. " +
          "Do NOT infer, invent, or add any details not explicitly stated. " +
          "Do NOT mention emails, calls, messages, or other communication types unless the input explicitly says so. " +
          "Just state the item title or a brief factual description. " +
          "No markdown, no quotes, no preamble." +
          priorityHint +
          recipientHint,
      },
      {
        role: "user" as const,
        content: `${threadCount} unread item${threadCount > 1 ? "s" : ""}:\n${descriptions}`,
      },
    ];

    const response = await ai.run(
      "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
      { messages, max_tokens: 128 }
    );

    if (response instanceof ReadableStream) {
      throw new Error("Response is a stream");
    }

    const text =
      typeof response === "string"
        ? response
        : "response" in response
          ? response.response
          : undefined;
    return text?.replace(/^"(.*)"$/, "$1")?.trim() || fallbackSummary(threads);
  } catch (e) {
    const logger = createLogger();
    logger.error("Error generating notification summary", e as Error);
    const postHog = new PostHog(env.POSTHOG_API_KEY, { host: env.POSTHOG_HOST, flushAt: 1, flushInterval: 0, before_send: exceptionFingerprintBeforeSend });
    postHog.captureException(e as Error, userId, { context: "notification-summary:generateSummary" });
    await postHog.shutdown();
    return fallbackSummary(threads);
  }
}

export function fallbackSummary(threads: z.infer<typeof ThreadSchema>[]): string {
  if (threads.length === 1) {
    return threads[0].title
      ? formatSingleThreadNotification(
          threads[0].title,
          threads[0].has_been_read,
          threads[0].original_author_name,
          threads[0].unread_author_names
        )
      : "1 new update";
  }
  const top = threads[0].title;
  if (top) {
    return `${top} and ${threads.length - 1} more update${threads.length > 2 ? "s" : ""}`;
  }
  return `${threads.length} new updates`;
}

export default notificationSummary;
