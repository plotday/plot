# Platform fix: connector write-back echo/over-dispatch loop

**Date:** 2026-07-02
**Status:** Draft v2 — revised after design review (provenance transport, migration shape, view scoping, Gmail KV retention)
**Author:** Kris + Claude
**Related:** `project_gmail_star_writeback_reunread_loop` (diagnosis), `project_inbound_read_sync_not_clearing_thread_state`, `project_active_read_guard_rejects_after_reply`

> **Scope assumption (confirm):** land the general mechanism for `thread_state`
> (`onThreadRead` + `onThreadToDo`) first — where the reported bug lives and both
> connector KV caches are — then extend the identical pattern to
> `schedule_contact` and `note_reaction` as a follow-up. If you want all four in
> one change, the mechanism is unchanged; only the migration/test surface grows.

## Problem

Connector state-mirror write-back callbacks are dispatched from per-row `seq`-cursor
views and fire on **any** change to the backing row, carrying the **current** value.
Two defects fall out:

- **(A) Over-dispatch across dimensions.** `read_at` and `active`/`on`/`at` share a
  single `thread_state.seq`, so a star (an `active` write) re-fires `onThreadRead`
  carrying the current `read_at`.
- **(B) No echo/origin suppression.** A value the connector *synced in* re-fires back
  *out*. Connectors work around this with local KV (`unread:{id}`, `starred:{id}`,
  `skip_todo_writeback`).

### Reported failure (prod thread `019f1e4f-…`, owner kris)

1. A genuine new reply (external sender) arrives → Plot correctly marks the thread
   unread for the owner (`read_at = NULL`). This is connector-inbound-caused.
2. Owner reads + stars the thread **in Gmail** (no Plot interaction).
3. The star writes `active = true` → bumps `thread_state.seq` → `twist_instance_thread_read`
   re-emits the row with `read_at = NULL` → `onThreadRead(unread=true)` →
   `api.modifyThread(id, ["UNREAD"])` **re-adds the UNREAD label in Gmail**, undoing the
   manual read.
4. Gmail's re-added UNREAD comes back inbound → `markThreadUnreadForUsers("all")` clears
   `read_at` again. Both sides settle on unread/unread.

### The class

Four callbacks share the exact pattern:

| Callback | View | Backing row / cursor | Mirrored dimension(s) |
|---|---|---|---|
| `onThreadRead` | `twist_instance_thread_read` | `thread_state.seq` | `read_at` |
| `onThreadToDo` | `twist_instance_thread_schedule` | `thread_state.seq` | `active`, `on`, `at` |
| `onScheduleContactUpdated` | `twist_instance_schedule_contact` | `schedule_contact.seq` | `status` (RSVP) |
| `onNoteReactionChanged` | `twist_instance_note_reaction_change` | `note_reaction.seq` | emoji add/remove |

(`read_at` is deliberately NOT part of the todo dimension: `deriveScheduleTodo`
in `workers/api/src/twist/tools/schedule-todo.ts` ignores it — reading a starred
thread must not clear the star. The header comment on
`twist_instance_thread_schedule` still claims dispatchers derive todo from
read_at; fix that stale comment when redefining the view.)

Because a connector-inbound write and a Plot-user write both act "as the owner,"
**actor identity alone cannot distinguish them** — closing (B) requires recording
*how* each write happened (connector sync-in vs. Plot-side action), per dimension.

## Principle

> A write-back callback fires only when **(1)** its specific mirrored dimension
> actually changed value **and (2)** the change originated outside the connector we'd
> dispatch to.

Track (1) with per-dimension change-seqs; track (2) with per-dimension write-provenance.
Both live in the platform; connectors keep no echo state.

## Design (thread_state)

### 1. Per-dimension change-seqs — nullable, no default, COALESCE fallback

Add to `public.thread_state`:

- `read_seq xid8` — **nullable, no default**. Set by the trigger only when `read_at`
  changes value.
- `todo_seq xid8` — **nullable, no default**. Set by the trigger only when `active`,
  `on`, or `at` change value.

