import type { Note } from "@plotday/twister/plot";

import { createLogger } from "@plotday/worker-util";
import { createNote } from "./thread";
import type { Plot } from "./index";

const MENU_INTENT = `Describe what this twist can do. Example: "What can you do?"`;
const REMOVE_INTENT = `Disable and remove this twist. Example: "Remove yourself."`;

/**
 * Matches a note's content against registered intents using AI.
 * Returns the best matching intent key or null if no good match.
 */
export async function matchIntent(
  plot: Plot,
  note: Note
): Promise<string | null> {
  // Skip intent matching when AI is disabled
  if (!(await plot.isAiEnabled())) {
    return null;
  }

  // Collect all intent descriptions (custom + built-in)
  const customIntents = plot.plotOptions?.note?.intents || [];
  const builtInIntentObjects = [
    { description: MENU_INTENT, examples: [] },
    { description: REMOVE_INTENT, examples: [] },
  ];
  const allIntents = [...customIntents, ...builtInIntentObjects];

  if (allIntents.length === 0) {
    return null;
  }

  // Prepare note content for matching
  const content = note.content;

  if (!content?.trim()) {
    return null;
  }

  // Format intents with description and examples
  const formatIntent = (
    intent: { description: string; examples: string[] },
    index: number
  ): string => {
    const formatted = [`${index + 1}. ${intent.description}`];
    if (intent.examples.length > 0) {
      formatted.push(`   Examples: ${intent.examples.join("; ")}`);
    }
    return formatted.join("\n");
  };

  // Use AI to match intent
  const prompt = `Available intents:
${allIntents.map((intent, i) => formatIntent(intent, i)).join("\n")}

Note:
${content}`;

  try {
    const response = await plot.ai.prompt({
      model: {
        speed: "fast",
        cost: "medium",
      },
      system: `You are a helpful intent classifier. 
Select the best matching intent from the list below, or respond with "none" if no intent matches well.
Given similar intents, prefer ones earlier in the list.
Consider both the intent description and example phrases when matching.
Respond only with the intent number (e.g., "1", "2", etc.) or "none".`,
      prompt,
    });

    const responseText = response.text.trim().toLowerCase();

    // Check if the response is "none"
    if (responseText === "none") {
      return null;
    }

    // Parse the number and validate it
    const intentNumber = parseInt(responseText, 10);
    if (
      isNaN(intentNumber) ||
      intentNumber < 1 ||
      intentNumber > allIntents.length
    ) {
      const logger = createLogger({ priority_twist_id: plot.priorityTwistId });
      logger.warn("Invalid intent number", { response_text: responseText });
      return null;
    }

    const matchedIntent = allIntents[intentNumber - 1];
    return matchedIntent.description;
  } catch (error) {
    const logger = createLogger({ priority_twist_id: plot.priorityTwistId });
    logger.error("Intent matching error", error as Error);
    return null;
  }
}

/**
 * Handles a note intent by dispatching to the appropriate handler.
 * If no intent matches, creates a reply note with a helpful message.
 * Returns info about which callback to invoke in the twist worker, or null if handled here.
 */
export async function handleIntent(
  plot: Plot,
  note: Note
): Promise<{ optionPath: string[]; args: any[] } | null> {
  const matchedIntent = await matchIntent(plot, note);

  const logger = createLogger({ priority_twist_id: plot.priorityTwistId });
  logger.info("Intent matching for note", {
    note_id: note.id,
    matched: matchedIntent ?? "none",
  });

  if (!matchedIntent) {
    // No intent matched - create a reply note
    await createNote(plot, {
      thread: { id: note.thread.id },
      content:
        "I didn't recognize what you're asking for. Try asking me 'What can you do?' to see what I can help with.",
    });
    return null;
  }

  // Handle built-in intents
  if (matchedIntent === MENU_INTENT) {
    await handleDescribeCapabilities(plot, note);
    return null;
  }

  if (matchedIntent === REMOVE_INTENT) {
    await handleRemoveTwist(plot, note);
    return null;
  }

  // Return path to custom intent handler to be called in twist worker
  const intents = plot.plotOptions?.note?.intents || [];
  const intentIndex = intents.findIndex(
    (intent: any) => intent.description === matchedIntent
  );

  if (intentIndex !== -1) {
    const intentHandler = intents[intentIndex];
    if (intentHandler && typeof intentHandler.handler === "function") {
      return {
        optionPath: ["note", "intents", intentIndex.toString(), "handler"],
        args: [note],
      };
    }
  }

  return null;
}

/**
 * Handles the "What can you do?" built-in intent.
 * Uses AI to generate a natural language summary of the twist's capabilities.
 */
async function handleDescribeCapabilities(
  plot: Plot,
  note: Note
): Promise<void> {
  const customIntents = plot.plotOptions?.note?.intents || [];

  let description: string;
  if (customIntents.length === 0) {
    description =
      "I can help with general tasks. Mention me in a note to get started!";
  } else {
    // Use AI to generate a natural summary
    const prompt = `Given these capabilities:
${customIntents
  .map((intent: any, i: number) => `${i + 1}. ${intent.description}`)
  .join("\n")}

Write a brief, friendly paragraph (2-3 sentences) describing what this twist can help with. Use "I" language.`;

    try {
      const response = await plot.ai.prompt({
        model: {
          speed: "fast",
          cost: "low",
        },
        system:
          "You are a helpful twist describing your capabilities in a friendly, concise way.",
        prompt,
      });

      description = response.text.trim();
    } catch (error) {
      const logger = createLogger({ priority_twist_id: plot.priorityTwistId });
      logger.error("Error generating capability description", error as Error);
      description = `I can help with: ${customIntents
        .map((i) => i.description)
        .join(", ")}`;
    }
  }

  // Create reply note with the description
  await createNote(plot, {
    thread: { id: note.thread.id },
    content: description,
  });
}

/**
 * Handles the "Remove yourself" built-in intent.
 * Soft-deletes the priority_twist by setting archived_at.
 */
async function handleRemoveTwist(plot: Plot, note: Note): Promise<void> {
  try {
    // Set archived_at on the priority_twist record
    await plot.db
      .updateTable("priority_twist")
      .set({ archived_at: new Date().toISOString() })
      .where("id", "=", plot.priorityTwistId)
      .execute();

    // Create farewell note
    await createNote(plot, {
      thread: { id: note.thread.id },
      content:
        "I've been removed from this priority. You can add me back anytime if you need me!",
    });
  } catch (error) {
    const logger = createLogger({ priority_twist_id: plot.priorityTwistId });
    logger.error("Error removing twist", error as Error);

    // Create error note
    await createNote(plot, {
      thread: { id: note.thread.id },
      content: `There was an error removing me: ${
        error instanceof Error ? error.message : "Unknown error"
      }`,
    });
  }
}
