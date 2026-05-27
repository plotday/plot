/**
 * Thread / note tags. Two remaining types:
 * 1. Compute tags (1–99) — system state (Todo, Done, …) that the runtime
 *    auto-manages.
 * 2. Toggle tags (100–999) — shared boolean state on a thread/note
 *    (Pinned, Urgent, Goal, Decision, Waiting, Blocked, Warning,
 *    Question, Twist, Star, Idea) that any member can flip.
 *
 * The count-tag range (1000–1027) was retired in favour of the open
 * Unicode emoji `Reaction` type — see `@plotday/twister/plot`'s
 * `Reactions` / `NewReactions` and the per-row `note.reactions` /
 * `thread.reactions` fields. Connectors should route emoji reactions
 * through `reactions`, not `tags`.
 *
 * Migration of existing data is handled server-side; old clients still
 * reading archived count-tag rows from local caches degrade gracefully.
 */
export enum Tag {
  // Compute tags
  Todo = 1,
  Done = 3,

  // Toggle tags
  Pinned = 100,
  Urgent = 101,
  Goal = 103,
  Decision = 104,
  Waiting = 105,
  Blocked = 106,
  Warning = 107,
  Question = 108,
  Twist = 109,
  Star = 110,
  Idea = 111,
}