Views expose `COALESCE(ts.read_seq, ts.seq)` / `COALESCE(ts.todo_seq, ts.seq)` as
`seq`. This is the load-bearing migration-safety choice:

- **No table rewrite.** A nullable column with no default is a metadata-only
  `ALTER TABLE` — a volatile default (`DEFAULT pg_current_xact_id()`) would force a
  full rewrite of `thread_state` (one row per user×thread, one of the hottest
  tables) under ACCESS EXCLUSIVE.
- **No backfill.** Existing rows fall back to today's exact `seq` values, so
  stored twist-sync cursors stay valid and the first post-deploy poll re-dispatches
  nothing. (A backfill `UPDATE` would either fire the current trigger — bumping
  every row's `seq`, causing a full connector re-dispatch AND a full Flutter
  client re-pull via `sync_user_for_thread_state` — or, if run after the new
  trigger is installed, be clobbered back to NULL by the trigger's preserve
  branch. COALESCE sidesteps the whole ordering problem.)
- **No `SET NOT NULL` validation scan.** The columns stay nullable forever;
  NULL simply means "no dimension-scoped change since this feature shipped."

**No new indexes initially.** Every `thread_state` UPDATE is already non-HOT
(`seq` is indexed and always changes), so two more indexes are pure write
amplification on a hot table. The twist-sync view queries reach `thread_state`
via `idx_thread_state_thread_id` per created-thread join, not via a seq range
scan (`idx_thread_state_user_seq` serves `/sync/threads`, not these views) —
and with COALESCE a plain btree on `read_seq` wouldn't match anyway. Run
EXPLAIN on the real view queries after landing; add an expression index
(`(COALESCE(read_seq, seq))`) only if it shows need.

### 2. Per-dimension write-provenance

Add:

- `read_source uuid` — the `twist_instance_id` that last wrote `read_at` **via a
  connector sync-in**; `NULL` when the last `read_at` write was Plot-side (user/AI).
- `todo_source uuid` — same, for the todo dimension.

### 3. Dedicated seq/provenance trigger

Replace `thread_state`'s use of the generic `update_seq_and_updated_at` with a
`thread_state_seq_and_updated_at` BEFORE INSERT/UPDATE trigger (shape mirrors the
existing `thread_priority_seq_and_updated_at` in `40-functions/01-common.sql`):

- Preserve the existing `plot.skip_activity_seq` short-circuit and the base
  `updated_at`/`seq` bump for compatibility. In the short-circuit branch also
  explicitly preserve `OLD.read_seq/read_source/todo_seq/todo_source`.
- On UPDATE, compute per dimension:
  - `read_changed := NEW.read_at IS DISTINCT FROM OLD.read_at`
  - `todo_changed := NEW.active IS DISTINCT FROM OLD.active OR NEW."on" IS DISTINCT FROM OLD."on" OR NEW."at" IS DISTINCT FROM OLD."at"`
  - if `read_changed`: `NEW.read_seq := pg_current_xact_id(); NEW.read_source := NULLIF(current_setting('plot.write_source_twist_instance', true), '')::uuid;`
  - if `todo_changed`: `NEW.todo_seq := pg_current_xact_id(); NEW.todo_source := <same GUC>;`
  - else `NEW.read_seq := OLD.read_seq; NEW.read_source := OLD.read_source;`
    (resp. todo) so a stray column write can't clobber them.
- On INSERT: set both `*_seq := pg_current_xact_id()` and `*_source` from the GUC.

The GUC `plot.write_source_twist_instance` is transaction-local and unset by default,
exactly like `plot.skip_activity_seq` — so any writer that does not set it yields
`NULL` provenance (= Plot-origin = dispatchable).

### 4. Dimension-scoped, echo-filtered views

`twist_instance_thread_read` — expose the COALESCEd dimension seq as `seq`, add
the echo filter, and **keep the join otherwise as-is** (see scoping note below):

