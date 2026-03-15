import { Hono } from "hono";
import { z } from "zod";

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
});

const BatchSchema = z.object({
  first_level_priority_id: z.string(),
  priority_title: z.string().nullable(),
  target_priority_id: z.string(),
  threads: z.array(ThreadSchema).min(1).max(10),
});

const RequestSchema = z.object({
  batches: z.array(BatchSchema).min(1).max(20),
});

// POST /notification-summary - Generate AI summaries for notification batches
notificationSummary.post("/notification-summary", async (c) => {
  try {
    const rawBody = await c.req.json();
    const parseResult = RequestSchema.safeParse(rawBody);
    if (!parseResult.success) {
      return handleValidationError(parseResult.error);
    }

    const { batches } = parseResult.data;

    // Check free-tier AI limit
    const aiAllowed = await checkAiLimit(c.env, c.var.db, c.var.user.id, "note_processing");

    const summaries = await Promise.all(
      batches.map(async (batch) => {
        const body = aiAllowed.allowed
          ? await generateSummary(c.env.AI, batch.threads)
          : fallbackSummary(batch.threads);
        return {
          first_level_priority_id: batch.first_level_priority_id,
          title: batch.priority_title ?? "Updates",
          body,
          target_priority_id: batch.target_priority_id,
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

async function generateSummary(
  ai: Ai,
  threads: z.infer<typeof ThreadSchema>[]
): Promise<string> {
  // For a single thread with a title, just use it directly
  if (threads.length === 1 && threads[0].title) {
    return threads[0].title;
  }

  // Build a simple description of the updates
  const descriptions = threads
    .slice(0, 5)
    .map((t) => {
      const title = t.title || "Untitled";
      const preview = t.preview ? `: ${t.preview.slice(0, 100)}` : "";
      return `- ${title}${preview}`;
    })
    .join("\n");

  const threadCount = threads.length;

  try {
    const messages = [
      {
        role: "system",
        content:
          "You write push notification bodies for a productivity app. " +
          "Given a list of unread updates, create 1-2 short sentences summarizing " +
          "the top 1-2 updates by importance. Be concise and informative. " +
          "Do not use markdown. Do not wrap the summary in quotes. Respond only with the summary text.",
      },
      {
        role: "user",
        content: `${threadCount} unread update${threadCount > 1 ? "s" : ""}:\n${descriptions}`,
      },
    ];

    const response = await ai.run(
      "@cf/meta/llama-3.1-8b-instruct-fp8",
      { messages, max_tokens: 128 }
    );

    if (response instanceof ReadableStream) {
      throw new Error("Response is a stream");
    }

    return response.response?.replace(/^"(.*)"$/, "$1")?.trim() || fallbackSummary(threads);
  } catch (e) {
    const logger = createLogger();
    logger.error("Error generating notification summary", e as Error);
    return fallbackSummary(threads);
  }
}

function fallbackSummary(threads: z.infer<typeof ThreadSchema>[]): string {
  if (threads.length === 1) {
    return threads[0].title || "1 new update";
  }
  const top = threads[0].title;
  if (top) {
    return `${top} and ${threads.length - 1} more update${threads.length > 2 ? "s" : ""}`;
  }
  return `${threads.length} new updates`;
}

export default notificationSummary;
