/**
 * Reconcile a thread's current contact list against the recipient set of an
 * incoming message-mode `saveLink` payload. Applied platform-wide by the
 * `saveLink` boundary whenever the resolved `LinkTypeConfig.sharingModel` is
 * `"message"` — see the "Heuristic" section of
 * docs/superpowers/specs/2026-05-27-thread-sharing-models-design.md.
 *
 * - Added recipients: always merged into the result.
 * - Removed recipients: dropped from the result only when <=50% of the
 *   previous recipients are missing from the incoming set. Larger
 *   subsets are treated as private replies and leave the thread default
 *   untouched.
 *
 * Output order is stable: previous order first, then incoming-only
 * additions, deduped.
 */
export function reconcileThreadContacts(args: {
  previous: string[];
  incoming: string[];
}): string[] {
  const { previous, incoming } = args;
  const incomingSet = new Set(incoming);
  const previousSet = new Set(previous);

  const additions = incoming.filter((c) => !previousSet.has(c));
  const removed = previous.filter((c) => !incomingSet.has(c));

  const removalRatio = previous.length === 0 ? 0 : removed.length / previous.length;
  const treatAsRealRemoval = removalRatio <= 0.5;

  const kept = treatAsRealRemoval
    ? previous.filter((c) => incomingSet.has(c))
    : previous;

  // Dedupe while preserving stable order.
  const out: string[] = [];
  const seen = new Set<string>();
  for (const c of [...kept, ...additions]) {
    if (!seen.has(c)) {
      out.push(c);
      seen.add(c);
    }
  }
  return out;
}