```sql
SELECT a.created_by AS twist_instance_id, tu.thread_id, tu.user_id, tu.read_at,
       tu.updated_at, COALESCE(tu.read_seq, tu.seq) AS seq, tp.priority_id
FROM twist_instance pt
JOIN thread a ON a.created_by = pt.id
LEFT JOIN thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
JOIN thread_state tu ON tu.thread_id = a.id
WHERE a.draft = FALSE AND pt.archived_at IS NULL
  AND tu.updated_at > pt.created_at
  AND tu.read_source IS DISTINCT FROM pt.id     -- (B) don't echo our own sync-in
ORDER BY COALESCE(tu.read_seq, tu.seq) ASC;
```

`twist_instance_thread_schedule` — analogous: `COALESCE(ts.todo_seq, ts.seq) AS seq`,
order by the same expression, add `AND ts.todo_source IS DISTINCT FROM pt.id`. This
view is already owner-scoped (`ts.user_id = pt.owner_id`); keep that. Also fix its
stale header comment (see "The class" above).

Keeping the exposed column named `seq` (still xid8) means `twist-sync.ts`
(`getSyncSeqExpr("thread_read"/"thread_schedule","update")`, horizon, ordering) is
**unchanged**.

**Owner-scoping decision (explicit):** the read view is NOT owner-scoped today —
it emits every user's read rows, and the owner filter lives at connector dispatch
time (`integrations.ts` thread_read handler, `owner.owner_id !== item.user_id`).
The Plot-tool twist dispatch path (`plot/index.ts` thread_read handler) dispatches
`onThreadRead` to twists with thread access for *any* user's read transition.
**This change keeps the read view unscoped** and relies on the provenance filter
alone, so twist-facing semantics don't silently narrow. Owner-scoping the view
would be a real efficiency win for connectors (non-owner rows currently burn slots
in the 100-row poll window and are discarded at dispatch) — do it as a follow-up
after auditing twist consumers of non-owner `onThreadRead` events.

### 5. Provenance transport: RPC parameter, not caller-side GUC

**A caller-side `set_config(..., is_local => true)` does not work here.** Every
connector-attributed `thread_state` write path runs **autocommit** on `plot.db`
(`rpcUser("upsert_thread_state", ...)` in `markThreadUnreadForUsers` /
`applyThreadToDoForUser`, `rpcUser("clear_thread_state", ...)` in
`markThreadReadForOwner`, plus one direct UPDATE) — a transaction-local GUC issued
as a separate autocommit statement evaporates before the write statement runs,
and a session-level GUC is unsafe under Hyperdrive pooling. Wrapping every call
site in explicit transactions would also change retry semantics (`rpcWithSchema`
applies `retryOnTxnConflict` only to autocommit calls).

Instead, move the `set_config` **inside the SQL functions**:

- Add an optional trailing parameter `p_write_source uuid DEFAULT NULL` to
  `user.upsert_thread_state` and `user.clear_thread_state`.
- First line of each function body:
  `PERFORM set_config('plot.write_source_twist_instance', COALESCE(p_write_source::text, ''), true);`
  A single statement is its own transaction, so the trigger fired within the
  statement sees the GUC, and it self-resets at statement end. The unconditional
  set (with `''` for NULL) also prevents leakage between consecutive RPC calls
  inside one enclosing `withUserDb` transaction. Backward compatible: existing
  callers omit the parameter → `''` → `NULL` provenance → dispatchable, exactly
  today's behavior.

Call-site changes:

- `workers/api/src/twist/tools/plot/thread.ts`: `markThreadReadForOwner`,
  `markThreadUnreadForUsers` pass `p_write_source: plot.twistInstanceId`.
- `workers/api/src/twist/tools/integrations.ts`: `applyThreadToDoForUser` passes
  it on the `upsert_thread_state` active path; its direct `thread_state` UPDATE
  (the todo=false read path) gets wrapped in a small explicit transaction with
  `SET LOCAL` (or rerouted through `clear_thread_state` if behavior-equivalent —
  decide at implementation; the explicit transaction is the behavior-preserving
  default). Audit for any other `saveLink`-driven read/unread write.
- Plot `/sync/*` routes, AI/classify, and note-analysis do **not** pass it
  (NULL → dispatch).

