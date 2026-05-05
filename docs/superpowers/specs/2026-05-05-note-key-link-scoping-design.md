# Note Key Scoping by Link

## Problem

Connectors identify their notes within a thread using a `key` (e.g. `"description"`, `"comment-12345"`). The current uniqueness rule is `(thread_id, key)`. When a thread aggregates links from multiple connectors — especially after a thread merge — generic keys like `"description"` collide between connectors, and even between two links from the same connector instance on a merged thread.

We need to scope note keys per link. Connectors only ever add notes via a link (`saveLink` / `saveLinks`), so the link is always available at write time.

## Approach

Add `link_id` to `note`. Make `(thread_id, link_id, key)` the uniqueness rule for keyed notes. Backfill existing notes by joining to the earliest matching link. Connector API stays the same — the runtime fills in `link_id` from the `saveLink` call.

## Schema Changes

File: `libs/db/schema/50-tables/25-note.sql`

```sql
ALTER TABLE "public"."note"
    ADD COLUMN "link_id" uuid REFERENCES public.link (id) ON DELETE SET NULL;

DROP INDEX IF EXISTS note_thread_key_unique;

-- Partial unique index: keyed notes are unique per (thread, link).
-- Notes with NULL key (user-authored) are unconstrained.
-- Notes with NULL link_id (user-authored, or a connector note whose link
-- was deleted) coexist because NULL != NULL in unique indexes.
CREATE UNIQUE INDEX note_thread_link_key_unique
    ON "public"."note" ("thread_id", "link_id", "key")
    WHERE key IS NOT NULL;

CREATE INDEX idx_note_link_id ON "public"."note" ("link_id")
    WHERE link_id IS NOT NULL;
```

No changes to `user.note` view — `key` and `link_id` are server-only (already true for `key`).

## Backfill

Embedded in the same Atlas-generated migration after the schema DDL:

```sql
-- For every keyed note created by a connector (twist_instance), assign the
-- earliest matching link on the same thread by the same connector instance.
-- Earliest-link-wins for ambiguous threads (multiple same-connector links),
-- which is expected to be vanishingly rare in current data.
WITH candidates AS (
    SELECT
        n.id AS note_id,
        (
            SELECT l.id
            FROM link l
            WHERE l.thread_id = n.thread_id
              AND l.created_by = n.created_by
            ORDER BY l.created_at ASC, l.id ASC
            LIMIT 1
        ) AS link_id
    FROM note n
    JOIN twist_instance ti ON ti.id = n.created_by
    WHERE n.key IS NOT NULL
)
UPDATE note n
SET link_id = c.link_id
FROM candidates c
WHERE n.id = c.note_id
  AND c.link_id IS NOT NULL;

-- Diagnostic: report keyed connector notes with no matching link. These
-- stay at link_id = NULL and will fall under the partial unique index's
-- NULL semantics (multiple permitted). They're not blockers for merges,
-- but the count surfaces unexpected state.
DO $$
DECLARE
    orphan_count integer;
BEGIN
    SELECT count(*) INTO orphan_count
    FROM note n
    JOIN twist_instance ti ON ti.id = n.created_by
    WHERE n.key IS NOT NULL AND n.link_id IS NULL;
    RAISE NOTICE 'note_link_scoping: % keyed connector notes left without a link_id', orphan_count;
END $$;
```

`thread.seq` is not bumped — clients don't read `key` or `link_id`.

## Runtime Changes

### `workers/api/src/twist/tools/plot/note.ts`

Add `link_id` plumbing through the note write path.

- The function that builds `dbNote` (around line 236) accepts an optional `linkId` from its caller and sets `dbNote.link_id = linkId` when present.
- The ON CONFLICT clause (around line 270 onward) changes from the implicit `(thread_id, key)` constraint to the new partial unique index. Postgres requires either the predicate inline (`ON CONFLICT (thread_id, link_id, key) WHERE key IS NOT NULL`) or the index name (`ON CONFLICT ON CONSTRAINT note_thread_link_key_unique`). Use the predicate form for clarity at the call site.
- Key-based lookup query (around line 665) gains `.where("link_id", "=", linkId)` when `linkId` is known.

### `workers/api/src/twist/tools/integrations.ts`

