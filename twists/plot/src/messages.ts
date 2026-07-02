import { ActorType, type Note } from "@plotday/twister";

export type ChatMessage = { role: "user" | "assistant"; content: string };

/** Max history turns (post-merge) kept verbatim before older turns are summarized. */
export const MAX_TURNS = 40;
/** Max characters kept per message before truncation (suffix `…`). */
export const MAX_CHARS_PER_MESSAGE = 8000;

/**
 * Local helper — clips overly long note content, suffixing `…`. Intentionally
 * duplicates tools.ts's truncateText to keep this module dependency-free;
 * cap semantics differ by one char (this clips to exactly the cap INCLUDING
 * the ellipsis, truncateText appends it after the cap).
 */
function truncate(content: string): string {
  if (content.length <= MAX_CHARS_PER_MESSAGE) return content;
  return content.slice(0, MAX_CHARS_PER_MESSAGE - 1) + "…";
}

/**
 * Build the AI message history from a thread's notes: map authors to
 * user/assistant roles, merge consecutive same-role turns (so the provider
 * sees alternating roles), and ensure the first turn is from the user.
 */
export function buildMessages(notes: Note[]): ChatMessage[] {
  const mapped = notes
    .filter((n) => n.content?.trim())
    .map((n) => ({
      role: (n.author.type === ActorType.Twist ? "assistant" : "user") as
        | "user"
        | "assistant",
      content: truncate(n.content as string),
    }));

  const merged: Array<{ role: "user" | "assistant"; content: string }> = [];
  for (const m of mapped) {
    const last = merged[merged.length - 1];
    if (last && last.role === m.role) {
      last.content += "\n\n" + m.content;
    } else {
      merged.push({ ...m });
    }
  }

  // Providers require the conversation to start with a user turn.
  while (merged.length > 0 && merged[0].role === "assistant") {
    merged.shift();
  }
  return merged;
}

/**
 * Split a merged message history into an older portion (to be summarized)
 * and a recent portion kept verbatim, capped at `maxTurns`. The recent
 * portion always starts with a user turn (provider requirement) — the cut
 * point is nudged forward past any leading assistant turn.
 */
export function partitionHistory(
  merged: ChatMessage[],
  maxTurns = MAX_TURNS
): { older: ChatMessage[]; recent: ChatMessage[] } {
  if (merged.length <= maxTurns) return { older: [], recent: merged };
  let cut = merged.length - maxTurns;
  // Recent must start with a user turn (provider requirement).
  while (cut < merged.length && merged[cut].role === "assistant") cut++;
  return { older: merged.slice(0, cut), recent: merged.slice(cut) };
}

/**
 * Merge a rolling summary of trimmed-off history into the first turn of the
 * recent (kept-verbatim) history, preserving role alternation by attaching
 * the context header to the existing (guaranteed user) first turn rather
 * than inserting a new one.
 */
export function withSummary(
  recent: ChatMessage[],
  summary: string | null,
  omittedCount: number
): ChatMessage[] {
  if (recent.length === 0) return recent;
  const header = summary
    ? `[Context: ${omittedCount} earlier messages omitted. Summary: ${summary}]`
    : `[Context: ${omittedCount} earlier messages omitted.]`;
  const [first, ...rest] = recent;
  // Merge into the first user turn to preserve role alternation.
  return [{ role: "user", content: `${header}\n\n${first.content}` }, ...rest];
}