**Deferred writes:** `upsert_thread_state` defers into `pending_thread_state`
when no usable `thread_priority` row exists, and the payload is flushed later by
a trigger running in *someone else's* transaction — where the GUC context is
gone (or worse, belongs to a different writer). The payload already serializes
every `p_*` argument one-to-one, so `p_write_source` must be included in the
stored payload and replayed by the applier. Without this, deferred
connector-inbound writes lose provenance and echo.

### 6. Connector cleanup (removes the KV the user wants gone — partially)

Once provenance suppresses echo platform-side:

- Gmail `sync.ts`: delete the `skip_todo_writeback:{id}` key entirely — both the
  set (inbound star handler) and the check-and-clear (top of `onThreadToDoFn`).
- **KEEP the `unread:{id}` / `starred:{id}` writes in `onThreadReadFn` /
  `onThreadToDoFn` for now.** They are dual-purpose: echo suppression (now
  redundant) AND the baseline that *inbound* change-detection compares against.
  Deleting the outbound baseline writes while inbound reads remain leaves stale
  baselines after every write-back → a spurious inbound "change" on the next
  Gmail poll. Mostly those settle as no-ops under the new trigger, but there is
  a real regression window: user reads in Plot → write-back removes UNREAD in
  Gmail (baseline stays "unread") → user marks the thread unread in Plot → next
  poll sees `isUnread=false ≠ baseline` → spurious inbound "read" →
  `clear_thread_state` passes its race guard (no newer content) and **reverts
  the user's manual mark-unread**. Today the pre-write baseline update prevents
  exactly this. These keys go away in the inbound rework (Out of scope below),
  when connectors report live source-app truth and lean on platform idempotency.
- Audit other bidirectional connectors (`public/connectors/*` AND private
  `connectors/*` — linkedin/instagram/whatsapp) for `skip_*`-style
  outbound-suppression KV (safe to remove) vs. inbound change-detection
  baselines (keep until the inbound rework).

## Generalization (follow-up, identical pattern)

- `schedule_contact`: add `status_source uuid`; `twist_instance_schedule_contact` gains
  `AND sc.status_source IS DISTINCT FROM pt.id`. Single dimension → existing `seq` is
  fine (optional `status_seq` if role-only churn proves noisy). Connector RSVP sync-in
  passes the write source; user `POST /sync/schedule/status` does not. Same transport
  rule: the RSVP write paths are autocommit too, so provenance rides an RPC parameter
  (or an explicit transaction), never a caller-side GUC statement.
- `note_reaction`: add `source_twist_instance uuid`; `twist_instance_note_reaction_change`
  gains a filter suppressing the connector's own synced-in reactions. Connector reaction
  sync-in stamps it; user reactions do not.

## Migration & backward compatibility

Expand-only (`migrations/`, Squawk-safe), and — because the columns are nullable
with no default — **metadata-only DDL, no rewrite, no backfill, no data
migration**:

- Add `read_seq`, `todo_seq` (xid8, nullable, no default) and `read_source`,
  `todo_source` (uuid, nullable) to `thread_state`.
- Create `thread_state_seq_and_updated_at()` and swap `thread_state`'s trigger to it.
- `CREATE OR REPLACE` the two views (same output column names/types — `seq` stays
  xid8 via COALESCE — so REPLACE is legal).
- `CREATE OR REPLACE` `user.upsert_thread_state` / `user.clear_thread_state` with
  the trailing `p_write_source uuid DEFAULT NULL` parameter (additive, old callers
  unaffected) + the `pending_thread_state` payload/applier change.
- No new indexes (see §1); revisit with EXPLAIN after landing.
- **Cursor continuity:** existing rows COALESCE to their current `seq`, which is
  ≤ every stored twist-sync cursor's horizon semantics — the first post-deploy
  poll re-dispatches nothing. New writes stamp `read_seq`/`todo_seq` from
  `pg_current_xact_id()`, the same monotonic xid8 domain the cursors already use.
