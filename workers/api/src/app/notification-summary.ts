import { Hono } from "hono";
import { z } from "zod";
import { PostHog } from "posthog-node";

import type { Bindings } from "../env";
import { captureServerError } from "../utils/error-capture";
import { createLogger } from "@plotday/worker-util";
import { handleValidationError } from "../utils/validation";
import { checkAiLimit, recordAiUsage } from "../utils/ai-limits";

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

    // Check free-tier AI limit
    const aiAllowed = await checkAiLimit(c.env, c.var.db, c.var.user.id, "note_processing");

    const summaries = await Promise.all(
      batches.map(async (batch) => {
        const displayPriorityTitle = batch.priority_title === "Everything" ? "Inbox" : batch.priority_title;
        const body = aiAllowed.allowed
          ? await generateSummary(c.env, batch.threads, user_name, displayPriorityTitle, c.var.user.id)
          : fallbackSummary(batch.threads);
        return {
          first_level_priority_id: batch.first_level_priority_id,
          title: displayPriorityTitle ?? "Updates",
          body,
          target_priority_id: batch.target_priority_id,
          thread_ids: batch.threads.map((t) => t.id),
        };
      })
    );

    if (aiAllowed.allowed) {
      recordAiUsage(c.env, c.var.user.id, "note_processing");
    }

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

    const text = typeof response === "string" ? response : response.response;
    return text?.replace(/^"(.*)"$/, "$1")?.trim() || fallbackSummary(threads);
  } catch (e) {
    const logger = createLogger();
    logger.error("Error generating notification summary", e as Error);
    const postHog = new PostHog(env.POSTHOG_API_KEY, { host: env.POSTHOG_HOST, flushAt: 1, flushInterval: 0 });
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
