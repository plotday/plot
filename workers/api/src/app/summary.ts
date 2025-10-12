import { Hono } from "hono";
import { z } from "zod";

import type { Bindings } from "../env";
import { handleValidationError } from "../utils/validation";

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
    return c.json(await summarize(c.env.AI, body.body));
  } catch (error) {
    console.error("Error processing summary request:", error);
    return c.json({ error: "Error processing request." }, 500);
  }
});

async function summarize(ai: Ai, body: string) {
  body = body.trim();
  if (body.length === 0) {
    return {
      title: "Empty",
    };
  }
  if (body.length < 40) {
    return {
      // TODO remove Markdown formatting
      title: body.replaceAll(/\s+/g, " ").trim(),
    };
  }
  try {
    const messages = [
      {
        role: "system",
        content:
          "You name items in a productivity app. Create a short title for the user-provided action or note. Respond only with the title.",
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
    const json = {
      title: response.response,
    };
    return json;
  } catch (e) {
    console.error("Error summarizing text:", e);

    throw e;
  }
}

export default summary;