- **Deploy window safety:** old workers call the old function signatures / write
  `thread_state` directly without provenance → `*_source` stays `NULL` → treated
  as Plot-origin → dispatches. That is exactly today's behavior, so no echo
  *regression* while old and new workers coexist; suppression activates as new
  workers ship. The over-dispatch fix (A) activates immediately for new writes
  (dimension seqs advance only on real changes) and is inert for old rows
  (COALESCE fallback).
- Regenerate `libs/db/src/types.ts` (`pnpm apply-migrations` → commit).

## Testing

- **DB/trigger unit tests:** `read_at` change bumps `read_seq` only (not `todo_seq`);
  `active`/`on`/`at` change bumps `todo_seq` only; provenance stamps the
  corresponding `*_source`; no provenance → `NULL`; no-op update (identical value)
  bumps neither and preserves prior `*_seq`/`*_source`; NULL `read_seq` COALESCEs
  to `seq` in both views.
- **Provenance transport (the test that catches the autocommit trap):** call the
  real code paths — `markThreadUnreadForUsers`, `markThreadReadForOwner`,
  `applyThreadToDoForUser` — over a plain (non-transaction) db handle and assert
  `read_source`/`todo_source` actually land non-NULL. A test that sets the GUC
  manually would pass while the feature silently no-ops in production.
- **Deferred-write provenance:** `upsert_thread_state` deferring into
  `pending_thread_state` with `p_write_source` set → flush via the applier →
  `*_source` preserved on the final row.
- **Dispatch integration (regression for the reported bug):** extend
  `integrations-thread-read.test.ts` / sibling schedule test —
  - connector-inbound unread (`read_source = instance`) → `onThreadRead` **not**
    dispatched;
  - a `todo`/`active` write does **not** dispatch `onThreadRead`;
  - a Plot-side read (`read_source = NULL`) → `onThreadRead` **is** dispatched;
  - symmetric checks for `onThreadToDo`;
  - non-owner read rows still flow to the Plot-tool twist dispatch path
    (view stays unscoped) and are still dropped by the connector dispatch
    owner check.
  Cover both consumers of the dispatch item shapes: the TwistSync DO poll
  (`state/twist-sync.ts`) and the queue path (`queue/updates.ts`).
- **Connector suite:** after `skip_todo_writeback` removal, Gmail tests stay
  green (baseline `unread:`/`starred:` writes retained); add a case asserting a
  Gmail-originated star+read round-trips without re-adding UNREAD.

## Edge cases

- **Cross-connector shared threads:** provenance `= pt.id` suppresses only the
  owning connector's own sync-ins; a different instance's writes carry a different
  id (or NULL) and still dispatch. The schedule view is additionally owner-scoped;
  the read view stays unscoped with the owner check at dispatch (see §4).
- **User sets a value identical to the connector's** (e.g. marks read when already
  read): value unchanged → no `read_seq` bump → no dispatch. Correct. This also
  means a same-value connector write never *takes over* provenance from a
  Plot-side write — `*_source` only moves on real value changes.
- **AI/classify sets `active`/`importance`:** no `p_write_source` → `todo_source =
  NULL` → dispatches `onThreadToDo` → connector stars in the source app. This is
  the intended AI-driven-todo behavior, preserved.
- **Twists (not just connectors) get echo suppression:** any twist calling
  `createThread` → `markThreadUnreadForUsers` stamps its own instance id, so the
  unread transition it caused is suppressed from its own `onThreadRead`. That is
  a (desirable) behavior change for twists too — they no longer hear echoes of
  their own thread-creation — and is worth a line in the twist changelog.

## Out of scope

- Reworking connector *inbound* change-detection (letting connectors always report the
  live source-app state and rely entirely on platform idempotency). Worth doing later;
  it is also what finally removes the Gmail `unread:`/`starred:` baseline KV (§6).
- Owner-scoping `twist_instance_thread_read` (efficiency follow-up gated on a twist
  consumer audit — see §4).
- The stale-`created_by` backfill (`project_gmail_starred_todo_writeback_stale_created_by`)
  — orthogonal; that governs *whether* write-back dispatches at all, this governs
  *when/which*.
