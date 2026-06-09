/**
 * Thread facets — heuristic, message-derived attributes used as internal
 * classifier signal (never user-facing). A connector emits the intrinsic
 * facets on the link it saves; the server stores them on the thread and the
 * focus classifier filters on them.
 *
 * Facets are best-effort: a connector sets a dimension only when a heuristic
 * is confident, leaving it `null` otherwise. The classifier never excludes a
 * thread on a `null` facet.
 *
 * `relationship` (a sender's relationship to the viewing user) is intentionally
 * NOT here: it is recipient-relative and evaluated live by the server, never
 * emitted by a connector.
 */

/** The kind of content. Single-valued. */
export type Format =
  | "chat"
  | "message"
  | "reading"
  | "notification"
  | "receipt"
  | "invoice"
  | "promotion";

/** Whether a person or a system produced the message. */
export type Automation = "human" | "automated";

/** How the user was addressed. */
export type Reach = "direct" | "list";

/**
 * Intrinsic facets a connector may set on a `NewLink`. Each is nullable —
 * omit (or set `null`) when no heuristic is confident.
 */
export type ThreadFacets = {
  format: Format | null;
  automation: Automation | null;
  reach: Reach | null;
};
