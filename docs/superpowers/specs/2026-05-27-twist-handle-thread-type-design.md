# Twist handle & threadType — connection-field unification

## Goal

On `NewThreadPage`, move twist selection out of the `NoteEditor` bottom bar and into the connection field above the editor, so users have a single place to pick "where this thread goes": Plot thread, a connector target, or a twist (e.g. "Plot AI chat").

To support this, split twist identity into two distinct labels:

- **`handle`** — at-mention name and author/attribution label (e.g. `Plot`).
- **`threadType`** — label shown in the connection picker (e.g. `Plot AI chat`). When absent, the twist does not appear in the connection picker.

At-mentioning a twist in the editor body also selects that twist as the connection — parallel to how at-mentioning a contact adds them to the thread.

## Twister metadata

Add two optional fields to twist `package.json`, alongside the existing `displayName`/`publisher`/`logoUrl` keys:

```json
{
  "displayName": "Plot",
  "handle": "Plot",
  "threadType": "Plot AI chat"
}
```

Defaults:

- `handle` defaults to `displayName` if not specified.
- `threadType` has no default; absent means the twist is not offered in the connection picker.

`twists/plot/package.json` adds both fields. Only the Plot twist ships in production today, so it is the only consumer at landing time.

`public/twister/cli/commands/deploy.ts` reads the two fields and forwards them in the `POST /v1/twist/:id` request body. A changeset entry is filed under `public/.changeset/`.

## Database

`twist` table (`libs/db/schema/50-tables/90-twist.sql`):

- Add `handle text NOT NULL` (backfilled from `name`).
- Add `thread_type text NULL`.

Both are package-level metadata, not per-install. `twist_instance.name` remains the per-install display name and is unchanged.

Existing `update_seq_and_updated_at` trigger on `twist` already bumps `seq` on update; the migration includes a one-shot `UPDATE twist SET updated_at = now()` so existing rows re-emit through the `user.twist` view and clients pick up the new columns (per `libs/db/AGENTS.md` "Bump on schema changes that add view columns").

`user.twist` view (`libs/db/schema/90-user-schema/32-twist.sql`) exposes `t.handle` and `t.thread_type` alongside the existing columns.

`notify_internal_api_for_twist_instance()` (`libs/db/schema/60-functions/70-update.sql`) needs no change — it notifies on `twist_instance`, not `twist`. However, the joined `user.twist` view is what Flutter reads via `/sync/twist-instances`, so the Zod schema for that endpoint needs the new fields.

`workers/api/src/types.ts` — `TwistInstanceItemSchema` gains `handle: z.string()` and `thread_type: z.string().nullable()`.

`workers/api/src/twist/deployment.ts` — the upsert into `twist` writes `handle` (defaulting to `name`) and `thread_type` from the request body. Both UPDATE and INSERT branches.

## Flutter

### TwistInstance

`apps/plot/lib/store/twist_instance.dart`:

- Drift table `TwistInstances` gains `TextColumn get handle => text()()` and `TextColumn get threadType => text().nullable()()`.
- `Store.schemaVersion` bumped; migration step adds both columns. `handle` defaults to existing `name` for in-place migration.
- New getter `mentionLabel({allInstances, teamName})` mirrors `displayName()` but uses `handle` instead of `name` as the base, preserving the scope-disambiguation suffix logic.
- Existing `displayName()` is unchanged — it still uses `name` and stays the source for settings/marketplace UI.

Call sites that show the twist as a participant/author/mention switch from `displayName(...)` to `mentionLabel(...)`:

- `apps/plot/lib/widget/editor.dart` — `MentionItem.fromTwist`.
- Anywhere a twist is rendered as an author (avatar fallback name, ThreadState author rendering). Audited during implementation.

### Connection picker

`apps/plot/lib/widget/compose/connection_choice.dart` — add a third sealed case:

```dart
class TwistConnectionChoice implements ConnectionChoice {
  final TwistInstance twist;
  // label  → twist.threadType ?? '${twist.handle} chat'
  // logo   → twist.logoUrl
  // toUserAction() → null  (twist selection uses thread.icon, not CreateLinkUserAction)
}
```

