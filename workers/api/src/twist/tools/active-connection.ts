/**
 * The canonical definition of an "active connection": one the user has
 * COMMITTED to and that is doing something.
 *
 *   active  ≡  draft = false  AND  archived_at IS NULL  AND  >= 1 enabled channel
 *
 * This predicate is the human-readable, unit-tested anchor for that rule. It is
 * NOT called from the hot paths — SQL and Dart can't invoke a TS function — so
 * the same three conditions are re-expressed inline in each of these places,
 * which MUST be kept in sync with the rule above:
 *   - the dedup guard SQL in integrations.ts (Integrations.storeAuthorization)
 *     — encodes all three conditions.
 *   - the Flutter Active-list filter in apps/plot/lib/command/twist.dart
 *     (and the two onboarding widgets) — applies the `enabledCount > 0` leg;
 *     the draft/archived legs come from GET /sources/summary upstream.
 *   - GET /sources/summary in app/twists.ts — applies the draft + archived
 *     legs server-side, leaving the enabled-channel leg to the Flutter filter.
 *
 * `draft = false` keeps an in-progress OAuth setup from counting; the
 * enabled-channel requirement keeps a committed-but-channel-less orphan from
 * counting (and from silently blocking a re-connect of the same account).
 */
export function isActiveConnection(input: {
  draft: boolean;
  archived: boolean;
  enabledChannelCount: number;
}): boolean {
  return !input.draft && !input.archived && input.enabledChannelCount > 0;
}
