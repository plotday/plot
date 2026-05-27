/**
 * Compute tags — system state the runtime auto-manages on threads and
 * notes (`todo`, `done`, `twist` activity marker, …).
 *
 * The toggle range (100–999) and count range (1000–1027) have been
 * retired in favour of the open Unicode emoji `Reaction` type — see
 * `@plotday/twister/plot`'s `Reactions` / `NewReactions` and the
 * per-row `note.reactions` / `thread.reactions` fields. Connectors
 * route emoji reactions through `reactions`, not `tags`.
 *
 * `Tag.Twist` is the surviving non-trivial tag: a system marker the
 * runtime adds to a note while a twist is processing it, and clears
 * once the twist returns. It's not user-facing and not a reaction.
 */
export enum Tag {
  Todo = 1,
  Done = 3,
  /** System marker for "a twist is processing this note." Set by the
   * runtime when a twist callback fires, cleared on return. Twists
   * may still write `{ [Tag.Twist]: true | false }` to twistTags to
   * mark/unmark a note explicitly. */
  Twist = 12,
}
