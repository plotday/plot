# Drop toggle tags; migrate to per-user emoji reactions

Item #2 from `docs/emoji-reactions-followups.md`. Retires the 10
user-facing toggle tags (Pinned, Urgent, Goal, Decision, Waiting,
Blocked, Warning, Question, Star, Idea) into per-user emoji reactions.
Special-cases `Tag.twist` (109), which is runtime-managed indicator
state, by reassigning its id into the compute range. Drops the
`'toggle'` dispatch branches once no rows reference them.

## Scope decisions

- **Full migration in a single landing.** §1 of the followups (filter
  pipeline integration) is not done yet; users will lose toggle-tag
  filtering until that lands. Acceptable because reactions already
  render as chips on individual notes/threads.
- **All 10 user-facing toggle tags become per-user reactions.** The
  semantic shift from collective state ("this is pinned") to per-user
  reaction ("Kris reacted with 📌") is accepted as more honest — these
  tags were always personal annotations rendered as collective.
- **Tag.twist (109) is NOT migrated to a reaction.** It marks runtime
  ownership ("this note is being processed by this twist"), not a user
  reaction. It moves to id 12 in the compute range and keeps its
  current semantics.
- **Decision (104) → ⚖️** (not 🤔). 🤔 was already used for the now-archived
  Thinking count tag (1013).
- **`tag_type` enum value `'toggle'` is retained** for this migration.
  Dropping the enum value happens in a follow-up migration once we've
  confirmed the dispatch retirement is clean.

## Toggle tag → emoji mapping

| Old id | Tag name  | Emoji |
|--------|-----------|-------|
| 100    | Pinned    | 📌    |
| 101    | Urgent    | 🚨    |
| 103    | Goal      | 🎯    |
| 104    | Decision  | ⚖️    |
| 105    | Waiting   | ⏳    |
| 106    | Blocked   | 🚧    |
| 107    | Warning   | ⚠️    |
| 108    | Question  | ❓    |
| 110    | Star      | ⭐    |
| 111    | Idea      | 💡    |

Tag 109 (Twist) is NOT in this mapping — it reassigns to id 12 in the
compute range instead.

## Architecture

```
Toggle tags (100, 101, 103-108, 110, 111)
   ↓ migration: backfill into note_reaction / thread_reaction
                with mapped Unicode emoji; archive source rows
   ↓ schema: drop 'toggle' branch from get_tag_type and from
             upsert/update functions
   ↓ (tag_type enum value 'toggle' retained — drop in follow-up)

Tag.twist (109 → 12)
   ↓ UPDATE existing tag_id=109 rows → 12 in note_tag, thread_tag
   ↓ get_tag_type: id 12 returns 'compute'
   ↓ upsert/update functions: special-case tag 12 to bypass the
     compute-rejection gate (runtime-managed indicator)
   ↓ cron in workers/api/src/index.ts:313: 109 → 12

Flutter
   ↓ Tag enum: 10 toggle entries deleted, Tag.twist's id 109 → 12,
     type changes to TagType.compute
   ↓ Drift migration: bump schemaVersion; archive local rows where
     tag_id BETWEEN 100 AND 111 AND tag_id != 109;
     rename 109 → 12
```

## Single migration: `<timestamp>_drop_toggle_tags.sql`

### Phase 1: Backfill 10 toggle tags into reactions

Mirror `20260526195200_backfill_count_tags_to_reactions.sql` exactly:

```sql
INSERT INTO public.note_reaction (
    actor_id, note_id, emoji, updated_at, archived_at, updated_by, sync_depth
)
SELECT
    nt.actor_id, nt.note_id, m.emoji, nt.updated_at, nt.archived_at,
    nt.updated_by, nt.sync_depth
FROM public.note_tag nt
JOIN (VALUES
    (100, '📌'), (101, '🚨'), (103, '🎯'), (104, '⚖️'),
    (105, '⏳'), (106, '🚧'), (107, '⚠️'), (108, '❓'),
    (110, '⭐'), (111, '💡')
) AS m(tag_id, emoji) ON m.tag_id = nt.tag_id
ON CONFLICT (actor_id, note_id, emoji)
    DO UPDATE SET
        archived_at = LEAST(public.note_reaction.archived_at, EXCLUDED.archived_at),
        updated_at = GREATEST(public.note_reaction.updated_at, EXCLUDED.updated_at);
```

Same shape for `thread_reaction` (including the `occurrence` column on
the unique constraint).

### Phase 2: Reassign Tag.twist (109 → 12)

```sql
UPDATE public.note_tag   SET tag_id = 12 WHERE tag_id = 109;
UPDATE public.thread_tag SET tag_id = 12 WHERE tag_id = 109;
```

