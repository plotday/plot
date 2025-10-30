import { type Activity, ActivityType } from "@plotday/agent/plot";

import { createActivity } from "./activity";
import type { Plot } from "./index";

const MENU_INTENT = `Describe what this agent can do. Example: "What can you do?"`;
const REMOVE_INTENT = `Disable and remove this agent. Example: "Remove yourself."`;

/**
 * Matches an activity's content against registered intents using AI.
 * Returns the best matching intent key or null if no good match.
 */
export async function matchIntent(
  plot: Plot,
  activity: Activity
): Promise<string | null> {
  if (!plot.env) {
    console.warn("Cannot match intent without env bindings");
    return null;
  }

  // Collect all intent descriptions (custom + built-in)
  const customIntents = plot.plotOptions?.activity?.intents || [];
  const builtInIntentObjects = [
    { description: MENU_INTENT, examples: [] },
    { description: REMOVE_INTENT, examples: [] },
  ];
  const allIntents = [...customIntents, ...builtInIntentObjects];

  if (allIntents.length === 0) {
    return null;
  }

  // Prepare activity content for matching
  const content = [activity.title, activity.note].filter(Boolean).join(" - ");

  if (!content.trim()) {
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
  const prompt = `Given this activity: "${content}"

Select the best matching intent from the list below, or respond with "none" if no intent matches well.
Given similar intents, prefer ones earlier in the list.
Consider both the intent description and example phrases when matching.

Available intents:
${allIntents.map((intent, i) => formatIntent(intent, i)).join("\n")}

Respond with ONLY the intent number (e.g., "1", "2", etc.) or "none".`;

  try {
    const response = await plot.ai.prompt({
      model: {
        speed: "fast",
        cost: "medium",
      },
      system:
        "You are a helpful intent classifier. Respond only with the intent number or 'none'.",
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
      console.warn("Invalid intent number:", responseText);
      return null;
    }

    const matchedIntent = allIntents[intentNumber - 1];
    return matchedIntent.description;
  } catch (error) {
    console.error("Intent matching error:", error);
    return null;
  }
}

/**
 * Handles an activity intent by dispatching to the appropriate handler.
 * If no intent matches, creates a reply activity with a helpful message.
 * Returns info about which callback to invoke in the agent worker, or null if handled here.
 */
export async function handleIntent(
  plot: Plot,
  activity: Activity
): Promise<{ optionPath: string[]; args: any[] } | null> {
  const matchedIntent = await matchIntent(plot, activity);

  if (!matchedIntent) {
    // No intent matched - create a reply activity
    await createActivity(plot, {
      type: ActivityType.Note,
      title: "I'm not sure how to help with that",
      note: "I didn't recognize what you're asking for. Try asking me 'What can you do?' to see what I can help with.",
      parent: { id: activity.id },
    });
    return null;
  }

  // Handle built-in intents
  if (matchedIntent === MENU_INTENT) {
    await handleDescribeCapabilities(plot, activity);
    return null;
  }

  if (matchedIntent === REMOVE_INTENT) {
    await handleRemoveAgent(plot, activity);
    return null;
  }

  // Return path to custom intent handler to be called in agent worker
  const intents = plot.plotOptions?.activity?.intents || [];
  const intentIndex = intents.findIndex(
    (intent) => intent.description === matchedIntent
  );

  if (intentIndex !== -1) {
    const intentHandler = intents[intentIndex];
    if (intentHandler && typeof intentHandler.handler === "function") {
      return {
        optionPath: ["activity", "intents", intentIndex.toString(), "handler"],
        args: [activity],
      };
    }
  }

  return null;
}

/**
 * Handles the "What can you do?" built-in intent.
 * Uses AI to generate a natural language summary of the agent's capabilities.
 */
async function handleDescribeCapabilities(
  plot: Plot,
  activity: Activity
): Promise<void> {
  if (!plot.env) {
    console.warn("Cannot describe capabilities without env bindings");
    return;
  }

  const customIntents = plot.plotOptions?.activity?.intents || [];

  let description: string;
  if (customIntents.length === 0) {
    description =
      "I can help with general tasks. Mention me in an activity to get started!";
  } else {
    // Use AI to generate a natural summary
    const prompt = `Given these capabilities:
${customIntents
  .map((intent, i) => `${i + 1}. ${intent.description}`)
  .join("\n")}

Write a brief, friendly paragraph (2-3 sentences) describing what this agent can help with. Use "I" language.`;

    try {
      const response = await plot.ai.prompt({
        model: {
          speed: "fast",
          cost: "low",
        },
        system:
          "You are a helpful agent describing your capabilities in a friendly, concise way.",
        prompt,
      });

      description = response.text.trim();
    } catch (error) {
      console.error("Error generating capability description:", error);
      description = `I can help with: ${customIntents
        .map((i) => i.description)
        .join(", ")}`;
    }
  }

  // Create reply activity with the description
  await createActivity(plot, {
    type: ActivityType.Note,
    title: "Here's what I can do",
    note: description,
    parent: { id: activity.id },
  });
}

/**
 * Handles the "Remove yourself" built-in intent.
 * Soft-deletes the priority_agent by setting deleted_at.
 */
async function handleRemoveAgent(
  plot: Plot,
  activity: Activity
): Promise<void> {
  try {
    // Set deleted_at on the priority_agent record
    const { error } = await plot.supabase
      .from("priority_agent")
      .update({ deleted_at: new Date().toISOString() })
      .eq("id", plot.priorityAgentId);

    if (error) {
      throw error;
    }

    // Create farewell activity
    await createActivity(plot, {
      type: ActivityType.Note,
      title: "I've removed myself",
      note: "I've been removed from this priority. You can add me back anytime if you need me!",
      parent: { id: activity.id },
    });
  } catch (error) {
    console.error("Error removing agent:", error);

    // Create error activity
    await createActivity(plot, {
      type: ActivityType.Note,
      title: "I couldn't remove myself",
      note: `There was an error removing me: ${
        error instanceof Error ? error.message : "Unknown error"
      }`,
      parent: { id: activity.id },
    });
  }
}
