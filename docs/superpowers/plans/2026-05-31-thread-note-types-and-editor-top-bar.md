# Thread Note Types and NoteEditor Top Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface note type/mode at the top of NoteEditor (Plot: Note/Task/Chat; connectors: Reply/Comment/Private; with per-message recipient picker), align placeholders and Send-button labels to the active mode, and add per-note group access via a new `Note.accessGroups` column.

**Architecture:** A new `NoteEditorTopBar` widget renders a sealed `TopBarState` (`PillRow` | `Replying` | `Editing`) computed by `NoteEditor` from `(thread, replyTo, editingNote, primaryLinkTypeConfig, draft.accessContacts, draft.accessGroups)`. The bottom bar loses its Task and Private toggles. A new `RecipientPickerModal` extends the per-note audience (contacts + groups) and writes through to `thread.contacts` / `thread.groups` when adding new recipients. Per-connector copy lives on `LinkTypeConfig` via four new optional strings; Flutter falls back to derivation when unset.

**Tech Stack:** Flutter (Dart, forui, Drift, Bloc); TypeScript (twister SDK, Cloudflare Workers API, public connectors); Postgres (Atlas migrations).

**Spec:** `docs/superpowers/specs/2026-05-31-thread-note-types-and-editor-top-bar-design.md`. Read it before starting.

---

## Worktree setup

If running outside a worktree, dispatch into one via `superpowers:using-git-worktrees` from main. Otherwise, run inside the existing worktree.

Before starting tasks in a worktree, run any project-specific bootstrap from `AGENTS.md`:

