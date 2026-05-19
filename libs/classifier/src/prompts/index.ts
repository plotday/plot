import { COLDSTART_V1 } from "./coldstart-v1";
import { COLDSTART_V2 } from "./coldstart-v2";
import { TIEBREAKER_V1 } from "./tiebreaker-v1";
import { TIEBREAKER_V2 } from "./tiebreaker-v2";
import { TOPIC_AMBIGUITY_V1 } from "./topic-ambiguity-v1";
import { TOPIC_AMBIGUITY_V2 } from "./topic-ambiguity-v2";

const PROMPTS: Record<string, string> = {
  "coldstart-v1": COLDSTART_V1,
  "coldstart-v2": COLDSTART_V2,
  "tiebreaker-v1": TIEBREAKER_V1,
  "tiebreaker-v2": TIEBREAKER_V2,
  "topic-ambiguity-v1": TOPIC_AMBIGUITY_V1,
  "topic-ambiguity-v2": TOPIC_AMBIGUITY_V2,
};

export async function loadPrompt(id: string): Promise<string> {
  const text = PROMPTS[id];
  if (!text) {
    throw new Error(
      `Unknown prompt id: ${id}. Registered: ${Object.keys(PROMPTS).join(", ")}`
    );
  }
  return text;
}