No archive — these are live indicator-state rows. The `updated_at` /
seq bump on UPDATE drives sync to clients.

### Phase 3: Archive source toggle-tag rows

```sql
UPDATE public.note_tag
SET archived_at = now()
WHERE tag_id IN (100, 101, 103, 104, 105, 106, 107, 108, 110, 111)
  AND archived_at IS NULL;

UPDATE public.thread_tag
SET archived_at = now()
WHERE tag_id IN (100, 101, 103, 104, 105, 106, 107, 108, 110, 111)
  AND archived_at IS NULL;
```

Per AGENTS.md, never bare-DELETE a synced row.

### Phase 4: Dispatch retirement

Edit `libs/db/schema/40-functions/30-tag.sql`. The toggle range (100-999)
now raises, but the count range (1000+) is **retained** — count-tag
dispatch is still live (e.g. `tag_id = 1019` Reply propagation in
`update_thread_tags` / `update_note_tags`). Count retirement is a
separate follow-up (§3 of `docs/emoji-reactions-followups.md`).

```sql
CREATE OR REPLACE FUNCTION get_tag_type (tag_id integer)
    RETURNS tag_type
    LANGUAGE plpgsql
    IMMUTABLE
    AS $$
BEGIN
    IF tag_id BETWEEN 1 AND 99 THEN
        RETURN 'compute'::tag_type;
    ELSIF tag_id >= 1000 THEN
        RETURN 'count'::tag_type;
    END IF;
    RAISE EXCEPTION 'invalid tag_id: %', tag_id;
END;
$$;
```

Edit `libs/db/schema/90-user-schema/85-user-sync-upserts.sql`:
- `upsert_thread_tag`: drop the toggle special-case logic. The
  compute-rejection gate stays but is updated to allow `p_tag_id = 12`
  (Twist) as the documented runtime-managed exception.
- `upsert_note_tag`: same.

Edit `libs/db/schema/90-user-schema/10-update_thread_tags.sql` and
`11-update_note_tags.sql`:
- Drop toggle-tag arms.
- Keep tag 12 (Twist) writes flowing — comment in line about why this
  one compute tag is writable.

The exact gate-relaxation pattern: the existing code raises on
`v_tag_type = 'compute'`. Change to `v_tag_type = 'compute' AND
p_tag_id != 12` (with a comment block explaining that tag 12 is
runtime-managed indicator state). Confirmed during implementation;
if `update_*_tags` doesn't actually call `upsert_*_tag` (going direct
to the table) no relaxation is needed in those files.

## Flutter changes

### `apps/plot/lib/store/tag.dart`

Delete enum entries: `pinned`, `urgent`, `goal`, `decision`, `waiting`,
`blocked`, `warning`, `question`, `star`, `idea`.

Move `twist` into the compute section:

```dart
twist(
  12,
  PlotIcon.twist,
  'Twisting',
  type: TagType.compute,
  addable: false,
  shortcodes: ['twist', 'twisting'],
),
```

Keep the default `this.type = TagType.toggle` in the constructor for
now — removing it requires touching every compute entry, and is a
separate cleanup that becomes worthwhile once `'toggle'` is dropped
from the enum.

### Drift migration

Bump `Store.schemaVersion` (current → next). Add migration arm:

```dart
if (from < <new_version>) {
  // Archive note/thread tag rows for retired toggle tags
  await m.database.customStatement('''
    UPDATE note_tags SET archived_at = ?
    WHERE tag_id IN (100, 101, 103, 104, 105, 106, 107, 108, 110, 111)
      AND archived_at IS NULL
  ''', [DateTime.now().toIso8601String()]);
  await m.database.customStatement('''
    UPDATE thread_tags SET archived_at = ?
    WHERE tag_id IN (100, 101, 103, 104, 105, 106, 107, 108, 110, 111)
      AND archived_at IS NULL
  ''', [DateTime.now().toIso8601String()]);
  // Reassign Twist tag id
  await m.database.customStatement('UPDATE note_tags SET tag_id = 12 WHERE tag_id = 109');
  await m.database.customStatement('UPDATE thread_tags SET tag_id = 12 WHERE tag_id = 109');
}
```

Adapt exact column/table names per the Drift store conventions in this
project (likely `noteTags`/`threadTags` in Dart, snake_case in SQL).

Run `flutter pub run build_runner build` after the bump.

### Widget / state / command callsites