- `pnpm install` (handled by WorktreeCreate hook)
- `cd public/twister && pnpm build` (if not already built — Twister types must compile before downstream packages typecheck)
- `bash scripts/worktree-db` (creates the worktree's isolated Postgres on a unique port; sets `$DATABASE_URL` in `.claude/settings.local.json`)
- `cd apps/plot && flutter pub get && flutter pub run build_runner build` (generates Drift `.g.dart` files; required for `flutter analyze` and tests)
- Copy `app.env` from main repo if `flutter test` is needed: `pnpm cp-env <main-repo-path>`

---

## Task 1: Add four optional copy fields to `LinkTypeConfig` in Twister SDK

**Files:**
- Modify: `public/twister/src/tools/integrations.ts`
- Create: `public/.changeset/note-editor-copy-fields.md`

- [ ] **Step 1: Add the four fields to `LinkTypeConfig`**

Open `public/twister/src/tools/integrations.ts` and find the `LinkTypeConfig` type. Insert these fields alongside the existing optional ones (after `noteLabel?: string;`):

```ts
  /**
   * Placeholder shown in the editor when this link type is the target of a
   * new thread (NewThreadPage). Example: "Send a Gmail email".
   * If unset, Plot derives "Create a new {connector} {label.toLowerCase()}".
   */
  composePlaceholder?: string;

  /**
   * Label for the Send button on NewThreadPage when this link type is the
   * target. Example: "Send". If unset, defaults to "Create".
   */
  composeVerb?: string;

  /**
   * Placeholder shown in the in-thread editor for the default reply mode.
   * Example: "Reply" (Gmail), "Add a comment" (Linear). If unset, Plot derives
   * "Add a {noteLabel.toLowerCase()}" or "Add a note".
   */
  replyPlaceholder?: string;

  /**
   * Label for the Send button in the in-thread editor. Example: "Send"
   * (Gmail), "Comment" (Linear). If unset, defaults to "Send".
   */
  replyVerb?: string;
```

- [ ] **Step 2: Build the Twister package**

Run from the repo root:

```bash
cd public/twister && pnpm build && cd -
```

Expected: Successful build. The new fields show up in `public/twister/dist/tools/integrations.d.ts`.

Verify:

```bash
grep -nP 'composePlaceholder|replyPlaceholder' public/twister/dist/tools/integrations.d.ts
```

Expected: Four matches showing the new field signatures.

- [ ] **Step 3: Create the changeset**

Create `public/.changeset/note-editor-copy-fields.md` with this exact content:

```markdown
---
"@plotday/twister": minor
---

Added: composePlaceholder, composeVerb, replyPlaceholder, replyVerb optional string fields on LinkTypeConfig. Connectors can now override the editor placeholder text and Send-button label per link type for both new-thread composition and in-thread replies. When unset, Plot derives values from existing label / noteLabel fields.
```

- [ ] **Step 4: Validate the changeset**

```bash
cd public && pnpm validate-changesets && cd -
```

Expected: No errors. The changeset passes the project's validation rules.

- [ ] **Step 5: Commit**

```bash
git add public/twister/src/tools/integrations.ts public/.changeset/note-editor-copy-fields.md
git commit -m "feat(twister): add composePlaceholder/composeVerb/replyPlaceholder/replyVerb to LinkTypeConfig

Lets connectors override editor placeholder text and Send-button label per
link type for both NewThreadPage composition and in-thread replies. All four
fields are optional; Plot derives sensible defaults from existing label and
noteLabel when unset.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Set the new copy fields on the Gmail and Linear connectors

**Files:**
- Modify: `public/connectors/gmail/src/gmail.ts`
- Modify: `public/connectors/linear/src/linear.ts`

- [ ] **Step 1: Update Gmail connector**

Open `public/connectors/gmail/src/gmail.ts`. Find the `linkTypes` array (look for `type: "email"`). Add the four new fields to that entry. Existing entry looks like:

```ts
readonly linkTypes = [
  {
    type: "email",
    label: "Thread",
    noteLabel: "Reply",
    sharingModel: "message" as const,
    logo: "https://api.iconify.design/logos/google-gmail.svg",
    contactRoles: [
      { id: "to", label: "To", default: true },
      { id: "cc", label: "CC" },
      { id: "bcc", label: "BCC", hidden: true },
    ],
    supportsContactChanges: true,
    compose: { targets: "addresses", status: "sent" },
  },
];
```

Add the four fields after `sharingModel`:

```ts
    sharingModel: "message" as const,
    composePlaceholder: "Send a Gmail email",
    composeVerb: "Send",
    replyPlaceholder: "Reply",
    replyVerb: "Send",
```

- [ ] **Step 2: Update Linear connector**

Open `public/connectors/linear/src/linear.ts`. Find the `linkTypes` array (look for `type: "issue"`). Add the four new fields after `sharingModel`:

```ts
    sharingModel: "channel" as const,
    composePlaceholder: "Create a Linear issue",
    composeVerb: "Create",
    replyPlaceholder: "Add a comment",
    replyVerb: "Comment",
```

- [ ] **Step 3: Lint both connectors**

```bash
pnpm --filter @plot-connectors/gmail lint && pnpm --filter @plot-connectors/linear lint
```

Expected: No errors. The new fields are recognized because Task 1 built the Twister package that the connectors consume via `workspace:*`.

- [ ] **Step 4: Commit**

```bash
git add public/connectors/gmail/src/gmail.ts public/connectors/linear/src/linear.ts
git commit -m "feat(connectors): set compose/reply placeholders and verbs for Gmail and Linear

Gmail: \"Send a Gmail email\" / \"Send\" for compose; \"Reply\" / \"Send\" for in-thread.
Linear: \"Create a Linear issue\" / \"Create\" for compose; \"Add a comment\" / \"Comment\" for in-thread.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Mirror the four new fields in the Dart `LinkTypeConfig`

**Files:**
- Modify: `apps/plot/lib/store/link.dart`
- Test: `apps/plot/test/store/link_test.dart`

- [ ] **Step 1: Locate the existing `LinkTypeConfig` mirror**

```bash
grep -nP 'class LinkTypeConfig|noteLabel|label\s*:\s*String' apps/plot/lib/store/link.dart | head -20
```

Find the class definition, its constructor, and the `fromJson` (or equivalent) parser. The class currently mirrors `label`, `noteLabel`, `logo`, `statuses`, etc.

- [ ] **Step 2: Add the four fields to the class**

In the `LinkTypeConfig` class body, add (alongside the existing `noteLabel`):

```dart
  final String? composePlaceholder;
  final String? composeVerb;
  final String? replyPlaceholder;
  final String? replyVerb;
```

In the constructor parameters (named, optional), add:

```dart
    this.composePlaceholder,
    this.composeVerb,
    this.replyPlaceholder,
    this.replyVerb,
```

- [ ] **Step 3: Update the JSON parser to read snake_case fields**

In the `fromJson` factory (or wherever JSON parsing lives), add reads for each new field. The Plot pattern reads snake_case from API responses:

```dart
      composePlaceholder: json['compose_placeholder'] as String?,
      composeVerb: json['compose_verb'] as String?,
      replyPlaceholder: json['reply_placeholder'] as String?,
      replyVerb: json['reply_verb'] as String?,
```

- [ ] **Step 4: Write a unit test**

Create or extend `apps/plot/test/store/link_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/link.dart';

void main() {
  group('LinkTypeConfig.fromJson', () {
    test('parses the four new compose/reply copy fields', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'email',
        'label': 'Thread',
        'note_label': 'Reply',
        'compose_placeholder': 'Send a Gmail email',
        'compose_verb': 'Send',
        'reply_placeholder': 'Reply',
        'reply_verb': 'Send',
      });
      expect(cfg.composePlaceholder, 'Send a Gmail email');
      expect(cfg.composeVerb, 'Send');
      expect(cfg.replyPlaceholder, 'Reply');
      expect(cfg.replyVerb, 'Send');
    });

    test('the four new fields default to null when absent', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'note',
        'label': 'Note',
      });
      expect(cfg.composePlaceholder, isNull);
      expect(cfg.composeVerb, isNull);
      expect(cfg.replyPlaceholder, isNull);
      expect(cfg.replyVerb, isNull);
    });
  });
}
```

- [ ] **Step 5: Run the test, see it pass**

```bash
cd apps/plot && flutter test test/store/link_test.dart
```

Expected: 2 tests pass.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/store/link.dart apps/plot/test/store/link_test.dart
git commit -m "feat(store): mirror new LinkTypeConfig copy fields in Dart

Adds composePlaceholder, composeVerb, replyPlaceholder, replyVerb to the
LinkTypeConfig Dart mirror with snake_case JSON parsing.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Update `link_type_copy.dart` helpers

**Files:**
- Modify: `apps/plot/lib/util/link_type_copy.dart`
- Test: `apps/plot/test/util/link_type_copy_test.dart`

- [ ] **Step 1: Add a Plot-specific helper for NewThreadPage placeholders**

At the top of `apps/plot/lib/util/link_type_copy.dart`, add:

```dart
/// Placeholder for the NewThreadPage body editor when the target is a Plot
/// thread (no connector). Driven by the (task, shared) flags.
///
/// - !task && !shared → "Add a note"
/// - task             → "Add a task"
/// - !task && shared  → "Start a chat"
String composerHintForNewThreadPlot({required bool task, required bool shared}) {
  if (task) return 'Add a task';
  if (shared) return 'Start a chat';
  return 'Add a note';
}
```

- [ ] **Step 2: Make `composerHintForNewThread` prefer `cfg.composePlaceholder`**

Find the existing `composerHintForNewThread` function. Change its body to prefer the SDK field with derivation fallback:

```dart
String composerHintForNewThread(LinkTypeConfig? cfg, {String? connectorName}) {
  if (cfg == null) return 'Start a new thread';
  if (cfg.composePlaceholder != null && cfg.composePlaceholder!.isNotEmpty) {
    return cfg.composePlaceholder!;
  }
  final label = cfg.label.toLowerCase();
  if (connectorName != null && connectorName.isNotEmpty) {
    return 'Create a new $connectorName $label';
  }
  return 'Create a new $label';
}
```

- [ ] **Step 3: Make `composerHintForNote` prefer `cfg.replyPlaceholder`**

Find the existing `composerHintForNote` function. Update similarly:

```dart
String composerHintForNote(LinkTypeConfig? cfg) {
  if (cfg?.replyPlaceholder != null && cfg!.replyPlaceholder!.isNotEmpty) {
    return cfg.replyPlaceholder!;
  }
  final noteLabel = cfg?.noteLabel?.toLowerCase();
  if (noteLabel != null && noteLabel.isNotEmpty) {
    return 'Add a $noteLabel';
  }
  return 'Add a note';
}
```

- [ ] **Step 4: Add helpers for verbs**

Append:

```dart
/// Send-button label on NewThreadPage when targeting a connector.
String composerVerbForNewThread(LinkTypeConfig? cfg) {
  return (cfg?.composeVerb?.isNotEmpty ?? false) ? cfg!.composeVerb! : 'Create';
}

/// Send-button label in the in-thread editor.
String composerVerbForNote(LinkTypeConfig? cfg) {
  return (cfg?.replyVerb?.isNotEmpty ?? false) ? cfg!.replyVerb! : 'Send';
}
```

- [ ] **Step 5: Write tests**

Create `apps/plot/test/util/link_type_copy_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/link.dart';
import 'package:plot/util/link_type_copy.dart';

void main() {
  group('composerHintForNewThreadPlot', () {
    test('returns "Add a note" when neither task nor shared', () {
      expect(composerHintForNewThreadPlot(task: false, shared: false), 'Add a note');
    });
    test('returns "Add a task" when task is true', () {
      expect(composerHintForNewThreadPlot(task: true, shared: false), 'Add a task');
      expect(composerHintForNewThreadPlot(task: true, shared: true), 'Add a task');
    });
    test('returns "Start a chat" when shared and not task', () {
      expect(composerHintForNewThreadPlot(task: false, shared: true), 'Start a chat');
    });
  });

  group('composerHintForNewThread', () {
    test('prefers cfg.composePlaceholder when set', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'email',
        'label': 'Thread',
        'compose_placeholder': 'Send a Gmail email',
      });
      expect(composerHintForNewThread(cfg, connectorName: 'Gmail'), 'Send a Gmail email');
    });
    test('derives from label and connector name when unset', () {
      final cfg = LinkTypeConfig.fromJson({'type': 'issue', 'label': 'Issue'});
      expect(composerHintForNewThread(cfg, connectorName: 'Linear'), 'Create a new Linear issue');
    });
  });

  group('composerHintForNote', () {
    test('prefers cfg.replyPlaceholder when set', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'issue', 'label': 'Issue', 'reply_placeholder': 'Add a comment',
      });
      expect(composerHintForNote(cfg), 'Add a comment');
    });
    test('derives from noteLabel when reply_placeholder unset', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'issue', 'label': 'Issue', 'note_label': 'Comment',
      });
      expect(composerHintForNote(cfg), 'Add a comment');
    });
  });

  group('verb helpers', () {
    test('composerVerbForNewThread prefers composeVerb, defaults to "Create"', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'email', 'label': 'Thread', 'compose_verb': 'Send',
      });
      expect(composerVerbForNewThread(cfg), 'Send');
      expect(composerVerbForNewThread(null), 'Create');
    });
    test('composerVerbForNote prefers replyVerb, defaults to "Send"', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'issue', 'label': 'Issue', 'reply_verb': 'Comment',
      });
      expect(composerVerbForNote(cfg), 'Comment');
      expect(composerVerbForNote(null), 'Send');
    });
  });
}
```

- [ ] **Step 6: Run tests, see them pass**

```bash
cd apps/plot && flutter test test/util/link_type_copy_test.dart
```

Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add apps/plot/lib/util/link_type_copy.dart apps/plot/test/util/link_type_copy_test.dart
git commit -m "feat(copy): SDK-driven placeholders and verbs; new Plot helper for NewThreadPage

composerHintForNewThread / composerHintForNote now prefer the new SDK
composePlaceholder / replyPlaceholder strings, falling back to derived
defaults. Adds composerVerbForNewThread / composerVerbForNote for the
Send button label. New composerHintForNewThreadPlot(task, shared)
covers Plot's Note / Task / Chat branch.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: NewThreadPage placeholder, sticky Chat, and dynamic Send button label

**Files:**
- Modify: `apps/plot/lib/page/new_thread.dart`

- [ ] **Step 1: Add the sticky-Chat draft-local flag**

In `_NewThreadPageState` (the State class for `NewThreadPage`), add:

```dart
  bool _hadContactsThisSession = false;
```

Find the place(s) where contacts are added to the draft thread (search for `thread.contacts` mutations or `setContacts` / `addContact` handlers). After any mutation that results in a non-empty contact list, set the flag:

```dart
  void _markContactsAdded() {
    if (!_hadContactsThisSession) {
      setState(() => _hadContactsThisSession = true);
    }
  }
```

Call `_markContactsAdded()` from wherever the user adds the first contact.

- [ ] **Step 2: Compute the placeholder and verb in `build`**

In `_NewThreadPageState.build`, just before constructing `NoteEditor`, compute:

```dart
    final isPlotTarget = _selectedTwist == null;  // adapt to the existing "target is Plot" check
    final isTask = state.draftNote.isTask;  // adapt to existing task-flag accessor
    final hasContacts = state.thread.contacts.isNotEmpty;
    final shared = hasContacts || _hadContactsThisSession;

    final String hint = isPlotTarget
        ? composerHintForNewThreadPlot(task: isTask, shared: shared)
        : composerHintForNewThread(
            _selectedLinkTypeConfig,  // already computed elsewhere; reuse
            connectorName: _selectedConnectorName,  // ditto
          );

    final String sendLabel = isPlotTarget
        ? (isTask ? 'Save task' : shared ? 'Send' : 'Save')
        : composerVerbForNewThread(_selectedLinkTypeConfig);
```

Adapt the field accessors to match what already exists in `new_thread.dart`. Use `grep` first to find the precise existing names (`_selectedTwist`, `_selectedLinkTypeConfig`, `state.draftNote.tags`, etc.).

- [ ] **Step 3: Wire the hint and Send label into the editor and bottom bar**

Pass `hint: hint` to the `NoteEditor` constructor (replacing any prior literal or `composerHintForNewThread(...)` call). In `_buildNewThreadBottomBar`, replace the hard-coded "Save" / "Create" string on the Send button with `sendLabel`.

- [ ] **Step 4: Add the import**

If not already imported:

```dart
import 'package:plot/util/link_type_copy.dart';
```

- [ ] **Step 5: Run analyze on the changed file**

```bash
cd apps/plot && flutter analyze lib/page/new_thread.dart
```

Expected: No new analyzer errors.

- [ ] **Step 6: Add or update widget tests for the placeholder table**

Find or create `apps/plot/test/page/new_thread_test.dart`. Add tests that build `NewThreadPage` in each cell of the placeholder table:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
// ... project imports (Bloc providers, test harness — match existing pattern in other page tests)

void main() {
  group('NewThreadPage placeholder and Send label', () {
    testWidgets('Plot, no contacts, !task → "Add a note" + "Save"', (tester) async {
      // Pump NewThreadPage with a Plot draft, no contacts, no task tag
      // Assert: editor hint text == "Add a note"; Send button label == "Save"
    });

    testWidgets('Plot, task=true → "Add a task" + "Save task"', (tester) async {
      // Pump with task tag set; assert hint and Send label
    });

    testWidgets('Plot, with contacts → "Start a chat" + "Send"', (tester) async {
      // Pump with at least one contact; assert
    });

    testWidgets('Gmail target → composePlaceholder + composeVerb', (tester) async {
      // Pump with Gmail target selected; assert hint == "Send a Gmail email", Send == "Send"
    });

    testWidgets('Plot: removing contacts keeps Chat label sticky', (tester) async {
      // Pump with one contact, remove it, assert hint still == "Start a chat"
    });
  });
}
```

Fill in the test bodies using the existing patterns from other `apps/plot/test/page/` tests. If no harness exists, find one in `apps/plot/test/` and copy the setup (typically `pumpWidget(MaterialApp(home: BlocProvider(...)))` or the project's equivalent).

- [ ] **Step 7: Run new tests, see them pass**

```bash
cd apps/plot && flutter test test/page/new_thread_test.dart
```

Expected: 5 tests pass.

- [ ] **Step 8: Commit**

```bash
git add apps/plot/lib/page/new_thread.dart apps/plot/test/page/new_thread_test.dart
git commit -m "feat(new-thread): mode-aware placeholder and Send button; sticky Chat label

Body editor placeholder and Send-button label now reflect the active
target: Plot Note/Task/Chat (driven by (task, shared) flags) or the
connector's composePlaceholder/composeVerb. Adds a draft-local
_hadContactsThisSession flag so the Chat label persists if the user
temporarily removes all contacts mid-compose.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Add `access_groups` column, GIN index, comment, and view updates to Postgres

**Files:**
- Modify: `libs/db/schema/50-tables/25-note.sql`
- Modify: `libs/db/schema/90-user-schema/31-note.sql`
- Create: `libs/db/migrations/<timestamp>_add_note_access_groups.sql` (generated)
- (regenerated) `libs/db/src/types.ts`

- [ ] **Step 1: Verify worktree DB is ready**

```bash
cat .worktree-db 2>/dev/null && echo "OK" || bash scripts/worktree-db
```

Expected: `.worktree-db` exists with a `PORT=...` line, OR the script runs and creates it. `$DATABASE_URL` should be set (check `.claude/settings.local.json` or run `echo $DATABASE_URL` — it should point to `127.0.0.1:<port>`).

- [ ] **Step 2: Add `access_groups` to the schema**

Edit `libs/db/schema/50-tables/25-note.sql`. Locate the `access_contacts` column declaration (line 13). Add a sibling column on the next line:

```sql
    "access_contacts" uuid[],
    "access_groups" uuid[],
```

After the `COMMENT ON COLUMN "public"."note"."access_contacts"` block (around line 35–39), add:

```sql

COMMENT ON COLUMN "public"."note"."access_groups" IS 'Restricts note visibility within thread viewers via group membership, parallel to access_contacts. NULL = thread-default groups can see, array of group_ids = author + members of listed groups (subset of thread.groups). Combines with access_contacts via OR: a non-author user sees the note iff their contact ids overlap access_contacts (when non-null) OR their group ids overlap access_groups (when non-null). When both are NULL, all thread viewers see it.';

CREATE INDEX idx_note_access_groups ON "public"."note" USING gin ("access_groups")
WHERE
    access_groups IS NOT NULL;
```

- [ ] **Step 3: Update `user.note` view**

Edit `libs/db/schema/90-user-schema/31-note.sql`. In the first SELECT (visible-rows view, around lines 11–50), add `n.access_groups` to the selected columns (after `n.access_contacts` on line 24):

```sql
    n.access_contacts,
    n.access_groups,
```

Replace the visibility WHERE clause (lines 42–44):

```sql
    AND (n.access_contacts IS NULL
        OR n.created_by = tp.user_id
        OR n.access_contacts && "user".user_contact_ids(tp.user_id))
```

with:

```sql
    AND (
        n.created_by = tp.user_id
        OR (n.access_contacts IS NULL AND n.access_groups IS NULL)
        OR (n.access_contacts IS NOT NULL AND n.access_contacts && "user".user_contact_ids(tp.user_id))
        OR (n.access_groups IS NOT NULL AND n.access_groups && "user".user_group_ids(tp.user_id))
    )
```

- [ ] **Step 4: Update `user.note_redacted` view**

In the second SELECT (redacted-stub view, around lines 59–109), add a NULL placeholder for `access_groups` so the column shapes match. After the `CAST(NULL AS uuid[]) AS access_contacts,` line (line 75) add:

```sql
    CAST(NULL AS uuid[]) AS access_groups,
```

Replace the "hidden by note-level access restriction" WHERE clause (lines 98–100):

```sql
    AND (n.access_contacts IS NOT NULL
        AND n.created_by != tp.user_id
        AND NOT (COALESCE(n.access_contacts, ARRAY[]::uuid[]) && "user".user_contact_ids(tp.user_id)))
```

with:

```sql
    AND n.created_by != tp.user_id
    AND (n.access_contacts IS NOT NULL OR n.access_groups IS NOT NULL)
    AND NOT (
        (n.access_contacts IS NOT NULL AND n.access_contacts && "user".user_contact_ids(tp.user_id))
        OR (n.access_groups IS NOT NULL AND n.access_groups && "user".user_group_ids(tp.user_id))
    )
```

- [ ] **Step 5: Update `user.note_tags` view**

In the third view (around lines 117–152), replace the WHERE access check (lines 150–152):

```sql
    AND (n.access_contacts IS NULL
        OR n.created_by = ua.user_id
        OR n.access_contacts && "user".user_contact_ids(ua.user_id));
```

with:

```sql
    AND (
        n.created_by = ua.user_id
        OR (n.access_contacts IS NULL AND n.access_groups IS NULL)
        OR (n.access_contacts IS NOT NULL AND n.access_contacts && "user".user_contact_ids(ua.user_id))
        OR (n.access_groups IS NOT NULL AND n.access_groups && "user".user_group_ids(ua.user_id))
    );
```

- [ ] **Step 6: Generate the migration**

```bash
pnpm gen-migration -- add_note_access_groups
```

Expected: A new file appears in `libs/db/migrations/` named `<timestamp>_add_note_access_groups.sql` containing the column add, comment, index, and the three view replacements.

- [ ] **Step 7: Add the seq bump at the end of the migration**

Per `libs/db/AGENTS.md` ("Bump Parent `seq` on Child-Table Changes"), adding a column to a synced view requires a one-shot bump so existing rows re-sync. Open the generated migration file and append at the very end:

```sql

-- Force re-sync of all existing notes so clients pick up the new access_groups
-- column. Without this bump, rows whose seq predates the migration would never
-- re-emit through /sync/notes.
UPDATE public.note SET updated_at = now();
```

Re-hash the migrations directory so Atlas accepts the edit:

```bash
atlas migrate hash --dir file://libs/db/migrations
```

Expected: `atlas.sum` updated.

- [ ] **Step 8: Apply the migration**

```bash
pnpm apply-migrations
```

Expected: Atlas applies the new migration and `pnpm types` runs at the end (regenerating `libs/db/src/types.ts`).

- [ ] **Step 9: Verify schema sync**

```bash
pnpm diff-schema-migrations
```

Expected: No differences (schema files are now in sync with migrations).

```bash
psql "$DATABASE_URL" -c "\\d public.note" | grep -E 'access_(contacts|groups)'
```

Expected: Both columns listed.

- [ ] **Step 10: Lint the db package**

```bash
pnpm --filter @plotday/db run lint
```

Expected: No errors — `types.ts` matches the live DB.

- [ ] **Step 11: Commit**

```bash
git add libs/db/schema/50-tables/25-note.sql \
        libs/db/schema/90-user-schema/31-note.sql \
        libs/db/migrations/ libs/db/atlas.sum \
        libs/db/src/types.ts
git commit -m "feat(db): add note.access_groups column for per-note group audience

Parallels access_contacts. NULL = thread-default groups see the note;
otherwise visibility is OR-combined with access_contacts: user can see
the note if their contact ids overlap access_contacts OR their group
ids overlap access_groups. Updates user.note, user.note_redacted, and
user.note_tags views to evaluate the OR. Adds a GIN index. The
migration ends with a one-shot UPDATE to bump every note's updated_at
so existing clients re-pull and pick up the new column.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Update API visibility queries and sync write path for `access_groups`

**Files:**
- Modify: `workers/api/src/app/sync/note-reactions.ts`
- Modify: `workers/api/src/app/sync/notes.ts`
- (search broadly for other `access_contacts` reads)

- [ ] **Step 1: Find every place that reads `access_contacts`**

```bash
grep -rn 'access_contacts' workers/api/src --include='*.ts' | grep -v db-types.ts
```

Note every line that filters or computes visibility from `access_contacts`. The two known ones from the explore are `note-reactions.ts:228-230` and `notes.ts:237,251,328`.

- [ ] **Step 2: Update `note-reactions.ts` visibility filter**

Open `workers/api/src/app/sync/note-reactions.ts`. Around lines 220–235, find the SQL fragment that includes:

```sql
n.access_contacts IS NULL
OR n.access_contacts && "user".user_contact_ids(tp.user_id)
```

Replace with the OR-combined check:

```sql
n.created_by = tp.user_id
OR (n.access_contacts IS NULL AND n.access_groups IS NULL)
OR (n.access_contacts IS NOT NULL AND n.access_contacts && "user".user_contact_ids(tp.user_id))
OR (n.access_groups IS NOT NULL AND n.access_groups && "user".user_group_ids(tp.user_id))
```

Keep the surrounding SQL structure (the SELECT and any other JOINs) unchanged.

- [ ] **Step 3: Update `notes.ts` sync write path**

Open `workers/api/src/app/sync/notes.ts`. Locate the body parsing block around line 237. Add `access_groups` extraction parallel to `access_contacts`:

```ts
      bodyAccessContacts: body.access_contacts ?? null,
      bodyAccessGroups: body.access_groups ?? null,  // NEW
```

Pass `body.access_groups` through to the RPC call (the `p_access_contacts` pattern, around line 251). Add:

```ts
      p_access_groups: body.access_groups ?? null,
```

Around line 328, look for any merge/append that combines body access fields with computed defaults; add a parallel handling for `access_groups`. The Message-mode invariant (lines 30–40) applies only to `access_contacts` and need not be extended to groups — groups can be NULL on a message-mode connector (no per-message group concept on Gmail).

Adapt the actual function signatures by reading the file: the local `resolveAccessContacts` helper at line ~30 is a pure function; no parallel needed unless your audit finds analogous resolution logic for groups.

- [ ] **Step 4: Update the body Zod (or type) schema for `/sync/notes` POST**

Search for the body validation schema for the notes POST handler:

```bash
grep -nP 'access_contacts\?|access_contacts:' workers/api/src/app/sync/notes.ts
```

Find the body schema (Zod or hand-rolled type) and add `access_groups`:

```ts
  access_groups: z.array(z.string()).nullable().optional(),
```

next to `access_contacts`.

- [ ] **Step 5: Update the RPC SQL function if it exists**

If the `bodyAccessContacts` path eventually calls a Postgres function (search `libs/db/schema/60-functions/` for `upsert_note` or similar):

```bash
grep -rn 'p_access_contacts\|upsert_note\b' libs/db/schema/60-functions/ workers/api/src 2>/dev/null | head -10
```

If a function takes `p_access_contacts uuid[]`, add `p_access_groups uuid[]` and assign it to the new column. If you modify a function definition, generate a follow-up migration:

```bash
pnpm gen-migration -- add_p_access_groups_to_upsert_note
pnpm apply-migrations
```

- [ ] **Step 6: Audit for any private-note checks**

```bash
grep -rn 'isPrivate\|is_private\|access_contacts.length' workers/api/src --include='*.ts' | head -20
```

For each match: if it's checking "is this note constrained" (any non-null `access_contacts`), extend to OR with `access_groups`. If it's checking "is this the Private note shortcut" (`accessContacts == [self]`), also assert `access_groups` is null or empty.

- [ ] **Step 7: Run the API tests**

```bash
pnpm --filter @plotday/api test
```

Expected: All tests pass (existing tests still work because `access_groups` is null by default; new test added in step 8 will validate group-based visibility).

- [ ] **Step 8: Add a regression test for the OR-combined visibility**

In `workers/api/src/app/sync/notes.test.ts` (or a co-located file), add a test that:

1. Creates a thread with one contact and one group.
2. Inserts a note with `access_contacts = [otherUserContact]` and `access_groups = [groupId]`.
3. Verifies that a user who's in the group (but not in `access_contacts`) sees the note.
4. Verifies that a user who's in neither doesn't see it.

Reuse the existing test scaffolding from `notes.test.ts`. If there's no integration harness, add a minimal SQL-level test that queries `user.note` directly.

```bash
pnpm --filter @plotday/api test
```

Expected: New test passes alongside existing tests.

- [ ] **Step 9: Commit**

```bash
git add workers/api/src/app/sync/note-reactions.ts \
        workers/api/src/app/sync/notes.ts \
        workers/api/src/app/sync/notes.test.ts \
        libs/db/schema/60-functions/ libs/db/migrations/ libs/db/atlas.sum libs/db/src/types.ts
git commit -m "feat(api): OR-combined access_contacts + access_groups in note visibility

Updates per-note visibility checks across sync/notes and sync/note-reactions
to evaluate access_contacts and access_groups with OR semantics. Accepts
access_groups in the POST /sync/notes body and writes it through the upsert
RPC. Adds an integration test asserting a user who's in the access group
(but not access_contacts) can read the note.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Drift schema bump and `Note.accessGroups` field in Flutter

**Files:**
- Modify: `apps/plot/lib/store/store.dart` (`notes` table + `schemaVersion` + `onUpgrade`)
- Modify: `apps/plot/lib/store/note.dart`
- Test: `apps/plot/test/store/note_test.dart`

- [ ] **Step 1: Add the column to the Drift table**

In `apps/plot/lib/store/note.dart`, find the `Notes` table (search for `TextColumn get accessContacts`). Add a parallel column right below it:

```dart
  TextColumn get accessContacts => text().nullable().map(const ActorIdListConverter())();
  TextColumn get accessGroups => text().nullable().map(const ActorIdListConverter())();
```

Reuse `ActorIdListConverter` since group ids in this codebase are `ActorId`-shaped (UUIDs serialized the same way). If the type system requires a distinct `GroupIdListConverter`, copy the existing converter and rename — but verify first by searching `grep -nP 'class ActorIdListConverter|class GroupId' apps/plot/lib/store/`.

- [ ] **Step 2: Add the field to the `Note` model class**

In `apps/plot/lib/store/note.dart`, find the `Note` class. After `accessContacts` (line 210), add:

```dart
  final List<ActorId>? accessGroups;
```

Add it to the constructor (line 163 area):

```dart
    this.accessContacts,
    this.accessGroups,
```

Add it to the `copyWith` parameter list and body, the `fromStore` factory (line ~191), the `toStore` / `toCompanion` round-trip, and any JSON serialization. Every place that lists `accessContacts` gets a parallel `accessGroups` entry. Use `grep -nP 'accessContacts' apps/plot/lib/store/note.dart` to find them all.

Note: line 622 also has `accessContacts: accessContacts,` — add `accessGroups: accessGroups,` there too. Same pattern for line 956 (`copyWith(accessContacts: Value(...))` in the toggle private code — extend the toggle to also clear `accessGroups`):

```dart
  Note togglePrivate(ActorId actorId, bool value) {
    return copyWith(
      accessContacts: Value(value ? [actorId] : null),
      accessGroups: Value(value ? [] : null),  // NEW: clear groups when going private
    );
  }
```

(Adapt to the exact method name; line 956 was inside something — read the surrounding 10 lines to find the method signature.)

- [ ] **Step 3: Update the `isPrivate` getter**

Replace line 211:

```dart
  bool get isPrivate => accessContacts != null;
```

with:

```dart
  bool get isPrivate =>
      accessContacts != null &&
      (accessGroups == null || accessGroups!.isEmpty);
```

This preserves UI semantics: a note with `accessContacts` set BUT also `accessGroups` set isn't "Private" — it's a custom subset that includes groups.

Leave `isAuthorOnly` (line 212) alone unless the same intuition applies; for clarity, update it too:

```dart
  bool get isAuthorOnly =>
      accessContacts != null && accessContacts!.isEmpty &&
      (accessGroups == null || accessGroups!.isEmpty);
```

- [ ] **Step 4: Bump Drift `schemaVersion` and add migration step**

Open `apps/plot/lib/store/store.dart`. Find `int get schemaVersion => 349;` (line 2411). Change to:

```dart
  int get schemaVersion => 350;
```

Find `Store.migration.onUpgrade` (or the migration block). At the end of the `onUpgrade` chain, add a step:

```dart
      if (from < 350) {
        await m.addColumn(notes, notes.accessGroups);
      }
```

- [ ] **Step 5: Regenerate Drift code**

```bash
cd apps/plot && flutter pub run build_runner build --delete-conflicting-outputs
```

Expected: Build completes. `note.g.dart` (or the bundled `*.g.dart`) now includes `accessGroups`.

- [ ] **Step 6: Run flutter analyze**

```bash
cd apps/plot && flutter analyze lib/store/note.dart lib/store/store.dart
```

Expected: No new errors. Resolve any references to `Note(...)` calls that need the new `accessGroups` parameter (named, optional → defaults to null, so most call sites should still compile).

- [ ] **Step 7: Add tests for the new field and isPrivate semantics**

Create or extend `apps/plot/test/store/note_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/note.dart';
import 'package:plot/store/actor.dart';  // for ActorId — adapt path if different

void main() {
  final selfId = ActorId.fromString('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  final aliceId = ActorId.fromString('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
  final groupId = ActorId.fromString('cccccccc-cccc-cccc-cccc-cccccccccccc');

  Note buildNote({
    List<ActorId>? accessContacts,
    List<ActorId>? accessGroups,
  }) {
    // Use the minimal factory available in tests; see note.dart for the
    // canonical test-construction pattern (likely Note.empty() or similar).
    return Note(
      // ... required fields per existing Note ctor; copy the pattern from
      // other tests in this directory.
      accessContacts: accessContacts,
      accessGroups: accessGroups,
    );
  }

  group('Note.isPrivate', () {
    test('accessContacts=null, accessGroups=null → not private', () {
      expect(buildNote().isPrivate, isFalse);
    });
    test('accessContacts=[self], accessGroups=null → private', () {
      expect(buildNote(accessContacts: [selfId]).isPrivate, isTrue);
    });
    test('accessContacts=[self], accessGroups=[] → private', () {
      expect(buildNote(accessContacts: [selfId], accessGroups: []).isPrivate, isTrue);
    });
    test('accessContacts=[self], accessGroups=[groupId] → NOT private (custom subset includes group)', () {
      expect(buildNote(accessContacts: [selfId], accessGroups: [groupId]).isPrivate, isFalse);
    });
    test('accessContacts=[self, alice], accessGroups=null → NOT private (custom subset)', () {
      expect(buildNote(accessContacts: [selfId, aliceId]).isPrivate, isFalse);
    });
  });
}
```

Adapt the `Note(...)` factory to match the existing constructor signature; copy from any other `note_test.dart` if present.

- [ ] **Step 8: Run tests**

```bash
cd apps/plot && flutter test test/store/note_test.dart
```

Expected: 5 tests pass.

- [ ] **Step 9: Commit**

```bash
git add apps/plot/lib/store/note.dart \
        apps/plot/lib/store/store.dart \
        apps/plot/lib/store/note.g.dart apps/plot/lib/store/store.g.dart \
        apps/plot/test/store/note_test.dart
git commit -m "feat(store): add Note.accessGroups; refine isPrivate to require empty/null groups

Adds the Drift column and Note field parallel to accessContacts. Bumps
schemaVersion to 350 with a migration step that calls addColumn. The
isPrivate getter now requires accessGroups is null or empty so a custom
subset that includes groups is not mislabeled as Private. togglePrivate
clears accessGroups when entering private mode.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: ThreadBloc event `EditNoteRecipients`

**Files:**
- Modify: `apps/plot/lib/state/thread.dart` (or wherever `ThreadBloc` lives)

- [ ] **Step 1: Locate ThreadBloc**

```bash
grep -nP 'class ThreadBloc|class ThreadEvent|setReplyTo' apps/plot/lib/state/ apps/plot/lib/ -r | head -10
```

Find the bloc file and the existing event sealed class / mapping.

- [ ] **Step 2: Add the new event**

In the events file, add:

```dart
/// Updates the draft note's per-message recipient subset and extends the
/// thread's contacts / groups with any newly-added members from the picker.
class EditNoteRecipients extends ThreadEvent {
  /// New per-note contact subset. null = thread default.
  final List<ActorId>? accessContacts;
  /// New per-note group subset. null = thread default.
  final List<ActorId>? accessGroups;
  /// Contacts the picker added that weren't on the thread before.
  final List<ActorId> threadContactsAdded;
  /// Groups the picker added that weren't on the thread before.
  final List<ActorId> threadGroupsAdded;

  const EditNoteRecipients({
    required this.accessContacts,
    required this.accessGroups,
    this.threadContactsAdded = const [],
    this.threadGroupsAdded = const [],
  });
}
```

- [ ] **Step 3: Add the handler**

In the bloc class, add an `on<EditNoteRecipients>` mapping. Follow the existing patterns for `setReplyTo` / `startEditing` so the handler runs within the same `withUserDb` transaction style.

```dart
  Future<void> _onEditNoteRecipients(EditNoteRecipients e, Emitter<ThreadState> emit) async {
    final draft = state.draft.copyWith(
      accessContacts: Value(e.accessContacts),
      accessGroups: Value(e.accessGroups),
    );

    final newThreadContacts = e.threadContactsAdded.isEmpty
        ? state.thread.contacts
        : [...state.thread.contacts, ...e.threadContactsAdded];
    final newThreadGroups = e.threadGroupsAdded.isEmpty
        ? state.thread.groups
        : [...state.thread.groups, ...e.threadGroupsAdded];

    final newThread = state.thread.copyWith(
      contacts: newThreadContacts,
      groups: newThreadGroups,
    );

    // Persist both in one transaction so they land atomically.
    await store.transaction(() async {
      await store.notes.save(draft);
      if (e.threadContactsAdded.isNotEmpty || e.threadGroupsAdded.isNotEmpty) {
        await store.threads.save(newThread);
      }
    });

    emit(state.copyWith(draft: draft, thread: newThread));
  }
```

Adapt to the existing emit/save pattern in this bloc. Watch for the `Store.transaction` zone-capture issue documented in user memory — keep all DB calls inside the transaction synchronously.

Wire it up in the constructor or `on<T>` registration block alongside the other events.

- [ ] **Step 4: Run analyze**

```bash
cd apps/plot && flutter analyze lib/state/thread.dart
```

Expected: No new errors.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/state/thread.dart
git commit -m "feat(state): add EditNoteRecipients event to ThreadBloc

Writes the picker's per-note contact and group subsets to the draft and
atomically extends thread.contacts / thread.groups with any newly-added
recipients. One Drift transaction so the two saves can't desync.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: `NoteEditorTopBar` widget and `TopBarState` sealed class

**Files:**
- Create: `apps/plot/lib/widget/note_editor_top_bar.dart`
- Test: `apps/plot/test/widget/note_editor_top_bar_test.dart`

- [ ] **Step 1: Write the failing test first (TDD)**

Create `apps/plot/test/widget/note_editor_top_bar_test.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:plot/widget/note_editor_top_bar.dart';

void main() {
  TopBarPill pill(String id, String label, {bool isActive = false, List<String>? avatars}) {
    return TopBarPill(
      id: id,
      label: label,
      avatarSlot: avatars,
      onTap: () {},
      onAvatarsTap: avatars == null ? null : () {},
    );
  }

  Widget host(Widget child) => FTheme(
        data: FThemes.zinc.light,
        child: Directionality(textDirection: TextDirection.ltr, child: child),
      );

  group('NoteEditorTopBar — PillRowState', () {
    testWidgets('renders all pill labels', (tester) async {
      await tester.pumpWidget(host(NoteEditorTopBar(
        state: PillRowState(
          pills: [
            pill('reply', 'Reply'),
            pill('task', 'Task'),
            pill('private', 'Private note'),
          ],
          activeId: 'reply',
        ),
        onClearReply: () {},
        onCancelEdit: () {},
      )));
      expect(find.text('Reply'), findsOneWidget);
      expect(find.text('Task'), findsOneWidget);
      expect(find.text('Private note'), findsOneWidget);
    });

    testWidgets('active pill has the accent fill, others are transparent', (tester) async {
      await tester.pumpWidget(host(NoteEditorTopBar(
        state: PillRowState(
          pills: [pill('a', 'A'), pill('b', 'B')],
          activeId: 'a',
        ),
        onClearReply: () {},
        onCancelEdit: () {},
      )));
      final activeFinder = find.byKey(const Key('pill-a'));
      final inactiveFinder = find.byKey(const Key('pill-b'));
      expect(activeFinder, findsOneWidget);
      expect(inactiveFinder, findsOneWidget);
      final active = tester.widget<Container>(find.descendant(of: activeFinder, matching: find.byType(Container)).first);
      final inactive = tester.widget<Container>(find.descendant(of: inactiveFinder, matching: find.byType(Container)).first);
      expect((active.decoration as BoxDecoration).color, isNotNull);
      expect((inactive.decoration as BoxDecoration).color, isNull);
    });

    testWidgets('tapping a pill invokes its onTap', (tester) async {
      var tapped = false;
      await tester.pumpWidget(host(NoteEditorTopBar(
        state: PillRowState(
          pills: [
            TopBarPill(id: 'task', label: 'Task', onTap: () => tapped = true),
          ],
          activeId: 'reply',
        ),
        onClearReply: () {},
        onCancelEdit: () {},
      )));
      await tester.tap(find.text('Task'));
      expect(tapped, isTrue);
    });
  });

  group('NoteEditorTopBar — ReplyingState', () {
    testWidgets('renders the reply chrome with quote preview', (tester) async {
      await tester.pumpWidget(host(NoteEditorTopBar(
        state: const ReplyingState(quotePreview: 'Sounds good, ship Friday'),
        onClearReply: () {},
        onCancelEdit: () {},
      )));
      expect(find.text('Replying'), findsOneWidget);
      expect(find.text('Sounds good, ship Friday'), findsOneWidget);
    });

    testWidgets('tapping X invokes onClearReply', (tester) async {
      var cleared = false;
      await tester.pumpWidget(host(NoteEditorTopBar(
        state: const ReplyingState(quotePreview: 'q'),
        onClearReply: () => cleared = true,
        onCancelEdit: () {},
      )));
      await tester.tap(find.byKey(const Key('top-bar-clear')));
      expect(cleared, isTrue);
    });
  });

  group('NoteEditorTopBar — EditingState', () {
    testWidgets('renders the editing chrome with preview', (tester) async {
      await tester.pumpWidget(host(NoteEditorTopBar(
        state: const EditingState(quotePreview: 'Old text'),
        onClearReply: () {},
        onCancelEdit: () {},
      )));
      expect(find.text('Editing'), findsOneWidget);
      expect(find.text('Old text'), findsOneWidget);
    });

    testWidgets('tapping X invokes onCancelEdit', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(host(NoteEditorTopBar(
        state: const EditingState(quotePreview: 'q'),
        onClearReply: () {},
        onCancelEdit: () => cancelled = true,
      )));
      await tester.tap(find.byKey(const Key('top-bar-clear')));
      expect(cancelled, isTrue);
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd apps/plot && flutter test test/widget/note_editor_top_bar_test.dart
```

Expected: All tests FAIL with `Target of URI doesn't exist: 'package:plot/widget/note_editor_top_bar.dart'`.

- [ ] **Step 3: Create the widget**

Create `apps/plot/lib/widget/note_editor_top_bar.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/style/colors.dart';

/// Sealed state passed to [NoteEditorTopBar]. Exactly one variant is rendered
/// at a time. `PillRowState` is the default; reply / edit takeovers are
/// exclusive and replace the pill row.
sealed class TopBarState {
  const TopBarState();
}

/// Default: a horizontal row of [TopBarPill]s with one active. Size always ≥ 1.
class PillRowState extends TopBarState {
  final List<TopBarPill> pills;
  final String activeId;
  const PillRowState({required this.pills, required this.activeId});
}

/// Loud accent chrome shown when the user is replying to a specific note in
/// the feed. Excludes the pill row while active.
class ReplyingState extends TopBarState {
  final String quotePreview;
  const ReplyingState({required this.quotePreview});
}

/// Loud accent chrome shown when the user is editing an existing note.
class EditingState extends TopBarState {
  final String quotePreview;
  const EditingState({required this.quotePreview});
}

class TopBarPill {
  final String id;
  final String label;
  final List<String>? avatarSlot;
  final VoidCallback onTap;
  final VoidCallback? onAvatarsTap;

  const TopBarPill({
    required this.id,
    required this.label,
    this.avatarSlot,
    required this.onTap,
    this.onAvatarsTap,
  });
}

/// Top region of the NoteEditor. Renders one of three states; the parent
/// computes the state from thread + draft context.
class NoteEditorTopBar extends StatelessWidget {
  final TopBarState state;
  final VoidCallback onClearReply;
  final VoidCallback onCancelEdit;

  const NoteEditorTopBar({
    super.key,
    required this.state,
    required this.onClearReply,
    required this.onCancelEdit,
  });

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      PillRowState s => _buildPillRow(context, s),
      ReplyingState s => _buildTakeover(
          context,
          icon: FontAwesomeIcons.reply,
          label: 'Replying',
          preview: s.quotePreview,
          onClear: onClearReply,
        ),
      EditingState s => _buildTakeover(
          context,
          icon: FontAwesomeIcons.penToSquare,
          label: 'Editing',
          preview: s.quotePreview,
          onClear: onCancelEdit,
        ),
    };
  }

  Widget _buildPillRow(BuildContext context, PillRowState state) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: state.pills
            .map((p) => _Pill(pill: p, isActive: p.id == state.activeId))
            .toList(),
      ),
    );
  }

  Widget _buildTakeover(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String preview,
    required VoidCallback onClear,
  }) {
    final accent = context.colour.colours.accentBackground;
    final accentBorder = context.colour.colours.borderFromTheme(0);  // adapt to actual API
    final accentFg = context.colour.colours.accentForeground;
    return Container(
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        border: Border(bottom: BorderSide(color: accent.withValues(alpha: 0.35))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 11, color: accentFg.withValues(alpha: 0.8)),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontWeight: FontWeight.w600, color: accentFg)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: accentFg.withValues(alpha: 0.7)),
            ),
          ),
          GestureDetector(
            key: const Key('top-bar-clear'),
            onTap: onClear,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(FontAwesomeIcons.xmark, size: 12, color: accentFg.withValues(alpha: 0.7)),
            ),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final TopBarPill pill;
  final bool isActive;
  const _Pill({required this.pill, required this.isActive});

  @override
  Widget build(BuildContext context) {
    final colours = context.colour.colours;
    final activeBg = colours.accentBackground;  // matches sidebar selection fill
    final activeFg = colours.accentForeground;  // matches sidebar selection fg
    final restFg = context.colour.muted;

    final container = Container(
      decoration: BoxDecoration(
        color: isActive ? activeBg : null,
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            pill.label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: isActive ? activeFg : restFg,
            ),
          ),
          if (pill.avatarSlot != null) ...[
            const SizedBox(width: 6),
            GestureDetector(
              onTap: pill.onAvatarsTap,
              child: _AvatarStrip(actorIds: pill.avatarSlot!),
            ),
          ],
        ],
      ),
    );

    return Padding(
      key: Key('pill-${pill.id}'),
      padding: const EdgeInsets.only(right: 4),
      child: GestureDetector(onTap: pill.onTap, child: container),
    );
  }
}

class _AvatarStrip extends StatelessWidget {
  final List<String> actorIds;
  const _AvatarStrip({required this.actorIds});

  @override
  Widget build(BuildContext context) {
    // Minimal placeholder rendering — real avatars come from the existing
    // avatar widget in apps/plot/lib/widget/. Replace this with the real
    // widget once wired up by the parent. The test only checks presence.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: actorIds.take(3).map((_) {
        return Container(
          width: 16,
          height: 16,
          margin: const EdgeInsets.only(left: -4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFFCCCCCC),
          ),
        );
      }).toList(),
    );
  }
}
```

Note: this uses the sidebar's `accentBackground` / `accentForeground` for the active pill, matching the spec. The exact API for `context.colour.colours.accentBackground` and `accentForeground` should match what `style/sidebar.dart` uses today — `grep -nP 'accentBackground|accentForeground' apps/plot/lib/style/colors.dart` to verify the field names.

- [ ] **Step 4: Run tests, see them pass**

```bash
cd apps/plot && flutter test test/widget/note_editor_top_bar_test.dart
```

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/widget/note_editor_top_bar.dart apps/plot/test/widget/note_editor_top_bar_test.dart
git commit -m "feat(widget): NoteEditorTopBar with PillRow / Replying / Editing states

New top region of the NoteEditor. Pure-presentation widget: parent computes
TopBarState from thread + draft context and passes onClearReply /
onCancelEdit callbacks. Active pill uses the sidebar's accent fill;
takeover states use the existing loud reply / edit chrome.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: `RecipientPickerModal`

**Files:**
- Create: `apps/plot/lib/widget/recipient_picker_modal.dart`
- Test: `apps/plot/test/widget/recipient_picker_modal_test.dart`

- [ ] **Step 1: Read existing FormModal patterns**

```bash
grep -nP 'class.*FormModal|extends FormModal' apps/plot/lib/widget/*.dart | head -10
```

Pick a representative FormModal usage (likely `select_modal.dart` or similar) and read it to learn the project conventions for: keyboard nav, FormItem subclassing, `.run(context)` invocation, return shape via `Modal.pop`.

- [ ] **Step 2: Write the failing tests first**

Create `apps/plot/test/widget/recipient_picker_modal_test.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:plot/widget/recipient_picker_modal.dart';

void main() {
  final self = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  final alice = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  final bob = 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  final groupX = 'dddddddd-dddd-dddd-dddd-dddddddddddd';

  group('RecipientPickerResult', () {
    test('all thread contacts checked → accessContacts is null', () {
      final r = RecipientPickerResult.fromSelection(
        threadContacts: [self, alice, bob],
        threadGroups: [groupX],
        selectedContacts: {self, alice, bob},
        selectedGroups: {groupX},
        addedContacts: [],
        addedGroups: [],
        self: self,
      );
      expect(r.accessContacts, isNull);
      expect(r.accessGroups, isNull);
    });

    test('subset of contacts → explicit list including self', () {
      final r = RecipientPickerResult.fromSelection(
        threadContacts: [self, alice, bob],
        threadGroups: [],
        selectedContacts: {self, alice},
        selectedGroups: {},
        addedContacts: [],
        addedGroups: [],
        self: self,
      );
      expect(r.accessContacts, equals([self, alice]));
    });

    test('Just me (private) → accessContacts=[self], accessGroups=[]', () {
      final r = RecipientPickerResult.justMe(self: self);
      expect(r.accessContacts, equals([self]));
      expect(r.accessGroups, equals([]));
    });

    test('Reply to original → accessContacts=[self, originalAuthor], accessGroups=[]', () {
      final r = RecipientPickerResult.replyToOriginal(self: self, originalAuthor: alice);
      expect(r.accessContacts, equals([self, alice]));
      expect(r.accessGroups, equals([]));
    });

    test('added contact is included in accessContacts AND threadContactsAdded', () {
      final r = RecipientPickerResult.fromSelection(
        threadContacts: [self, alice],
        threadGroups: [],
        selectedContacts: {self, alice, bob},  // bob was added
        selectedGroups: {},
        addedContacts: [bob],
        addedGroups: [],
        self: self,
      );
      expect(r.accessContacts, contains(bob));
      expect(r.threadContactsAdded, equals([bob]));
    });
  });
}
```

- [ ] **Step 3: Run tests, see them fail**

```bash
cd apps/plot && flutter test test/widget/recipient_picker_modal_test.dart
```

Expected: Tests FAIL — `RecipientPickerResult` doesn't exist yet.

- [ ] **Step 4: Implement the modal**

Create `apps/plot/lib/widget/recipient_picker_modal.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/widget/modal.dart';  // adapt to actual path
import 'package:plot/widget/form_modal.dart';  // adapt to actual path

/// Result of the picker: the new per-note subsets plus any audience members
/// the picker added to the thread.
class RecipientPickerResult {
  final List<String>? accessContacts;
  final List<String>? accessGroups;
  final List<String> threadContactsAdded;
  final List<String> threadGroupsAdded;

  const RecipientPickerResult({
    required this.accessContacts,
    required this.accessGroups,
    this.threadContactsAdded = const [],
    this.threadGroupsAdded = const [],
  });

  /// Build a result from the picker's checkbox state.
  factory RecipientPickerResult.fromSelection({
    required List<String> threadContacts,
    required List<String> threadGroups,
    required Set<String> selectedContacts,
    required Set<String> selectedGroups,
    required List<String> addedContacts,
    required List<String> addedGroups,
    required String self,
  }) {
    final allContactsSelected = threadContacts.toSet().difference(selectedContacts).isEmpty
        && addedContacts.isEmpty;
    final allGroupsSelected = threadGroups.toSet().difference(selectedGroups).isEmpty
        && addedGroups.isEmpty;
    return RecipientPickerResult(
      accessContacts: allContactsSelected
          ? null
          : [self, ...selectedContacts.where((c) => c != self)],
      accessGroups: allGroupsSelected ? null : selectedGroups.toList(),
      threadContactsAdded: addedContacts,
      threadGroupsAdded: addedGroups,
    );
  }

  factory RecipientPickerResult.justMe({required String self}) =>
      RecipientPickerResult(accessContacts: [self], accessGroups: const []);

  factory RecipientPickerResult.replyToOriginal({
    required String self,
    required String originalAuthor,
  }) =>
      RecipientPickerResult(
        accessContacts: [self, originalAuthor],
        accessGroups: const [],
      );
}

/// Modal for picking the per-note audience. Lists thread contacts + thread
/// groups (pre-checked), plus an Add search field. Returns a
/// [RecipientPickerResult] via `Modal.pop`.
class RecipientPickerModal {
  final List<String> threadContacts;
  final List<String> threadGroups;
  final List<String> initialContactSelection;  // current draft.accessContacts ?? threadContacts
  final List<String> initialGroupSelection;
  final String self;
  final String? originalAuthor;

  const RecipientPickerModal({
    required this.threadContacts,
    required this.threadGroups,
    required this.initialContactSelection,
    required this.initialGroupSelection,
    required this.self,
    this.originalAuthor,
  });

  Future<RecipientPickerResult?> run(BuildContext context) async {
    // Implemented in Step 6 below — sketched here as a stub so the unit
    // tests on RecipientPickerResult.fromSelection / .justMe / .replyToOriginal
    // can run and pass without depending on the rendering layer.
    throw UnimplementedError('See Step 6: wire FormModal');
  }
}
```

The `run(context)` body needs to be filled in against the actual `FormModal` / `Modal` API. The pure data layer (`RecipientPickerResult.fromSelection` and friends) is tested above; the rendering layer is exercised in integration tests once `note_editor.dart` wires it up.

- [ ] **Step 5: Run the result tests, see them pass**

```bash
cd apps/plot && flutter test test/widget/recipient_picker_modal_test.dart
```

Expected: All 5 tests pass.

- [ ] **Step 6: Implement the actual modal `run()`**

Open an existing FormModal-using widget (run `grep -rn 'FormModal(' apps/plot/lib/widget/ apps/plot/lib/page/ | head -5` and pick one with checkbox or multi-select content). Mirror its structure for the picker.

If FormModal doesn't already have a "checkbox list" FormItem, add a new FormItem subclass — see the canonical extension pattern in `apps/plot/lib/widget/form_scheduler.dart` (per `apps/plot/AGENTS.md` modal convention: "extend the framework rather than dropping to a raw Modal + ad-hoc widgets"). The new FormItem renders the contacts list, groups list, and the Add search field.

Once that's in place, replace the stub `run()` with:

```dart
  Future<RecipientPickerResult?> run(BuildContext context) async {
    final selectedContacts = <String>{...initialContactSelection};
    final selectedGroups = <String>{...initialGroupSelection};
    final addedContacts = <String>[];
    final addedGroups = <String>[];

    final result = await FormModal<RecipientPickerResult>(
      title: 'Choose recipients',
      items: [
        RecipientCheckboxListItem(
          contacts: threadContacts,
          groups: threadGroups,
          selectedContacts: selectedContacts,
          selectedGroups: selectedGroups,
          self: self,
        ),
        RecipientSearchAddItem(
          excludeContacts: {...threadContacts},
          excludeGroups: {...threadGroups},
          onContactAdded: (c) {
            addedContacts.add(c);
            selectedContacts.add(c);
          },
          onGroupAdded: (g) {
            addedGroups.add(g);
            selectedGroups.add(g);
          },
        ),
        RecipientQuickActionItem(
          self: self,
          originalAuthor: originalAuthor,
          onJustMe: () => Modal.pop(context, Value(RecipientPickerResult.justMe(self: self))),
          onReplyToOriginal: originalAuthor == null
              ? null
              : () => Modal.pop(context, Value(RecipientPickerResult.replyToOriginal(
                    self: self,
                    originalAuthor: originalAuthor!,
                  ))),
        ),
      ],
      onSubmit: () => RecipientPickerResult.fromSelection(
        threadContacts: threadContacts,
        threadGroups: threadGroups,
        selectedContacts: selectedContacts,
        selectedGroups: selectedGroups,
        addedContacts: addedContacts,
        addedGroups: addedGroups,
        self: self,
      ),
    ).run(context);
    return result;
  }
```

`RecipientCheckboxListItem`, `RecipientSearchAddItem`, `RecipientQuickActionItem` are the new `FormItem` subclasses. Define them in the same file (or in a `recipient_picker_items.dart` neighbor). Their constructors receive the lists and callbacks; their `build()` methods emit forui `FCheckbox` rows, an `FInput` with a typeahead suggestion list filtered by `excludeContacts` / `excludeGroups`, and `FButton` quick actions respectively. Match the keyboard semantics (Tab order, Enter to confirm, Esc to cancel) by following the same FormItem hooks `FormScheduler` uses.

- [ ] **Step 7: Run analyze**

```bash
cd apps/plot && flutter analyze lib/widget/recipient_picker_modal.dart
```

Expected: No errors.

- [ ] **Step 8: Commit**

```bash
git add apps/plot/lib/widget/recipient_picker_modal.dart apps/plot/test/widget/recipient_picker_modal_test.dart
git commit -m "feat(widget): RecipientPickerModal for per-note audience editing

Lists thread contacts + groups (pre-checked). Adds a search field for new
audience members which write through to thread.contacts / thread.groups
alongside the per-note subset. Quick actions: Just me (private), Reply to
original. RecipientPickerResult is a value type with pure factory helpers
that compute null (thread default) when every thread member stays selected.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Integrate `NoteEditorTopBar` into `NoteEditor` and strip the bottom-bar mode toggles

**Files:**
- Modify: `apps/plot/lib/widget/note_editor.dart`
- Modify: `apps/plot/lib/page/thread.dart` (pass picker bloc handler)

- [ ] **Step 1: Add `_computeTopBarState` to `_NoteEditorState`**

In `apps/plot/lib/widget/note_editor.dart`, inside `_NoteEditorState`, add a method:

```dart
  TopBarState _computeTopBarState({
    required ThreadState threadState,
    required LinkTypeConfig? linkConfig,
  }) {
    final replyTo = threadState.replyTo;
    if (replyTo != null) {
      return ReplyingState(quotePreview: _previewOf(replyTo.content));
    }
    final editingNote = threadState.editingNote;
    if (editingNote != null) {
      return EditingState(quotePreview: _previewOf(editingNote.content));
    }
    return PillRowState(
      pills: _buildPills(threadState: threadState, linkConfig: linkConfig),
      activeId: _activePillId(threadState, linkConfig),
    );
  }

  String _previewOf(String? content) {
    if (content == null || content.isEmpty) return '';
    return content.length <= 60 ? content : '${content.substring(0, 60)}…';
  }
```

- [ ] **Step 2: Implement `_buildPills`**

Add to `_NoteEditorState`:

```dart
  List<TopBarPill> _buildPills({
    required ThreadState threadState,
    required LinkTypeConfig? linkConfig,
  }) {
    final thread = threadState.thread;
    final draft = widget.draft;
    final self = Base.actorId;
    final isPlotThread = linkConfig == null;
    final hasSharing = thread.contacts.isNotEmpty || thread.groups.isNotEmpty;
    final isTask = draft.tags.containsKey(Tag.task);
    final isPrivate = draft.isPrivate;

    final pills = <TopBarPill>[];

    if (isPlotThread) {
      if (!hasSharing) {
        // Unshared Plot: Note · Task
        pills.add(TopBarPill(
          id: 'note',
          label: 'Note',
          onTap: () => _activatePlotNote(),
        ));
        pills.add(TopBarPill(
          id: 'task',
          label: 'Task',
          onTap: () => _activatePlotTask(),
        ));
      } else {
        // Shared Plot: Reply to [avatars] · (Reply to original) · Task · Private
        final replyAvatars = _replyAllAvatars(thread, self);
        pills.add(TopBarPill(
          id: 'reply',
          label: 'Reply',
          avatarSlot: replyAvatars,
          onTap: () => _activatePlotReply(),
          onAvatarsTap: () => _openRecipientPicker(),
        ));
        final orig = _originalAuthorIfDistinct(thread, self);
        if (orig != null) {
          pills.add(TopBarPill(
            id: 'replyOriginal',
            label: 'Reply to ${_displayName(orig)}',
            avatarSlot: [orig.value],
            onTap: () => _activateReplyToOriginal(orig),
          ));
        }
        pills.add(TopBarPill(id: 'task', label: 'Task', onTap: _activatePlotTask));
        pills.add(TopBarPill(id: 'private', label: 'Private note', onTap: _activatePrivate));
      }
      return pills;
    }

    // Connector
    final sharingModel = linkConfig.sharingModel;
    if (sharingModel == null) {
      // Truly-private connector: single static mode pill, no Private option.
      pills.add(TopBarPill(
        id: 'note',
        label: linkConfig.noteLabel ?? 'Note',
        onTap: () {},  // no-op, only mode available
      ));
      return pills;
    }
    if (sharingModel == 'message') {
      final replyAvatars = _replyAllAvatars(thread, self);
      pills.add(TopBarPill(
        id: 'reply',
        label: linkConfig.noteLabel ?? 'Reply',
        avatarSlot: replyAvatars,
        onTap: () => _activateConnectorReply(),
        onAvatarsTap: () => _openRecipientPicker(),
      ));
      final orig = _originalAuthorIfDistinct(thread, self);
      if (orig != null) {
        pills.add(TopBarPill(
          id: 'replyOriginal',
          label: 'Reply to ${_displayName(orig)}',
          avatarSlot: [orig.value],
          onTap: () => _activateReplyToOriginal(orig),
        ));
      }
      pills.add(TopBarPill(id: 'private', label: 'Private note', onTap: _activatePrivate));
      return pills;
    }
    // sharingModel == 'channel' or 'thread': just the noteLabel pill + Private
    pills.add(TopBarPill(
      id: 'comment',
      label: linkConfig.noteLabel ?? 'Comment',
      onTap: () => _activateConnectorReply(),
    ));
    pills.add(TopBarPill(id: 'private', label: 'Private note', onTap: _activatePrivate));
    return pills;
  }
```

Helpers (also added to `_NoteEditorState`):

```dart
  /// Returns UUID strings (TopBarPill.avatarSlot is List<String>?) for the
  /// "reply all" default audience. Groups are appended as their UUIDs and
  /// rendered as group-icon avatars; contacts as individual avatars.
  List<String> _replyAllAvatars(Thread thread, ActorId self) {
    return [
      ...thread.contacts.where((c) => c != self).map((c) => c.value),
      ...thread.groups.map((g) => g.value),
    ];
  }

  ActorId? _originalAuthorIfDistinct(Thread thread, ActorId self) {
    final author = thread.createdBy;  // adapt to actual field
    final otherCount = thread.contacts.where((c) => c != self).length;
    if (author == self) return null;
    if (otherCount < 2) return null;  // reply-all == reply-to-original when ≤ 1 other
    return author;
  }

  String _displayName(ActorId id) {
    // Use existing contact-name lookup from the store/bloc.
    return store.contacts.nameFor(id) ?? 'them';
  }

  String _activePillId(ThreadState s, LinkTypeConfig? cfg) {
    final draft = widget.draft;
    if (draft.isPrivate) return 'private';
    if (draft.tags.containsKey(Tag.task)) return 'task';
    final isPlotThread = cfg == null;
    final hasSharing = s.thread.contacts.isNotEmpty || s.thread.groups.isNotEmpty;
    if (isPlotThread) {
      return hasSharing ? 'reply' : 'note';
    }
    if (cfg.sharingModel == null) return 'note';
    if (cfg.sharingModel == 'message') return 'reply';
    return 'comment';
  }
```

Add the activate-* handlers (each writes the appropriate draft state and dispatches a save):

```dart
  void _activatePlotNote() {
    threadBloc.add(UpdateDraft(
      tags: removeTag(widget.draft.tags, Tag.task),
      accessContacts: const Value(null),
      accessGroups: const Value(null),
    ));
  }
  void _activatePlotTask() {
    threadBloc.add(UpdateDraft(tags: addTag(widget.draft.tags, Tag.task, Base.actorId)));
  }
  void _activatePlotReply() {
    threadBloc.add(UpdateDraft(
      tags: removeTag(widget.draft.tags, Tag.task),
      accessContacts: const Value(null),
      accessGroups: const Value(null),
    ));
  }
  void _activateReplyToOriginal(ActorId original) {
    threadBloc.add(EditNoteRecipients(
      accessContacts: [Base.actorId, original],
      accessGroups: const [],
    ));
  }
  void _activatePrivate() {
    threadBloc.add(EditNoteRecipients(
      accessContacts: [Base.actorId],
      accessGroups: const [],
    ));
  }
  void _activateConnectorReply() {
    threadBloc.add(UpdateDraft(
      accessContacts: const Value(null),
      accessGroups: const Value(null),
    ));
  }

  Future<void> _openRecipientPicker() async {
    final s = threadBloc.state;
    final draft = widget.draft;
    final picker = RecipientPickerModal(
      threadContacts: s.thread.contacts.map((c) => c.value).toList(),
      threadGroups: s.thread.groups.map((g) => g.value).toList(),
      initialContactSelection: (draft.accessContacts ?? s.thread.contacts).map((c) => c.value).toList(),
      initialGroupSelection: (draft.accessGroups ?? s.thread.groups).map((g) => g.value).toList(),
      self: Base.actorId.value,
      originalAuthor: _originalAuthorIfDistinct(s.thread, Base.actorId)?.value,
    );
    final result = await picker.run(context);
    if (result == null) return;
    threadBloc.add(EditNoteRecipients(
      accessContacts: result.accessContacts?.map(ActorId.fromString).toList(),
      accessGroups: result.accessGroups?.map(ActorId.fromString).toList(),
      threadContactsAdded: result.threadContactsAdded.map(ActorId.fromString).toList(),
      threadGroupsAdded: result.threadGroupsAdded.map(ActorId.fromString).toList(),
    ));
  }
```

Helper names (`UpdateDraft`, `addTag`, `removeTag`, `threadBloc`) need to be adapted to what already exists in this file. Use grep to find the actual draft-update event name.

- [ ] **Step 3: Replace `_buildNoteIndicators` with the new top bar**

Find the call site of `_buildNoteIndicators()` and replace it:

```dart
        NoteEditorTopBar(
          state: _computeTopBarState(
            threadState: threadBloc.state,
            linkConfig: threadBloc.state.primaryLinkTypeConfig,
          ),
          onClearReply: () => threadBloc.setReplyTo(null),
          onCancelEdit: () => threadBloc.cancelEditing(),
        ),
```

Delete the now-unused `_buildNoteIndicators`, `_buildReplyIndicatorContent`, `_buildEditingIndicatorContent` methods (they're absorbed into `NoteEditorTopBar`).

- [ ] **Step 4: Strip Task and Private buttons from the bottom bar**

In `_buildNoteBottomBar()`, find the `ToggleSelfTask` and `ToggleNoteTag(Tag.private)` buttons and remove them entirely along with their wrappers. Keep `AddLink`, `AttachFile`, take-photo (mobile), and the twist toggle button.

- [ ] **Step 5: Make the Save button label dynamic**

Find the bottom-bar Save button (search for `'Save'` literal). Replace its `child` with a `Text(_sendLabel)`-style call where `_sendLabel` is computed from the active pill:

```dart
  String get _sendLabel {
    final s = threadBloc.state;
    final cfg = s.primaryLinkTypeConfig;
    final pillId = _activePillId(s, cfg);
    return switch (pillId) {
      'note' => 'Save',
      'task' => 'Save task',
      'reply' => cfg == null ? 'Send' : composerVerbForNote(cfg),
      'replyOriginal' => 'Send',
      'comment' => composerVerbForNote(cfg),
      'private' => 'Save',
      _ => 'Send',
    };
  }
```

- [ ] **Step 6: Make the placeholder dynamic**

Find the placeholder logic (around lines 530–543, the existing `composerHintForEditNote(cfg)` / `composerHintForNote(cfg)` branch). Replace it:

```dart
  String _resolvePlaceholder() {
    final s = threadBloc.state;
    final cfg = s.primaryLinkTypeConfig;
    if (s.editingNote != null) return composerHintForEditNote(cfg);
    if (s.replyTo != null) return composerHintForNote(cfg);  // existing reply-quote hint
    final pillId = _activePillId(s, cfg);
    return switch (pillId) {
      'note' => 'Add a note',
      'task' => 'Add a task',
      'reply' => cfg == null ? 'Reply' : (cfg.replyPlaceholder ?? composerHintForNote(cfg)),
      'replyOriginal' => 'Reply',
      'comment' => composerHintForNote(cfg),
      'private' => 'Add a private note',
      _ => composerHintForNote(cfg),
    };
  }
```

Use `_resolvePlaceholder()` in the SuperEditor placeholder builder.

- [ ] **Step 7: Run analyze on the changed file**

```bash
cd apps/plot && flutter analyze lib/widget/note_editor.dart
```

Expected: No new errors.

- [ ] **Step 8: Update existing note_editor tests**

```bash
ls apps/plot/test/widget/note_editor_test.dart 2>/dev/null || \
  grep -rln 'note_editor' apps/plot/test 2>/dev/null
```

In the existing tests, remove any assertions that the bottom-bar Task or Private buttons render (they're gone). Add assertions that:

- The top bar renders with the expected pill labels in each context (unshared Plot, shared Plot, Gmail, Linear).
- The Send button shows the label appropriate for the active pill.
- The placeholder text matches the active-pill table.

These are smoke tests; the deep coverage lives in `note_editor_top_bar_test.dart` from Task 10.

- [ ] **Step 9: Run all editor-related tests**

```bash
cd apps/plot && flutter test test/widget/note_editor_top_bar_test.dart test/widget/recipient_picker_modal_test.dart
ls apps/plot/test/widget/note_editor_test.dart >/dev/null 2>&1 && \
  cd apps/plot && flutter test test/widget/note_editor_test.dart
```

Expected: All tests pass.

- [ ] **Step 10: Commit**

```bash
git add apps/plot/lib/widget/note_editor.dart apps/plot/lib/page/thread.dart apps/plot/test/widget/
git commit -m "feat(note-editor): move mode signifiers to top pill bar; dynamic Send and placeholder

Replaces the bottom-bar mix of mode toggles (Task, Private) and content
actions with a top NoteEditorTopBar pill row. The bottom bar keeps content
affordances (link, attach, photo, twist toggle) plus a Send button whose
label is computed from the active pill. Placeholder text follows the
active-pill table from the spec. Reply-to-note and edit takeovers continue
to replace the pill row entirely with the existing loud accent chrome.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: Constrain Gmail outbound recipients by per-note `accessContacts`

**Files:**
- Modify: `public/connectors/gmail/src/gmail.ts` (the send-email code path)

- [ ] **Step 1: Find Gmail's outbound send path**

```bash
grep -nP 'sendMessage|to:|raw:.*base64|gmail.users.messages.send' public/connectors/gmail/src/*.ts | head -15
```

Locate the function that builds the outgoing email's To/Cc/Bcc headers from thread contacts.

- [ ] **Step 2: Constrain by `note.accessContacts`**

In the send function, take the note (or note-payload) as input and compute the recipient list:

```ts
function recipientsFor(note: NotePayload, thread: ThreadPayload, self: ContactId): ContactId[] {
  if (note.access_contacts == null) {
    // Thread default: everyone on the thread minus self
    return thread.contacts.filter((c) => c !== self);
  }
  // Per-note subset: those listed, minus self (self is the sender)
  return note.access_contacts.filter((c) => c !== self);
}
```

Replace the existing thread-contacts iteration in the send code with this helper, intersected with the existing contact-role mapping (To / Cc / Bcc). Self is always the sender; never include it as a recipient.

- [ ] **Step 3: Add unit test**

In `public/connectors/gmail/src/gmail.test.ts` (create if needed), add:

```ts
import { describe, expect, it } from "vitest";
import { recipientsFor } from "./gmail";  // export it from gmail.ts if not already

describe("recipientsFor", () => {
  const self = "self-id";
  const alice = "alice-id";
  const bob = "bob-id";

  it("uses thread.contacts when access_contacts is null", () => {
    expect(recipientsFor(
      { access_contacts: null },
      { contacts: [self, alice, bob] },
      self,
    )).toEqual([alice, bob]);
  });

  it("uses access_contacts when set, dropping self", () => {
    expect(recipientsFor(
      { access_contacts: [self, alice] },
      { contacts: [self, alice, bob] },
      self,
    )).toEqual([alice]);
  });
});
```

- [ ] **Step 4: Run tests**

```bash
pnpm --filter @plot-connectors/gmail test
```

Expected: Tests pass.

- [ ] **Step 5: Commit**

```bash
git add public/connectors/gmail/src/gmail.ts public/connectors/gmail/src/gmail.test.ts
git commit -m "feat(gmail): constrain outbound recipients by per-note access_contacts

When a note has access_contacts set, the outgoing email is sent only to the
listed contacts (minus self, the sender). When access_contacts is null,
behavior is unchanged: all thread contacts receive the email.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 14: Documentation

**Files:**
- Modify: `docs/updates.md`
- Modify: `docs/features.md`

- [ ] **Step 1: Add the user-facing update**

Open `docs/updates.md`. Insert a single bullet at the very top section (per the project's convention of newest-first):

```markdown
- Pick recipients per message: tap the avatars in the new note bar to choose who sees a reply (now including any groups on the thread), or use the Private note button to keep it to yourself. The new bar also shows what mode you're in — Note, Task, Chat, Reply, or Comment — and the Send button label follows.
```

- [ ] **Step 2: Update features.md**

Open `docs/features.md`. Add (or extend) the note-composition section:

```markdown
### Composing notes

Plot threads can be created as a **Note** (private to you), a **Task** (first
note tagged for follow-up), or a **Chat** (shared with one or more contacts).
The body editor's placeholder reflects which one you're creating.

Inside a thread, the editor's top bar shows the active **mode** as a pill:

- **Plot threads (unshared)** — Note · Task
- **Plot threads (shared)** — Reply · Task · Private note, plus a one-click
  "Reply to {original author}" shortcut when there are 3+ people on the thread.
- **Gmail-style threads** — Reply · Private note. Tap the avatars on Reply to
  choose who receives a specific message (per-message recipient picker).
- **Linear-style channels** — Comment · Private note.
- **Personal connectors** (Google Keep–style) — just the mode pill (no Private
  needed because the connector is already personal).

Replying to a specific note from the feed replaces the pill row with a
"Replying to: …" chrome; clicking the X returns to the pill row.
```

- [ ] **Step 3: Commit**

```bash
git add docs/updates.md docs/features.md
git commit -m "docs: thread note types and per-message recipient picker

Adds a user-facing update bullet and extends features.md with the new
composing-notes section.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 15: End-to-end verification with `flutter analyze` and the full test suite

- [ ] **Step 1: Run repo-wide analyze for the Flutter app**

```bash
cd apps/plot && flutter analyze
```

Expected: No new analyzer errors introduced by any task in this plan.

- [ ] **Step 2: Run the Flutter test suite**

```bash
cd apps/plot && flutter test
```

Expected: All tests pass. (Some tests may need updating if they assert removed bottom-bar buttons or old placeholder strings. Update them in this step to match the new behavior.)

- [ ] **Step 3: Run the API test suite**

```bash
pnpm --filter @plotday/api test
```

Expected: All tests pass.

- [ ] **Step 4: Verify schema sync one more time**

```bash
pnpm diff-schema-migrations
pnpm --filter @plotday/db run lint
```

Expected: No differences; lint passes.

- [ ] **Step 5: Smoke test the app via the run-app skill**

Invoke the `run-app` skill from this repo's `.agents/skills/`. Manual checks:

1. **NewThreadPage placeholder cycle**: open NewThreadPage with Plot target, no contacts → "Add a note". Toggle Task → "Add a task". Add a contact → "Start a chat". Remove the contact → still "Start a chat" (sticky).
2. **NewThreadPage Send label**: matches the placeholder mode ("Save" / "Save task" / "Send").
3. **ThreadPage on unshared Plot thread**: pill row shows Note · Task; default Note is active.
4. **ThreadPage on shared Plot thread**: pill row shows Reply · Task · Private note; "Reply to {name}" appears with 3+ participants.
5. **Tap "Private note" pill**: Send button label becomes "Save"; placeholder becomes "Add a private note".
6. **Tap a Reply pill's avatars**: RecipientPickerModal opens. Deselect a contact, confirm. Pill avatars update.
7. **Add a new contact via the modal's search**: it joins the thread (visible in thread header) AND the per-note subset.
8. **Click "Reply" on a feed note**: pill row hides, "Replying" takeover shows the quoted preview. Click X — pill row returns.
9. **Reply to a specific note**: send works, the new note is correctly attributed and quoted.

Document any defects found.

- [ ] **Step 6: Final commit (if any test or analyze fixes were needed)**

```bash
git status
# If non-empty:
git add -A
git commit -m "test: fix-ups from full-suite run

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Out of scope (do not implement here)

- Slack-specific "reply in thread vs send to channel" mode. (Future SDK design needed.)
- Persisting per-user "always reply privately on Linear" intent across sessions.
- Restyling the Replying / Editing takeover chrome (kept as-is).
- Per-group-member picking (groups are treated as a single recipient slot for now).
- Adding NewThreadPage's own pill bar (intentionally placeholder-only).
