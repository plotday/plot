/**
 * Derive whether a thread is an active to-do from a `thread_schedule` dispatch
 * item, for the connector/twist `onThreadToDo` callback.
 *
 * `active` is the source of truth: a thread is a to-do when it carries a
 * scheduling intent (`on`/`at`) AND has not been completed. The two dispatch
 * paths feed different row shapes into this, so the expression is written to
 * work for both — absent fields are `undefined`:
 *
 *  - Polling (`twist_instance_thread_schedule` view, via TwistSync/queue):
 *    carries `active`/`read_at` but NO `archived_at`. Completion shows up as
 *    `active === false` (marking a to-do done). `archived_at` is `undefined`,
 *    so `archived_at == null` is `true` and doesn't gate.
 *  - Direct (`POST /sync/schedules`, `schedule` table row): carries
 *    `archived_at` but NO `active`. Completion shows up as `archived_at != null`
 *    (the schedule is archived). `active` is `undefined`, so `active !== false`
 *    is `true` and doesn't gate.
 *
 * Note we intentionally do NOT gate on `read_at`: merely reading a thread that
 * is still an active to-do must not clear it (in Gmail terms, opening a starred
 * message should not remove the star). Only completion (`active === false` /
 * `archived_at`) clears the to-do.
 */
export function deriveScheduleTodo(item: {
  archived_at?: unknown;
  active?: boolean | null;
  on?: unknown;
  at?: unknown;
}): boolean {
  return (
    item.archived_at == null &&
    item.active !== false &&
    (item.on != null || item.at != null)
  );
}
