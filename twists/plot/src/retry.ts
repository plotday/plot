import type { AI } from "@plotday/twister/tools/ai";

const TRANSIENT_PATTERN =
  /\b429\b|\b5\d{2}\b|rate.?limit|overloaded|timeout|timed out|fetch failed|ECONNRESET|network|unavailable/i;

export function isTransientAiError(e: unknown): boolean {
  const message = e instanceof Error ? e.message : String(e);
  return TRANSIENT_PATTERN.test(message);
}

/** One retry on transient provider errors; everything else propagates. */
export async function promptWithRetry(
  ai: Pick<AI, "prompt">,
  request: Parameters<AI["prompt"]>[0],
  retryDelayMs = 1500
): Promise<Awaited<ReturnType<AI["prompt"]>>> {
  try {
    return await ai.prompt(request);
  } catch (error) {
    if (!isTransientAiError(error)) throw error;
    await new Promise((resolve) => setTimeout(resolve, retryDelayMs));
    return await ai.prompt(request);
  }
}