`apps/plot/lib/widget/connection_chip.dart` (`ConnectionPickerModal`) builds choices in this order:

1. `ConnectionChoice.plotThread`
2. One `TwistConnectionChoice` per `TwistInstance` where `threadType != null`
3. Existing `CreateTarget`s

The picker is populated from `PriorityBloc.state.twists` (already loaded) plus `loadCreateTargets()`.

`apps/plot/lib/widget/compose/connection_compose_field.dart` renders the twist case: logo + `threadType` as the title; scope suffix as subtitle when the twist has siblings (uses the same disambiguation logic as `displayName()`).

### NewThreadPage wiring

`apps/plot/lib/page/new_thread.dart`:

- `_applyConnectionChoice` handles all three cases:
  - `PlotThreadChoice` — clear `CreateLinkUserAction` AND clear twist (`_selectedTwist = null`, restore default icon).
  - `TargetConnectionChoice` — set `CreateLinkUserAction`, clear twist.
  - `TwistConnectionChoice` — clear `CreateLinkUserAction`, call existing `_selectTwist(twist)` path.
- `_resolveActiveConnectionChoice` — if `_selectedTwist != null`, return the corresponding `TwistConnectionChoice`; otherwise existing logic.
- New: at-mention → connection wire. A new optional `onTwistMentioned(String twistId)` callback on `NoteEditor`/`Editor`. When fired, `NewThreadPage` looks up the `TwistInstance` from cache and calls `_selectTwist(twist)`. The @-mention text continues to be inserted in the body — matches contact-mention behavior.

### NoteEditor cleanup

`apps/plot/lib/widget/note_editor.dart`:

- Remove `_buildNewThreadTwistButton()` and its call site at the end of `_buildNewThreadBottomBar`.
- Remove the new-thread branch of `_shortcutSelectTwist` (`⌘⇧M`). The corresponding shortcut on the page level can be re-added in a follow-up if needed, but per YAGNI we drop it now — the connection field is one click away.
- Keep `_buildTwistButton()` (note-mode toggle) and `selectedTwist`/`onTwistSelected` props unchanged — the parent (`NewThreadPage`) still owns the state.

### Editor mention callback

`apps/plot/lib/widget/editor.dart`:

- `Editor` gains `final void Function(String twistId)? onTwistMentioned`.
- In `_buildEditorMentionPopover.onItemSelected`, when `item.isTwist`, call `widget.onTwistMentioned?.call(item.id)` in addition to the existing `recordMentionUsage`/`completeMention` calls.
- `NoteEditor` plumbs the prop through to `NewThreadPage`'s callback.

## Out of scope

- Renaming `displayName` → `handle` in twist metadata. They are distinct concepts.
- Backfilling `threadType` for arbitrary twists. Only Plot opts in at landing.
- Reworking the note-mode twist button (`_buildTwistButton`) on ThreadPage. Different feature.
- Re-introducing a keyboard shortcut for the new connection picker on NewThreadPage.

## File touch list

- `public/twister/cli/commands/deploy.ts`
- `public/.changeset/twist-handle-thread-type.md` (new)
- `twists/plot/package.json`
- `libs/db/schema/50-tables/90-twist.sql`
- `libs/db/schema/90-user-schema/32-twist.sql`
- new Atlas migration + regenerated `libs/db/src/types.ts`
- `workers/api/src/twist/deployment.ts`
- `workers/api/src/types.ts`
- `apps/plot/lib/store/twist_instance.dart`
- Drift migration in `apps/plot/lib/store/store.dart` (bump `schemaVersion`)
- `apps/plot/lib/widget/compose/connection_choice.dart`
- `apps/plot/lib/widget/compose/connection_compose_field.dart`
- `apps/plot/lib/widget/connection_chip.dart`
- `apps/plot/lib/page/new_thread.dart`
- `apps/plot/lib/widget/note_editor.dart`
- `apps/plot/lib/widget/editor.dart`
- audit pass: any author/attribution call sites that currently use `TwistInstance.displayName()` for mention/author display switch to `mentionLabel()`