`grep -rEn "Tag\.(pinned|urgent|goal|decision|waiting|blocked|warning|question|star|idea)" apps/plot/lib`
returns zero hits for the 10 deleted entries — only `Tag.twist` is
referenced in `widget/note.dart`, `widget/note_action.dart`,
`widget/pulsing_color_button.dart`, and `store/note.dart`. Those all
keep working because `Tag.twist` survives, only its id changes (and
the Dart enum identifier hasn't moved).

`flutter analyze` will surface any callsites missed.

## API worker changes

`workers/api/src/index.ts:313`:
- Change `.where("tag_id", "=", 109)` → `.where("tag_id", "=", 12)`.
- Update the surrounding comment block (line ~301-307) from "Twisting
  tag (tag_id 109)" to "(tag_id 12)".

`grep -rn "tag_id.*109\|tag_id = 109"` in `workers/` returns only this
one match. Nothing else needs updating.

## Test plan

### Database

1. `pnpm gen-migration -- drop_toggle_tags` → creates timestamped file.
2. Edit the file to add Phases 1-3 SQL after Atlas's generated DDL
   (Phase 4 schema changes generate automatically from the function
   edits).
3. `pnpm apply-migrations` → succeeds, auto-runs `pnpm types`.
4. `pnpm diff-schema-migrations` → no diff.
5. `pnpm --filter @plotday/db run lint` → types in sync.
6. Manual SQL:
   ```sql
   SELECT tag_id, COUNT(*) FROM note_tag WHERE archived_at IS NULL GROUP BY tag_id;
   SELECT tag_id, COUNT(*) FROM thread_tag WHERE archived_at IS NULL GROUP BY tag_id;
   -- Both should show only ids 1-12, with id 12 (Twist) populated.
   SELECT emoji, COUNT(*) FROM note_reaction GROUP BY emoji;
   -- Should show the 10 mapped emoji with row counts matching pre-migration toggle counts.
   ```
7. `SELECT get_tag_type(12)` → `'compute'`; `SELECT get_tag_type(1019)`
   → `'count'` (count dispatch remains live); `SELECT get_tag_type(100)`
   → raises `invalid tag_id` (toggle range retired).

### Flutter

1. `cd apps/plot && flutter analyze` clean — surfaces any missed
   callsites.
2. `flutter pub run build_runner build` — regenerates `.g.dart` for
   the Drift schema bump.
3. Manual migration test: launch the app (existing local DB), confirm
   it starts cleanly. Inspect local sqlite to verify old toggle rows
   archived and tag_id=109 rows now show 12.

### End-to-end (via `run-app` skill)

1. Open a thread that previously had toggle tags. Confirm the chips
   row now shows the migrated emoji instead of the old toggle icons.
   The reaction picker should not offer Pinned/Star/etc. as duplicate
   options alongside their emoji.
2. Trigger a twist mention on a note → confirm the Twisting indicator
   still renders correctly (Tag.twist with new id 12).
3. (Optional, time-permitting) confirm the cron-driven stuck-Twisting
   cleanup still fires on the new id by patching the WHERE clause
   locally and rerunning.

## Out of scope (follow-ups)

- §1 of `emoji-reactions-followups.md`: filter pipeline integration so
  reactions surface in the filter UI / suggestions / active-filter
  chips. Users temporarily lose tag-as-filter for the migrated tags.
- Dropping the `tag_type` enum value `'toggle'` (separate migration).
- Twist ownership as a dedicated column on `note` / `thread` (a deeper
  refactor that this design explicitly defers by keeping Tag.twist as
  a tag, just compute-classified).
- The cleanup follow-ups in §3 of the followups doc (note.dart count-tag
  chip row, count-tag enum entries) — those are tracked separately.

## Risk notes

- **Existing Twist runtime state.** Any in-flight twist runs at the
  moment of migration that hold a `tag_id = 109` row will see it
  rewritten to 12. Since the UPDATE bumps `updated_at`, sync will
  re-emit the row and the cleanup paths (queue handler finally,
  cron sweep) target the new id — no semantic break, just a moment
  of seq churn for in-progress twists.
- **Old clients in the wild.** A client that hasn't pulled the
  schema-bumped Tag enum yet will see archived toggle-tag rows on
  next sync and stop rendering those chips (correct). It won't know
  the new id-12 mapping for Twist, but the row's name lookup is by
  numeric id in the JSON converter (`Tag.get(id: id)`) — and old
  clients have no id-12 entry, so they'll log "No tag found for id:
  12" and skip it. The Twisting indicator will not render on old
  clients until they update. Acceptable for local-only work.
- **Dispatch gate relaxation for tag 12.** If the implementation
  reveals that `update_thread_tags` / `update_note_tags` already
  bypass the compute-rejection gate (it lives only in `upsert_*_tag`),
  no relaxation is needed. Verify during implementation; if a
  relaxation IS needed, the pattern is `v_tag_type = 'compute' AND
  p_tag_id != 12` with a load-bearing comment.
