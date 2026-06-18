import { Hono } from "hono";
import { z } from "zod";

import type { Bindings } from "../env";
import { captureServerError } from "../utils/error-capture";
import { createLogger } from "@plotday/worker-util";
import { handleValidationError } from "../utils/validation";
import { checkAiLimit, isAiEnabled, recordAiUsage } from "../utils/ai-limits";
import { cleanTitle } from "../twist/tools/plot/thread";
import { titleFromContent } from "../twist/tools/plot/thread-helpers";
import { loadBuiltinProviderConfig, summarizeWithProvider } from "../utils/ai-provider";

const summary = new Hono<{ Bindings: Bindings }>();

// Schemas
const SummaryRequestSchema = z.object({
  body: z.string(),
});

// POST /summary - Generate AI summary
summary.post("/summary", async (c) => {
  try {
    const rawBody = await c.req.json();
    const parseResult = SummaryRequestSchema.safeParse(rawBody);
    if (!parseResult.success) {
      return handleValidationError(parseResult.error);
    }
    const body = parseResult.data;

    // Gate on both the free-tier AI limit and the user's built-in-AI opt-out.
    // When either blocks, fall back to a non-AI title derived from the content.
    const [aiAllowed, aiOn] = await Promise.all([
      checkAiLimit(c.env, c.var.db, c.var.user.id, "note_processing"),
      isAiEnabled(c.var.db, c.var.user.id),
    ]);
    if (!aiAllowed.allowed || !aiOn) {
      return c.json({ title: titleFromContent(body.body) ?? cleanTitle(body.body).slice(0, 60) });
    }

    // Check if user has a custom builtin AI provider configured
    const providerConfig = await loadBuiltinProviderConfig(c.var.db, c.var.user.id, c.env);

    let result;
    if (providerConfig) {
      result = await summarizeWithProvider(providerConfig, body.body);
      if (result) {
        recordAiUsage(c.env, c.var.user.id, "note_processing");
        return c.json({ title: result });
      }
      // Fall through to default if provider call failed to produce a result
    }

    const defaultResult = await summarize(c.env.AI, body.body);
    recordAiUsage(c.env, c.var.user.id, "note_processing");
    return c.json(defaultResult);
  } catch (error) {
    return captureServerError(c, error, "Error processing request.");
  }
});

export async function summarize(ai: Ai, body: string) {
  body = body.trim().slice(0, 2000);
  if (body.length === 0) {
    return {
      title: "Empty",
    };
  }
  if (body.length < 40) {
    return {
      title: cleanTitle(body),
    };
  }
  try {
    const messages = [
      {
        role: "system",
        content:
          "You name items in a productivity app. Create a short title for the user-provided action or note. Do not wrap the title in quotes. Respond only with the title.",
      },
      {
        role: "user",
        content: body,
      },
    ];
    const response = await ai.run("@cf/meta/llama-3.3-70b-instruct-fp8-fast", {
      messages,
      max_tokens: 64,
    });
    if (response instanceof ReadableStream) {
      throw new Error("Response is a stream");
    }
    const responseText =
      typeof response === "string"
        ? response
        : "response" in response
          ? response.response
          : undefined;
    const json = {
      title: responseText?.replace(/^"(.*)"$/, "$1")?.trim() || (titleFromContent(body) ?? cleanTitle(body).slice(0, 60)),
    };
    return json;
  } catch (e) {
    const logger = createLogger();
    logger.error("Error summarizing text", e as Error);

    throw e;
  }
}

export default summary;