`saveLink` and `saveLinks` already resolve a `link.id` before writing notes. Pass that ID into the note write path. Concretely, the inner loop that creates notes for a saved link receives the link's UUID and forwards it to `note.ts`'s save function.

### `workers/api/src/twist/tools/plot/thread.ts`

The reply-target lookup at line 843 (`query = query.where("key", "=", note.key)`) joins to a single thread. When the caller is a connector and the thread has more than one of its links, scope this lookup by `link_id` too. The `linkId` is available from the connector's current operation.

### Bare `saveNote(thread, note)` from a connector

Resolve `link_id` server-side by selecting `link.id WHERE thread_id = ? AND created_by = ? (twistInstanceId)`:

- Exactly one match → use it.
- Multiple matches → throw a clear error: `"Cannot resolve link for keyed note: thread {threadId} has {n} links from this connector. Use saveLink instead, or specify the link explicitly."` This is a behavior change but a safer one: the alternative is silently writing to one of N links and possibly producing a unique-index conflict on re-sync.
- Zero matches → leave `link_id = NULL`. Coexists with other NULL-link notes by the partial unique index's NULL semantics.

Notes from non-connector authors (users, Plot tools) always set `link_id = NULL` — no behavior change.

## Connector API (`@plotday/twister`)

No type changes. Update the JSDoc on `Note.key` in `public/twister/src/plot.ts` to mention scoping:

> ... Note keys are scoped to a link, not a thread — two links on the same thread (e.g. after a merge) can each have a `"description"` note without colliding.

This is a doc-only change but still warrants a `patch` changeset under `public/.changeset/`.

## Flutter / Client

No changes. `note.key` and `note.link_id` are not in:
- `user.note` view
- The Flutter `Note` Drift entity
- Any sync payload schema

## Tests

`workers/api/test/` (or the equivalent existing twist-runtime test location):

1. **`saveLink` writes link_id**: One `saveLink` with `notes: [{ key: "description", content: "..." }]` produces a note with `link_id = <link.id>`.
2. **Merged thread, different connectors**: Two threads with `key: "description"` notes from different connectors (different `created_by`) merge into one thread. Both notes survive — distinct rows on `(thread_id, link_id, key)`.
3. **Merged thread, same connector instance**: Two `saveLink` calls on the same thread with different links, each with `key: "description"`. Both notes survive — this is the regression target.
4. **Bare `saveNote`, single link**: Resolves `link_id` automatically.
5. **Bare `saveNote`, multiple links**: Throws the documented error.
6. **Bare `saveNote`, no link**: Writes with `link_id = NULL`.
7. **Backfill correctness**: Seed notes pre-migration; run migration; assert `link_id` matches the earliest link rule. Assert orphan count `RAISE NOTICE` fires.

## Migration Steps

1. Modify `libs/db/schema/50-tables/25-note.sql` per Schema Changes.
2. `pnpm gen-migration -- scope_note_key_by_link`.
3. Append the Backfill SQL to the generated migration file.
4. `pnpm apply-migrations`.
5. `pnpm types`.
6. Update `note.ts`, `integrations.ts`, `thread.ts` per Runtime Changes.
7. Update `Note.key` JSDoc in `public/twister/src/plot.ts`.
8. Add changeset: `public/.changeset/note-key-link-scoping.md` (`patch`, "Changed: ...").
9. `cd public/twister && pnpm build && cd ../..`.
10. Run the test suite.
11. `/finalize`.

## Risks and Open Questions

- **Backfill ambiguity** (multiple same-connector links on one thread, no existing `link_id`): resolved by earliest-link-wins per approval. Logged via `RAISE NOTICE`.
- **Bare `saveNote` ambiguous error**: a behavior change, but it surfaces a real correctness bug. If a connector currently relies on this path on a merged thread, the new error tells them to specify the link. We have not seen this path used by current connectors.
- **Orphan keyed notes** (`link_id = NULL` after backfill): coexist by NULL semantics in the partial unique index. They cannot be re-keyed by a connector via `saveLink` later (because the new write would carry a non-NULL `link_id` and create a separate row). Acceptable: orphans only exist if the link was deleted while the note was kept.
- **Non-`saveLink` connector writes** that create notes via the runtime's lower-level paths (if any): need to be audited so they pass `link_id` through. The `saveLink` and bare `saveNote` paths are the only documented ones; the audit will catch internal callers.
