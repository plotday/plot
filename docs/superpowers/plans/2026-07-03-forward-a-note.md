# Forward a Note Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user forward any note to new recipients — opening a fresh compose seeded with the note's channel and a forwarding indicator — with email connectors performing a real upstream forward (original message + attachments) and every other channel falling back to a new item with the forwarded content blockquoted.

**Architecture:** The app does the minimum — a `ForwardNote` command seeds compose and attaches a `fwdNoteId` pointer to the source note; a per-viewer renderer shows the author a link to the original and recipients the forwarded snapshot. The server (`workers/api`) owns the native-vs-fallback decision, the fallback assembly (blockquote + copied attachments), and the recipient-visible snapshot. Only Gmail's MIME forward lives in the connector.

**Tech Stack:** Flutter/Dart + Drift (app), TypeScript Cloudflare Workers + Kysely + Postgres/Atlas (API + DB), `@plotday/twister` SDK + Gmail connector (TypeScript, in the `public/` submodule).

## Global Constraints

Copied verbatim from the spec and repo guidelines; every task's requirements implicitly include these.

- **Server owns the logic.** All forward *assembly* and the *native-vs-fallback decision* live in `workers/api`, never the app. The app only (1) seeds compose and (2) attaches a `fwdNoteId` pointer.
- **Distinct field.** Add a new `fwd_note` / `fwdNoteId` reference; do NOT overload `reNoteId`.
- **`supportsForward` is modeled on `supportsFileAttachments`** — an optional boolean on `LinkTypeConfig`, consumed server-side only.
- **Approach A:** reuse `onCreateLink` (via a `CreateLinkDraft.forward?: { key }` field) rather than adding a new connector hook.
- **Snapshot, not live pointer.** Forward crosses a trust boundary; the server captures the forwarded content into a `ForwardUserAction` on the note so recipients see it regardless of access to the original.
- **Identical before/after sync.** The author's view derives purely from `note.content` + locally resolved `fwdNoteId` (a link to the original) and suppresses the server snapshot; it must render the same before and after sync, native or fallback.
- **Gmail native now; Outlook + others are fast-follows** (gated by the same `supportsForward` flag; they use the fallback until implemented).
- **Public submodule = separate PR + changeset.** Any change under `public/twister/src/` needs a changeset (`@plotday/twister` minor, `Added:` prefix). Write all `public/` commit/PR text for a public audience (no internal IDs/data).
- **Never `DELETE` from a synced table**; never hardcode DB port — use `$DATABASE_URL`. Schema changes go through `libs/db/schema/` → `pnpm gen-migration` → `pnpm apply-migrations` → commit regenerated `libs/db/src/types.ts`.
- **Flutter:** forui + `flutter/widgets.dart` only (no `flutter/material.dart`); sentence case for all UI text; every new unexpected-error `catch` calls `Tracker.captureException` (Dart) / `tracker.captureException` (TS).
- **Local only. Never deploy** (including workers — run locally).

---

## Task Ordering & Testability

- **Phase A — Task 1:** SDK types (`supportsForward`, `CreateLinkDraft.forward`). Testable via `tsc`/lint.
- **Phase B — Tasks 2–3:** `fwd_note` column (remote + Drift) + Note model plumbing. Testable via migration apply + Dart round-trip test.
- **Phase C — Task 4:** `ForwardUserAction` (the snapshot payload). Testable via Dart JSON round-trip.
- **Phase D — Tasks 5–8:** Server forward pipeline (resolve source, decide, native draft field, fallback + snapshot, plain-Plot). Testable via `workers/api` vitest.
- **Phase E — Tasks 9–10:** Gmail native forward. Testable via connector vitest.
- **Phase F — Tasks 11–14:** Flutter UX (command, compose seeding, takeover bar, rendering). Testable via widget tests + `run-app`.
- **Phase G — Task 15:** Finalization (docs, changeset, lint).

Each task's commit message: `public/` tasks (1, 9, 10) commit inside the submodule; all others in the main repo.

---

## Phase A — SDK types

### Task 1: Add `supportsForward` + `CreateLinkDraft.forward` to Twister

**Files:**
- Modify: `public/twister/src/tools/integrations.ts:211` (after `supportsFileAttachments`)
- Modify: `public/twister/src/connector.ts:201` (end of `CreateLinkDraft`)
- Create: `public/.changeset/forward-a-note.md`

**Interfaces:**
- Produces: `LinkTypeConfig.supportsForward?: boolean`; `CreateLinkDraft.forward?: { key: string }`. Consumed by Tasks 5–6 (server) and 9–10 (Gmail).

- [ ] **Step 1: Add `supportsForward` to `LinkTypeConfig`.** Insert immediately after the `supportsFileAttachments?: boolean;` block (`integrations.ts:211`):

```ts
  /**
   * Whether a note on this link type can be forwarded to new recipients using
   * the source system's native forwarding (e.g. an email forward that carries
   * the original message and its attachments). When false (the default), Plot
   * forwards by creating a new item on the target whose body is the user's
   * message followed by the blockquoted original ("fallback" forward). Only set
   * true if the connector's `onCreateLink` handles a `CreateLinkDraft.forward`
   * reference and builds a real upstream forward.
   */
  supportsForward?: boolean;
```

- [ ] **Step 2: Add `forward` to `CreateLinkDraft`.** Insert before the closing `};` of `CreateLinkDraft` (`connector.ts:201`, after the `attachments?` field):

```ts
  /**
   * When present, this create-link is a FORWARD of an existing upstream item.
   * `key` is the source note's connector `key` (e.g. the Gmail message id). The
   * connector should reconstruct a native forward of that item — carrying its
   * original body and attachments — addressed to the draft's recipients, with
   * `noteContent` as the forwarder's own message on top. Only populated for link
   * types that declare `supportsForward: true`; otherwise the runtime uses the
   * blockquote fallback and never sets this.
   */
  forward?: { key: string };
```

- [ ] **Step 3: Add the changeset.** Create `public/.changeset/forward-a-note.md`:

```markdown
---
"@plotday/twister": minor
---

Added: `LinkTypeConfig.supportsForward` and `CreateLinkDraft.forward` so connectors can perform native forwards of existing items (e.g. email forwards carrying the original message and attachments) when a user forwards a note.
```

- [ ] **Step 4: Build + validate.**

Run: `cd public/twister && pnpm build && cd .. && pnpm validate-changesets`
Expected: build succeeds; changeset validation passes.

- [ ] **Step 5: Refresh the workspace link in the main repo.**

Run: `cd /Users/kris.braun/code/plot && pnpm install`
Expected: completes; `@plotday/twister` workspace link updated.

- [ ] **Step 6: Commit (inside the submodule).**

```bash
cd /Users/kris.braun/code/plot/public
git add twister/src/tools/integrations.ts twister/src/connector.ts .changeset/forward-a-note.md
git commit -m "Add supportsForward and CreateLinkDraft.forward for native forwards"
cd /Users/kris.braun/code/plot
```

---

## Phase B — `fwd_note` column + Note plumbing

### Task 2: Add `fwd_note` to the remote `note` table + `upsert_note` RPC

**Files:**
- Modify: `libs/db/schema/50-tables/` (the `note` table definition — the file that declares `re_note_id`)
- Modify: `libs/db/schema/` upsert_note function (the file defining `upsert_note`, which declares `p_re_note_id`)
- Generate: `libs/db/migrations/<timestamp>_add_note_fwd_note.sql` (via `pnpm gen-migration`)
- Commit: regenerated `libs/db/src/types.ts`

**Interfaces:**
- Produces: `note.fwd_note uuid null` column; `upsert_note(..., p_fwd_note uuid default null, ...)`. Consumed by Task 3 (Flutter sync), Tasks 5–8 (server), and the note-ingest handler.

- [ ] **Step 1: Locate the anchors.**

Run: `rg -n "re_note_id" libs/db/schema/`
Expected: shows the `note` table column declaration and the `upsert_note` function's `p_re_note_id` param + its INSERT/UPDATE usage. These are the exact sites to mirror.

- [ ] **Step 2: Add the column to the `note` table.** In the `note` table schema file, directly beneath the `re_note_id uuid` column, add:

```sql
  fwd_note uuid null references note(id) on delete set null,
```

(Mirror the nullability/reference style of `re_note_id` in that file. If `re_note_id` has no FK, omit the `references …` clause to match.)

- [ ] **Step 3: Thread `p_fwd_note` through `upsert_note`.** In the `upsert_note` function, mirror every place `p_re_note_id` appears:
  - Add param `p_fwd_note uuid default null` next to `p_re_note_id`.
  - Add `fwd_note` to the INSERT column list and `p_fwd_note` to its VALUES.
  - Add `fwd_note = coalesce(p_fwd_note, note.fwd_note)` (or the exact merge style used for `re_note_id`) to the `ON CONFLICT ... DO UPDATE SET`.

- [ ] **Step 4: Generate the migration.**

Run: `pnpm gen-migration -- add_note_fwd_note`
Expected: a new file in `libs/db/migrations/`. Verify it adds the column and the RPC changes.

- [ ] **Step 5: Apply locally + regenerate types.**

Run: `psql "$DATABASE_URL" -tAc "show port;"` (confirm the DB port is the expected local/worktree one, NOT a stale value), then `pnpm apply-migrations`
Expected: migration applies; `pnpm types` runs automatically (regenerates `libs/db/src/types.ts` with `fwd_note`).

- [ ] **Step 6: Verify schema/migrations in sync + types current.**

Run: `pnpm diff-schema-migrations && pnpm --filter @plotday/db run lint`
Expected: no differences; lint passes (types committed-ready).

- [ ] **Step 7: Commit.**

```bash
git add libs/db/schema libs/db/migrations libs/db/src/types.ts
git commit -m "feat(db): add note.fwd_note column and upsert_note p_fwd_note param"
```

### Task 3: Add `fwdNoteId` to the Flutter `Note` (store + sync + migration)

**Files:**
- Modify: `apps/plot/lib/store/note.dart` (table col 124; factory 216/243; `Note.draft` 265; `_internal` 287; `_fromStore` 320; field decl 365; `copyWith` 1450/1532; `props` 1556)
- Modify: `apps/plot/lib/store/store.dart` (`Store.schemaVersion` + `migration.onUpgrade`)
- Test: `apps/plot/test/store/note_fwd_note_test.dart`

**Interfaces:**
- Consumes: `note.fwd_note` sync field (Task 2).
- Produces: `Note.fwdNoteId` (`NoteId?`) that round-trips through Drift + sync (`toBase`/`fromBase` handle it automatically via the `NoteRow` JSON, since the column name matches `fwd_note`). Consumed by Tasks 11–14.

- [ ] **Step 1: Write the failing round-trip test.** Create `apps/plot/test/store/note_fwd_note_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

void main() {
  test('fwdNoteId round-trips through copyWith', () {
    final source = NoteId.generate();
    final note = Note.draft(threadId: ThreadId.generate());
    expect(note.fwdNoteId, isNull);

    final forwarded = note.copyWith(fwdNoteId: source);
    expect(forwarded.fwdNoteId, source);

    // clearing works
    final cleared = forwarded.copyWith(clearFwdNoteId: true);
    expect(cleared.fwdNoteId, isNull);
  });
}
```

- [ ] **Step 2: Run it to confirm it fails.**

Run: `cd apps/plot && flutter test test/store/note_fwd_note_test.dart`
Expected: FAIL — `fwdNoteId`/`clearFwdNoteId` are undefined.

- [ ] **Step 3: Add the Drift column.** In `Notes` (`note.dart`), after `reNoteId` (line 123):

```dart
  BlobColumn get fwdNoteId => blob().nullable().map(const UuidConverter())();
```

- [ ] **Step 4: Thread `fwdNoteId` through the `Note` class.** Mirror `reNoteId` in each site:
  - factory params (after `NoteId? reNoteId,`): `NoteId? fwdNoteId,`
  - factory body `Note._internal(... reNoteId: reNoteId, fwdNoteId: fwdNoteId, ...)`
  - `Note.draft` initializer list: `fwdNoteId = null,`
  - `Note._internal` params: `this.fwdNoteId,`
  - `Note._fromStore`: `fwdNoteId: noteRow.fwdNoteId,`
  - field declaration (after `final NoteId? reNoteId;`): `final NoteId? fwdNoteId;`

- [ ] **Step 5: Thread through `copyWith`.** Add params next to `reNoteId` (line 1450):

```dart
    NoteId? fwdNoteId,
    bool clearFwdNoteId = false,
```

and in the `NoteRow(...)` constructed at line 1516, next to the `reNoteId:` line:

```dart
        fwdNoteId: clearFwdNoteId ? null : (fwdNoteId ?? this.fwdNoteId),
```

and add `fwdNoteId,` to the `props` list (after `reNoteId,` at line 1556).

- [ ] **Step 6: Add the Drift migration.** First read the current version:

Run: `rg -n "schemaVersion" apps/plot/lib/store/store.dart`

Let `V` be the current value. In `store.dart`, set `schemaVersion` to `V + 1` and add an `onUpgrade` step guarded on that new version (substitute the real number for `V+1`):

```dart
    if (from < /* V+1 */) {
      await m.addColumn(notes, notes.fwdNoteId);
    }
```

(A nullable column needs no data migration.)

- [ ] **Step 7: Regenerate Drift code.**

Run: `cd apps/plot && flutter pub run build_runner build --delete-conflicting-outputs`
Expected: regenerates `store.g.dart` (or equivalent) with the new column; no errors.

- [ ] **Step 8: Run the test + analyze.**

Run: `cd apps/plot && flutter test test/store/note_fwd_note_test.dart && flutter analyze lib/store/note.dart`
Expected: PASS; analyze clean.

- [ ] **Step 9: Commit.**

```bash
git add apps/plot/lib/store/note.dart apps/plot/lib/store/store.dart apps/plot/lib/store/*.g.dart apps/plot/test/store/note_fwd_note_test.dart
git commit -m "feat(app): add Note.fwdNoteId (store column, sync, migration)"
```

---

## Phase C — Forward snapshot payload

### Task 4: Add `ForwardUserAction` (recipient-visible snapshot)

**Files:**
- Modify: `apps/plot/lib/store/user_action.dart` (enum 3; `fromJson` switch 28; new class after `ThreadUserAction` ~302)
- Test: `apps/plot/test/store/forward_user_action_test.dart`

**Interfaces:**
- Produces: `ForwardUserAction { sourceTitle, sourceAuthorName, quotedContent, sourceThreadId? }` with `type: UserActionType.forward`, JSON key `"forward"`. Server (Task 7) emits the identical JSON shape; renderer (Task 14) consumes it.

- [ ] **Step 1: Write the failing JSON round-trip test.** Create `apps/plot/test/store/forward_user_action_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

void main() {
  test('ForwardUserAction round-trips through JSON', () {
    const action = ForwardUserAction(
      sourceTitle: 'Q3 budget review',
      sourceAuthorName: 'Alice Smith',
      quotedContent: '> Original body line 1\n> line 2',
      sourceThreadId: 'abc-123',
    );
    final json = action.toJson();
    expect(json['type'], 'forward');

    final parsed = UserAction.fromJson(json);
    expect(parsed, isA<ForwardUserAction>());
    expect((parsed as ForwardUserAction).sourceTitle, 'Q3 budget review');
    expect(parsed.quotedContent, '> Original body line 1\n> line 2');
  });
}
```

- [ ] **Step 2: Run it to confirm it fails.**

Run: `cd apps/plot && flutter test test/store/forward_user_action_test.dart`
Expected: FAIL — `ForwardUserAction`/`UserActionType.forward` undefined.

- [ ] **Step 3: Extend the enum + dispatch.** In `user_action.dart`, add `forward` to `UserActionType` (line 3 block) after `createLink`:

```dart
  createLink,
  forward,
```

and add a case to `UserAction.fromJson` (line 28 switch), after the `createLink` case:

```dart
      case UserActionType.forward:
        return ForwardUserAction.fromJson(json);
```

- [ ] **Step 4: Add the class.** Insert after `ThreadUserAction` (after line 302):

```dart
/// A snapshot of a forwarded note's content, materialized by the server onto
/// the forwarded item so recipients see the original even when they lack access
/// to it. The author's client suppresses this in favor of a link to the
/// original (see note rendering). Never authored by the client.
class ForwardUserAction extends UserAction {
  const ForwardUserAction({
    required this.sourceTitle,
    required this.sourceAuthorName,
    required this.quotedContent,
    this.sourceThreadId,
  }) : super(type: UserActionType.forward);

  /// Title of the original thread/message being forwarded.
  final String sourceTitle;

  /// Display name of the original message's author.
  final String sourceAuthorName;

  /// The original content, already blockquoted as Markdown.
  final String quotedContent;

  /// Base58/uuid id of the original thread, when the viewer could resolve it.
  /// Recipients typically cannot; null then.
  final String? sourceThreadId;

  factory ForwardUserAction.fromJson(Map<String, dynamic> json) {
    return ForwardUserAction(
      sourceTitle: json['sourceTitle'] as String? ?? '',
      sourceAuthorName: json['sourceAuthorName'] as String? ?? '',
      quotedContent: json['quotedContent'] as String? ?? '',
      sourceThreadId: json['sourceThreadId'] as String?,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'sourceTitle': sourceTitle,
      'sourceAuthorName': sourceAuthorName,
      'quotedContent': quotedContent,
      if (sourceThreadId != null) 'sourceThreadId': sourceThreadId,
    };
  }

  @override
  List<Object?> get props =>
      [type, sourceTitle, sourceAuthorName, quotedContent, sourceThreadId];
}
```

- [ ] **Step 5: Run the test + analyze.**

Run: `cd apps/plot && flutter test test/store/forward_user_action_test.dart && flutter analyze lib/store/user_action.dart`
Expected: PASS; analyze clean.

- [ ] **Step 6: Commit.**

```bash
git add apps/plot/lib/store/user_action.dart apps/plot/test/store/forward_user_action_test.dart
git commit -m "feat(app): add ForwardUserAction snapshot payload"
```

---

## Phase D — Server forward pipeline (`workers/api`)

> Test runner for this phase: `pnpm --filter @plotday/api test -- <file>` (vitest). Confirm the exact invocation with `rg -n '"test"' workers/api/package.json` before Step 1 of Task 5.

### Task 5: `resolveForwardSource` — source key, connection, and snapshot

**Files:**
- Create: `workers/api/src/twist/forward.ts`
- Test: `workers/api/src/twist/forward.test.ts`

**Interfaces:**
- Consumes: `fwd_note` (uuid), a Kysely `DB` handle.
- Produces:
  ```ts
  type ForwardSource = {
    key: string | null;            // source note connector key (null = plain Plot note)
    sourceConnectionId: string | null; // source thread's primary link.created_by (twist_instance)
    supportsForward: boolean;      // source link type declares supportsForward
    snapshot: { sourceTitle: string; sourceAuthorName: string; quotedContent: string; sourceThreadId: string };
  };
  async function resolveForwardSource(db: Kysely<DB>, fwdNoteId: string): Promise<ForwardSource | null>;
  function blockquote(markdown: string): string;
  ```
  Consumed by Tasks 6–8.

- [ ] **Step 1: Write the failing unit test for `blockquote`.** Create `workers/api/src/twist/forward.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { blockquote } from "./forward";

describe("blockquote", () => {
  it("prefixes every line with '> '", () => {
    expect(blockquote("line 1\nline 2")).toBe("> line 1\n> line 2");
  });
  it("keeps blank lines quoted so the block stays contiguous", () => {
    expect(blockquote("a\n\nb")).toBe("> a\n>\n> b");
  });
  it("returns empty string for empty input", () => {
    expect(blockquote("")).toBe("");
  });
});
```

- [ ] **Step 2: Run it to confirm it fails.**

Run: `pnpm --filter @plotday/api test -- src/twist/forward.test.ts`
Expected: FAIL — module `./forward` not found.

- [ ] **Step 3: Implement `blockquote` + the resolver skeleton.** Create `workers/api/src/twist/forward.ts`:

```ts
import type { Kysely } from "kysely";
import type { DB } from "@plotday/db";

/** Markdown-blockquote every line (blank lines become a bare ">"). */
export function blockquote(markdown: string): string {
  if (markdown === "") return "";
  return markdown
    .split("\n")
    .map((line) => (line.length === 0 ? ">" : `> ${line}`))
    .join("\n");
}

export type ForwardSource = {
  key: string | null;
  sourceConnectionId: string | null;
  supportsForward: boolean;
  snapshot: {
    sourceTitle: string;
    sourceAuthorName: string;
    quotedContent: string;
    sourceThreadId: string;
  };
};

/**
 * Resolve everything the forward pipeline needs from the source note id:
 * its connector key, the connection (twist_instance) that owns its thread,
 * whether that connection's link type supports native forward, and a
 * snapshot of the original content (blockquoted) for the recipient view.
 * Returns null if the source note no longer exists.
 */
export async function resolveForwardSource(
  db: Kysely<DB>,
  fwdNoteId: string,
): Promise<ForwardSource | null> {
  const note = await db
    .selectFrom("note")
    .select(["id", "key", "content", "thread_id", "author_id"])
    .where("id", "=", fwdNoteId)
    .executeTakeFirst();
  if (!note) return null;

  const thread = await db
    .selectFrom("thread")
    .select(["id", "title"])
    .where("id", "=", note.thread_id)
    .executeTakeFirst();

  // Primary link = the connector link on the source thread (created_by is the
  // owning twist_instance). Null for a plain Plot thread.
  const link = await db
    .selectFrom("link")
    .select(["created_by", "type"])
    .where("thread_id", "=", note.thread_id)
    .where("created_by", "is not", null)
    .orderBy("created_at", "asc")
    .executeTakeFirst();

  const authorName = await resolveActorName(db, note.author_id);

  return {
    key: note.key ?? null,
    sourceConnectionId: (link?.created_by as string | undefined) ?? null,
    supportsForward: await linkTypeSupportsForward(db, link?.created_by ?? null, link?.type ?? null),
    snapshot: {
      sourceTitle: thread?.title ?? "",
      sourceAuthorName: authorName,
      quotedContent: blockquote(note.content ?? ""),
      sourceThreadId: note.thread_id,
    },
  };
}
```

- [ ] **Step 4: Implement the two private helpers.** Append to `forward.ts` — resolve the actor's display name and read the connector's `supportsForward` for the link type:

```ts
async function resolveActorName(db: Kysely<DB>, actorId: string): Promise<string> {
  const contact = await db
    .selectFrom("contact")
    .select(["name"])
    .where("id", "=", actorId)
    .executeTakeFirst();
  return contact?.name ?? "";
}

/**
 * Read the connector's declared linkTypes for `connectionId` (a twist_instance)
 * and return whether the given link `type` declares supportsForward. Mirrors how
 * the runtime resolves per-linkType compose/capability config from the twist's
 * connector metadata. Returns false when unknown (→ fallback forward).
 */
async function linkTypeSupportsForward(
  db: Kysely<DB>,
  connectionId: string | null,
  type: string | null,
): Promise<boolean> {
  if (!connectionId || !type) return false;
  const config = await loadLinkTypeConfig(db, connectionId, type);
  return config?.supportsForward === true;
}
```

For `loadLinkTypeConfig`, reuse the existing runtime helper the API already uses to read a twist_instance's linkType config (the same source that feeds `LinkTypeConfig.supportsFileAttachments`/`compose`). Locate it first:

Run: `rg -n "supportsFileAttachments|getLinkTypeConfig|linkTypes\b" workers/api/src`
Then import and call that helper here instead of `loadLinkTypeConfig`; delete the placeholder name. (If the config is materialized on the twist_instance row as JSON, select and parse it; match the existing access pattern exactly.)

- [ ] **Step 5: Run the `blockquote` tests.**

Run: `pnpm --filter @plotday/api test -- src/twist/forward.test.ts`
Expected: PASS (the `blockquote` describe block; the resolver is exercised in Task 7).

- [ ] **Step 6: Typecheck.**

Run: `pnpm --filter @plotday/api exec tsc --noEmit`
Expected: no type errors.

- [ ] **Step 7: Commit.**

```bash
git add workers/api/src/twist/forward.ts workers/api/src/twist/forward.test.ts
git commit -m "feat(api): resolveForwardSource + blockquote helper for forwarding"
```

### Task 6: Carry `forward` through the create-link draft (native path)

**Files:**
- Modify: `workers/api/src/app/sync/create-link-dispatch.ts:88-171` (`CreateLinkDraftPayload`)
- Modify: `workers/api/src/app/sync/threads.ts:1200-1218` (draft builder) + wherever `body.note_*` denormalized fields are read (~650)
- Modify: `workers/api/src/twist/tools/integrations.ts:3110-3294` (`create_link` dispatch → pass `forward` into the `CreateLinkDraft`)
- Test: `workers/api/src/app/sync/create-link-forward.test.ts`

**Interfaces:**
- Consumes: `resolveForwardSource` (Task 5); `body.note_fwd_note` on the thread POST.
- Produces: a `CreateLinkDraft.forward = { key }` reaching `onCreateLink` when the source is native-capable AND the target connection equals the source connection.

- [ ] **Step 1: Write the failing decision test.** Create `workers/api/src/app/sync/create-link-forward.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { decideForward } from "./create-link-dispatch";

describe("decideForward", () => {
  const src = { key: "msg-1", sourceConnectionId: "conn-A", supportsForward: true };

  it("native when same connection + supportsForward", () => {
    expect(decideForward(src, "conn-A")).toEqual({ mode: "native", key: "msg-1" });
  });
  it("fallback when connection differs", () => {
    expect(decideForward(src, "conn-B")).toEqual({ mode: "fallback" });
  });
  it("fallback when link type lacks supportsForward", () => {
    expect(decideForward({ ...src, supportsForward: false }, "conn-A")).toEqual({ mode: "fallback" });
  });
  it("fallback when target is plain Plot (no connection)", () => {
    expect(decideForward(src, null)).toEqual({ mode: "fallback" });
  });
});
```

- [ ] **Step 2: Run it to confirm it fails.**

Run: `pnpm --filter @plotday/api test -- src/app/sync/create-link-forward.test.ts`
Expected: FAIL — `decideForward` not exported.

- [ ] **Step 3: Add `decideForward` + extend the payload type.** In `create-link-dispatch.ts`, add near `CreateLinkDraftPayload`:

```ts
export type ForwardDecision = { mode: "native"; key: string } | { mode: "fallback" };

/**
 * Native forward only when the target connection is the SAME connection that
 * owns the source item AND that link type supports native forward. Any other
 * case (different connection, unsupported link type, plain Plot) → fallback.
 */
export function decideForward(
  source: { key: string | null; sourceConnectionId: string | null; supportsForward: boolean },
  targetConnectionId: string | null,
): ForwardDecision {
  if (
    source.supportsForward &&
    source.key &&
    targetConnectionId &&
    source.sourceConnectionId &&
    targetConnectionId === source.sourceConnectionId
  ) {
    return { mode: "native", key: source.key };
  }
  return { mode: "fallback" };
}
```

and add `forward?: { key: string };` to the `CreateLinkDraftPayload` type.

- [ ] **Step 4: Populate `forward` in the thread draft builder.** In `threads.ts`, where `body.note_fwd_note` arrives (add it alongside the existing `body.note_content` read ~650) and the draft is built (`threads.ts:1200-1218`): when `body.note_fwd_note` is set, call `resolveForwardSource(db, body.note_fwd_note)`, then `decideForward(source, createLinkSpec.twist_instance_id ?? null)`; if `native`, set `draft.forward = { key: decision.key }`. (The fallback branch is Task 7 — leave a `// Task 7: fallback assembly` marker here for now, native only.)

```ts
// after building `draft` in the isDispatchableCreateLink block:
if (body.note_fwd_note) {
  const source = await resolveForwardSource(db, body.note_fwd_note);
  if (source) {
    const decision = decideForward(source, createLinkSpec.twist_instance_id ?? null);
    if (decision.mode === "native") {
      (draft as CreateLinkDraftPayload).forward = { key: decision.key };
    }
    // Task 7 handles decision.mode === "fallback" (blockquote noteContent + snapshot).
  }
}
```

- [ ] **Step 5: Pass `forward` through the dispatch → `CreateLinkDraft`.** In `integrations.ts:3110-3294`, add `forward?: { key: string };` to the destructured `draft` shape (~3116) and include `forward: draft.forward` when constructing the `CreateLinkDraft` handed to `onCreateLink` in the `createEntries` args (~3287). No entrypoint change is needed — the existing `forwardTo → saveCreatedLink` wiring is reused.

- [ ] **Step 6: Run the decision test + typecheck.**

Run: `pnpm --filter @plotday/api test -- src/app/sync/create-link-forward.test.ts && pnpm --filter @plotday/api exec tsc --noEmit`
Expected: PASS; no type errors.

- [ ] **Step 7: Commit.**

```bash
git add workers/api/src/app/sync/create-link-dispatch.ts workers/api/src/app/sync/threads.ts workers/api/src/twist/tools/integrations.ts workers/api/src/app/sync/create-link-forward.test.ts
git commit -m "feat(api): route native forward through CreateLinkDraft.forward"
```

### Task 7: Fallback assembly + snapshot materialization

**Files:**
- Modify: `workers/api/src/app/sync/threads.ts` (fallback branch from Task 6)
- Modify: `workers/api/src/twist/forward.ts` (add `buildFallbackContent` + `buildSnapshotAction`)
- Test: `workers/api/src/twist/forward.test.ts` (extend)

**Interfaces:**
- Produces:
  ```ts
  function buildFallbackContent(userMessage: string, snapshot: ForwardSource["snapshot"]): string;
  function buildSnapshotAction(snapshot: ForwardSource["snapshot"]): Record<string, unknown>; // ForwardUserAction JSON
  ```
  The snapshot action JSON matches `ForwardUserAction.fromJson` (Task 4).

- [ ] **Step 1: Write the failing tests.** Append to `workers/api/src/twist/forward.test.ts`:

```ts
import { buildFallbackContent, buildSnapshotAction } from "./forward";

describe("buildFallbackContent", () => {
  const snap = { sourceTitle: "Q3", sourceAuthorName: "Alice", quotedContent: "> hi", sourceThreadId: "t1" };
  it("puts the user's message above the quoted original with an attribution line", () => {
    expect(buildFallbackContent("FYI", snap)).toBe(
      "FYI\n\n---\n\nForwarded from Alice — Q3\n\n> hi",
    );
  });
  it("omits the leading blank when the user wrote nothing", () => {
    expect(buildFallbackContent("", snap)).toBe("---\n\nForwarded from Alice — Q3\n\n> hi");
  });
});

describe("buildSnapshotAction", () => {
  it("emits ForwardUserAction JSON matching the Flutter shape", () => {
    const snap = { sourceTitle: "Q3", sourceAuthorName: "Alice", quotedContent: "> hi", sourceThreadId: "t1" };
    expect(buildSnapshotAction(snap)).toEqual({
      type: "forward",
      sourceTitle: "Q3",
      sourceAuthorName: "Alice",
      quotedContent: "> hi",
      sourceThreadId: "t1",
    });
  });
});
```

- [ ] **Step 2: Run to confirm failure.**

Run: `pnpm --filter @plotday/api test -- src/twist/forward.test.ts`
Expected: FAIL — functions not exported.

- [ ] **Step 3: Implement both builders.** Append to `forward.ts`:

```ts
/**
 * Fallback forward body: the forwarder's own message, a separator, an
 * attribution line, then the blockquoted original. Used verbatim as the
 * outbound item's content on connectors without native forward, and as the
 * plain-Plot note content.
 */
export function buildFallbackContent(
  userMessage: string,
  snapshot: ForwardSource["snapshot"],
): string {
  const attribution = `Forwarded from ${snapshot.sourceAuthorName} — ${snapshot.sourceTitle}`;
  const head = userMessage.length > 0 ? `${userMessage}\n\n` : "";
  return `${head}---\n\n${attribution}\n\n${snapshot.quotedContent}`;
}

/** ForwardUserAction JSON (matches the Flutter `ForwardUserAction.fromJson`). */
export function buildSnapshotAction(
  snapshot: ForwardSource["snapshot"],
): Record<string, unknown> {
  return {
    type: "forward",
    sourceTitle: snapshot.sourceTitle,
    sourceAuthorName: snapshot.sourceAuthorName,
    quotedContent: snapshot.quotedContent,
    sourceThreadId: snapshot.sourceThreadId,
  };
}
```

- [ ] **Step 4: Wire the fallback branch (connector target, no native).** In `threads.ts`, replace the Task-6 fallback marker: when `decision.mode === "fallback"` and the target is a connector, set the create-link draft's `noteContent` to `buildFallbackContent(originalNoteContent, source.snapshot)` (so the outbound item carries the blockquoted original) and append `buildSnapshotAction(source.snapshot)` to the note's `actions` array persisted on the originating note (so recipients render the snapshot). Do NOT set `draft.forward`.

```ts
if (decision.mode === "fallback") {
  draft.noteContent = buildFallbackContent(draft.noteContent ?? "", source.snapshot);
  // Persist the snapshot action onto the originating note so recipients render it.
  await appendNoteAction(db, dispatchThreadId, buildSnapshotAction(source.snapshot));
}
```

For `appendNoteAction`, mirror the existing note-action update pattern (see `updateNoteBaseline`/`updateNoteKey` at `integrations.ts:6386-6475` for the note-row update shape) — read the thread's opening note's `actions`, append the snapshot object, write back via a Kysely update on `note.actions`. Locate/confirm the opening-note lookup with `rg -n "opening note|firstNote|order by created_at asc" workers/api/src/app/sync/threads.ts`.

- [ ] **Step 5: Run the tests + typecheck.**

Run: `pnpm --filter @plotday/api test -- src/twist/forward.test.ts && pnpm --filter @plotday/api exec tsc --noEmit`
Expected: PASS; no type errors.

- [ ] **Step 6: Commit.**

```bash
git add workers/api/src/twist/forward.ts workers/api/src/app/sync/threads.ts workers/api/src/twist/forward.test.ts
git commit -m "feat(api): fallback forward body + recipient snapshot materialization"
```

### Task 8: Plain-Plot forward (no connector target)

**Files:**
- Modify: `workers/api/src/app/sync/notes.ts:220-329` (note ingest) OR `threads.ts` plain-Plot branch
- Test: `workers/api/src/app/sync/forward-plain-plot.test.ts`

**Interfaces:**
- Consumes: `resolveForwardSource`, `buildSnapshotAction`, `isDispatchableCreateLink`.
- Produces: a plain Plot forwarded note that carries a `ForwardUserAction` snapshot and a `fwd_note` pointer, with no connector dispatch.

- [ ] **Step 1: Write the failing test.** Create `workers/api/src/app/sync/forward-plain-plot.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { forwardActionsForPlainPlot } from "./notes";

describe("forwardActionsForPlainPlot", () => {
  it("appends a ForwardUserAction snapshot to a plain-Plot forwarded note", () => {
    const snap = { sourceTitle: "Q3", sourceAuthorName: "Alice", quotedContent: "> hi", sourceThreadId: "t1" };
    const actions = forwardActionsForPlainPlot([], snap);
    expect(actions).toEqual([
      { type: "forward", sourceTitle: "Q3", sourceAuthorName: "Alice", quotedContent: "> hi", sourceThreadId: "t1" },
    ]);
  });
  it("preserves existing actions", () => {
    const snap = { sourceTitle: "Q3", sourceAuthorName: "Alice", quotedContent: "> hi", sourceThreadId: "t1" };
    const existing = [{ type: "external", title: "x", url: "https://x" }];
    expect(forwardActionsForPlainPlot(existing, snap)).toHaveLength(2);
  });
});
```

- [ ] **Step 2: Run to confirm failure.**

Run: `pnpm --filter @plotday/api test -- src/app/sync/forward-plain-plot.test.ts`
Expected: FAIL — `forwardActionsForPlainPlot` not exported.

- [ ] **Step 3: Implement the helper + wire it into note ingest.** In `notes.ts`, add:

```ts
import { buildSnapshotAction } from "../../twist/forward";

/** Append the forward snapshot action to a plain-Plot forwarded note's actions. */
export function forwardActionsForPlainPlot(
  existing: Array<Record<string, unknown>>,
  snapshot: { sourceTitle: string; sourceAuthorName: string; quotedContent: string; sourceThreadId: string },
): Array<Record<string, unknown>> {
  return [...existing, buildSnapshotAction(snapshot)];
}
```

Then in the `POST /sync/notes` handler (before the `upsert_note` call at ~303), when `body.fwd_note` is set: resolve `resolveForwardSource(trx, body.fwd_note)`; if the source resolved and there is NO connector create-link on this note (plain Plot), set `body.actions = forwardActionsForPlainPlot(body.actions ?? [], source.snapshot)`. Always pass `p_fwd_note: body.fwd_note || null` to `upsert_note` (mirror `p_re_note_id`).

```ts
      if (body.fwd_note) {
        const source = await resolveForwardSource(trx, body.fwd_note);
        if (source && !body.actions?.some((a: any) => a?.type === "createLink")) {
          body.actions = forwardActionsForPlainPlot(body.actions ?? [], source.snapshot);
        }
      }
      // ...and in the rpcUser("upsert_note", { ... }) call:
      p_fwd_note: body.fwd_note || null,
```

- [ ] **Step 4: Run the test + typecheck.**

Run: `pnpm --filter @plotday/api test -- src/app/sync/forward-plain-plot.test.ts && pnpm --filter @plotday/api exec tsc --noEmit`
Expected: PASS; no type errors.

- [ ] **Step 5: Commit.**

```bash
git add workers/api/src/app/sync/notes.ts workers/api/src/app/sync/forward-plain-plot.test.ts
git commit -m "feat(api): plain-Plot forward persists fwd_note + snapshot action"
```

---

## Phase E — Gmail native forward (`public/` submodule)

> Test runner: confirm with `rg -n '"test"' public/connectors/gmail/package.json` (existing suite is `gmail-api.test.ts`).

### Task 9: `buildForwardMessage` MIME builder

**Files:**
- Modify: `public/connectors/gmail/src/gmail-api.ts` (add after `buildReplyMessage`, ~1459)
- Test: `public/connectors/gmail/src/gmail-api.test.ts`

**Interfaces:**
- Produces: `buildForwardMessage(options): string` — base64url raw MIME. Mirrors `buildReplyMessage` but with `Fwd:` subject, no `In-Reply-To`/`References` (a forward starts a new thread), the forwarder's message on top of a quoted original attribution, and re-attached original attachments.

- [ ] **Step 1: Write the failing test.** Add to `gmail-api.test.ts`:

```ts
import { buildForwardMessage } from "./gmail-api";

describe("buildForwardMessage", () => {
  function decode(raw: string): string {
    const b64 = raw.replace(/-/g, "+").replace(/_/g, "/");
    return Buffer.from(b64, "base64").toString("utf-8");
  }
  it("uses a Fwd: subject and includes the quoted original + forwarder message", () => {
    const raw = buildForwardMessage({
      to: ["bob@example.com"],
      cc: [],
      from: "me@example.com",
      subject: "Q3 budget",
      body: "See below.",
      originalHeader: "From: Alice <alice@example.com>\nSubject: Q3 budget",
      originalBody: "Let's meet Thursday.",
    });
    const msg = decode(raw);
    expect(msg).toContain("Subject: Fwd: Q3 budget");
    expect(msg).not.toContain("In-Reply-To:");
    expect(msg).toContain("See below.");
    expect(msg).toContain("Let's meet Thursday.");
  });
  it("keeps an existing Fwd: prefix instead of doubling it", () => {
    const raw = buildForwardMessage({
      to: ["b@x.com"], cc: [], from: "m@x.com", subject: "Fwd: hi",
      body: "", originalHeader: "From: a@x.com", originalBody: "hi",
    });
    expect(decode(raw)).toContain("Subject: Fwd: hi");
    expect(decode(raw)).not.toContain("Fwd: Fwd:");
  });
});
```

- [ ] **Step 2: Run to confirm failure.**

Run: `pnpm --filter @plotday/connector-gmail test -- gmail-api.test.ts`
Expected: FAIL — `buildForwardMessage` not exported.

- [ ] **Step 3: Implement `buildForwardMessage`.** Add after `buildReplyMessage` (`gmail-api.ts:1459`), reusing the module's existing helpers (`sanitizeHeaderValue`, `mimeBoundary`, `buildAlternativeBlock`, `uint8ArrayToBase64Lines`, `base64UrlEncodeMessage`, `AttachmentData`):

```ts
/**
 * Build an RFC 2822 forward of an existing Gmail message. Unlike a reply, a
 * forward starts a NEW thread (no In-Reply-To / References). The body is the
 * forwarder's own message followed by a standard quoted-original block; the
 * original's attachments are re-attached.
 */
export function buildForwardMessage(options: {
  to: string[];
  cc: string[];
  from: string;
  subject: string;
  body: string;
  originalHeader: string; // "From: … \n Date: … \n Subject: … \n To: …"
  originalBody: string;   // the original message's text/markdown body
  attachments?: AttachmentData[];
}): string {
  const { to, cc, from, subject, body, originalHeader, originalBody, attachments } = options;

  const fromHeader = sanitizeHeaderValue(from);
  const toHeader = to.map(sanitizeHeaderValue).join(", ");
  const ccHeader = cc.map(sanitizeHeaderValue).join(", ");
  const fwdSubject = sanitizeHeaderValue(
    subject.startsWith("Fwd:") ? subject : `Fwd: ${subject}`,
  );

  const headerLines: string[] = [`From: ${fromHeader}`, `To: ${toHeader}`];
  if (cc.length > 0) headerLines.push(`Cc: ${ccHeader}`);
  headerLines.push(`Subject: ${fwdSubject}`);
  headerLines.push(`MIME-Version: 1.0`);

  // Compose the visible body: forwarder message + quoted-original block.
  const quotedOriginal = [
    "---------- Forwarded message ----------",
    originalHeader,
    "",
    originalBody,
  ].join("\n");
  const composed = body.length > 0 ? `${body}\n\n${quotedOriginal}` : quotedOriginal;

  const altBoundary = mimeBoundary("alt");
  const altBlock = buildAlternativeBlock(altBoundary, composed);

  let rawMessage: string;
  if (attachments && attachments.length > 0) {
    const mixBoundary = mimeBoundary("mix");
    const attachmentParts: string[] = [];
    for (const att of attachments) {
      const b64Lines = uint8ArrayToBase64Lines(att.data);
      const safeFileName = att.fileName.replace(/[\r\n"]/g, "_");
      attachmentParts.push(
        `--${mixBoundary}`,
        `Content-Type: ${att.mimeType}; name="${safeFileName}"`,
        `Content-Transfer-Encoding: base64`,
        `Content-Disposition: attachment; filename="${safeFileName}"`,
        "",
        b64Lines,
      );
    }
    rawMessage = [
      ...headerLines,
      `Content-Type: multipart/mixed; boundary="${mixBoundary}"`,
      "",
      `--${mixBoundary}`,
      ...altBlock,
      ...attachmentParts,
      `--${mixBoundary}--`,
    ].join("\r\n");
  } else {
    rawMessage = [...headerLines, ...altBlock].join("\r\n");
  }

  return base64UrlEncodeMessage(rawMessage);
}
```

- [ ] **Step 4: Run the test + build.**

Run: `pnpm --filter @plotday/connector-gmail test -- gmail-api.test.ts && cd public/connectors/gmail && pnpm build && cd /Users/kris.braun/code/plot`
Expected: PASS; build succeeds.

- [ ] **Step 5: Commit (inside the submodule).**

```bash
cd /Users/kris.braun/code/plot/public
git add connectors/gmail/src/gmail-api.ts connectors/gmail/src/gmail-api.test.ts
git commit -m "gmail: add buildForwardMessage for native email forwards"
cd /Users/kris.braun/code/plot
```

### Task 10: Branch Gmail `onCreateLink` on `draft.forward` + declare `supportsForward`

**Files:**
- Modify: `public/connectors/gmail/src/sync.ts:1867` (`onCreateLinkFn` — branch at top)
- Modify: `public/connectors/gmail/src/gmail.ts` (email `linkTypes` entry → `supportsForward: true`)
- Test: `public/connectors/gmail/src/sync.test.ts` (or the existing sync test file — confirm with `rg -n "onCreateLinkFn" public/connectors/gmail/src`)

**Interfaces:**
- Consumes: `CreateLinkDraft.forward` (Task 1), `buildForwardMessage` (Task 9), the existing `getApiAnyFn`/`getMessage`/`getAttachment` client helpers.
- Produces: Gmail native forward — when `draft.forward` is set, fetch the source message by key, build a forward, send, return the link.

- [ ] **Step 1: Declare `supportsForward` on the email link type.** In `gmail.ts`, on the `email` entry of `linkTypes`, add `supportsForward: true,` next to its `compose` block.

- [ ] **Step 2: Write the failing branch test.** Add a test asserting that when `draft.forward` is present, `onCreateLinkFn` fetches the source message and calls `buildForwardMessage` (mock the api client's `getMessage`/`sendNewMessage`). Model it on the existing `onCreateLinkFn` tests; assert the sent raw contains `Fwd:`.

```ts
it("onCreateLink builds a native forward when draft.forward is set", async () => {
  const host = makeFakeHost({ /* enabled channel + api mock returning source message */ });
  const link = await onCreateLinkFn(host, {
    channelId: "c1", type: "email", status: null, title: "Q3", noteContent: "fyi",
    contacts: [], inviteEmails: ["bob@x.com"], forward: { key: "msg-1" },
  } as any);
  expect(host.sentRaw).toContain("Fwd:");
  expect(host.sentRaw).toContain("fyi");
  expect(link?.type).toBe("email");
});
```

(Adapt `makeFakeHost`/mocks to the file's existing test harness.)

- [ ] **Step 3: Run to confirm failure.**

Run: `pnpm --filter @plotday/connector-gmail test`
Expected: FAIL — no forward branch yet.

- [ ] **Step 4: Add the forward branch at the top of `onCreateLinkFn`.** Right after the `if (draft.type !== "email") return null;` guard (`sync.ts:1871`), before recipient parsing:

```ts
  if (draft.forward) {
    const api = await getApiAnyFn(host);
    if (!api) {
      console.error("[gmail] onCreateLink(forward): no enabled channel for auth");
      return null;
    }
    // Recipients (reuse the To/Cc/Bcc split below by falling through would be
    // ideal, but a forward needs them before building the MIME):
    const to: string[] = [];
    const cc: string[] = [];
    for (const r of draft.recipients ?? []) (r.role === "cc" ? cc : to).push(r.externalAccountId);
    for (const email of draft.inviteEmails ?? []) to.push(email);
    if (to.length + cc.length === 0) {
      console.error("[gmail] onCreateLink(forward): no recipients");
      return null;
    }

    const src = await api.getMessage(draft.forward.key); // format: "full"
    const profile = await api.getProfile();
    const originalHeader = buildForwardedHeaderBlock(src); // From/Date/Subject/To from src headers
    const originalBody = extractPlainBody(src);            // reuse existing body extractor
    const atts = await fetchOriginalAttachments(api, draft.forward.key, src); // reuse getAttachment

    const raw = buildForwardMessage({
      to, cc,
      from: profile.emailAddress,
      subject: draft.title || getHeader(src, "Subject") || "",
      body: draft.noteContent ?? "",
      originalHeader,
      originalBody,
      attachments: atts,
    });

    const sent = await sendWithRetry(() => api.sendNewMessage(raw), "forward");
    if (!sent.ok) {
      return { originatingNote: { deliveryError: { code: sent.error.code, message: sent.error.message } } };
    }
    const gmailThreadId = sent.result.threadId;
    const canonicalUrl = `https://mail.google.com/mail/u/0/#inbox/${gmailThreadId}`;
    const enabledChannels = await getEnabledChannelsFn(host);
    const channelId = [...enabledChannels][0] ?? "";
    return {
      source: canonicalUrl,
      type: "email",
      title: (draft.title || getHeader(src, "Subject")) ?? undefined,
      status: null,
      created: new Date(),
      sourceUrl: canonicalUrl,
      channelId,
      meta: { syncProvider: "google", syncableId: channelId, channelId, threadId: gmailThreadId, historyId: null },
    };
  }
```

For `buildForwardedHeaderBlock`, `extractPlainBody`, `getHeader`, and `fetchOriginalAttachments`: reuse the connector's existing header/body/attachment helpers (the inbound transform already reads these — find them with `rg -n "getHeader|extractBody|getAttachment|payload.headers" public/connectors/gmail/src`). Do not invent new parsers; wire to the existing ones and delete any placeholder names.

- [ ] **Step 5: Run tests + build.**

Run: `pnpm --filter @plotday/connector-gmail test && cd public/connectors/gmail && pnpm build && cd /Users/kris.braun/code/plot`
Expected: PASS; build succeeds.

- [ ] **Step 6: Commit (inside the submodule).**

```bash
cd /Users/kris.braun/code/plot/public
git add connectors/gmail/src/gmail.ts connectors/gmail/src/sync.ts connectors/gmail/src/sync.test.ts
git commit -m "gmail: forward existing message when draft.forward is set; declare supportsForward"
cd /Users/kris.braun/code/plot
```

---

## Phase F — Flutter UX

### Task 11: `ForwardNote` command

**Files:**
- Modify: `apps/plot/lib/command/note.dart` (add `ForwardNote` after `SplitNoteToNewThread` ~810; register in `noteCommands` ~855)
- Modify: `apps/plot/lib/page/new_thread.dart` (add `requestForward` static signal — full wiring in Task 12; this task only calls it)
- Test: `apps/plot/test/command/forward_note_test.dart`

**Interfaces:**
- Produces: a `ForwardNote(note)` command that resolves the source note's connection and calls `NewThreadPageState.requestForward(ForwardSeed(...))`, then routes to `NewThreadRoute`.
- Consumes: `NewThreadPageState.requestForward` (Task 12) and `ForwardSeed` (Task 12).

- [ ] **Step 1: Write the failing test.** Create `apps/plot/test/command/forward_note_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/note.dart';

void main() {
  test('ForwardNote is titled "Forward" with the forward icon', () {
    final note = Note.draft(threadId: ThreadId.generate())
        .copyWith(content: 'hello', draft: false);
    final cmd = ForwardNote(note);
    expect(cmd.title, 'Forward');
  });
}
```

- [ ] **Step 2: Run to confirm failure.**

Run: `cd apps/plot && flutter test test/command/forward_note_test.dart`
Expected: FAIL — `ForwardNote` undefined.

- [ ] **Step 3: Implement `ForwardNote`.** Add after `SplitNoteToNewThread` (`note.dart:810`):

```dart
class ForwardNote extends NoteCommand {
  ForwardNote(super.note)
    : super(
        title: 'Forward',
        eventObject: EventObject.note,
        eventAction: EventAction.opened,
        icon: FontAwesomeIcons.share, // arrow-forward style
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      // Resolve the source note's connection so compose defaults to the same
      // channel (plain Plot when the thread has no connector).
      final links = await Link.getForThread(note.threadId);
      final thread = await Thread.getOne(note.threadId);
      final primaryLink = thread.primaryLink(links);

      final priorityBloc = context.read<PriorityBloc>();
      final priorityId =
          (priorityBloc.state.context ?? priorityBloc.state.draft.priority).id;

      NewThreadPageState.activateOnOpen();
      NewThreadPageState.requestForward(
        ForwardSeed(sourceNote: note, primaryLink: primaryLink),
      );

      return CommandRoute(
        PriorityRoute(
          priorityIdString: priorityId.toShortString(),
          children: [NewThreadRoute()],
        ),
      );
    } catch (e, stackTrace) {
      log.severe('Error in ForwardNote: $e', e, stackTrace);
      Tracker.captureException(e, stackTrace);
      return CommandMessage('Failed to forward note', isError: true);
    }
  }
}
```

Confirm the exact link-lookup API with `rg -n "primaryLink|getForThread|Link.forThread" apps/plot/lib/store/link.dart apps/plot/lib/store/thread.dart` and adjust `Link.getForThread`/`Thread.primaryLink` names to match.

- [ ] **Step 4: Register in `noteCommands`.** In `noteCommands` (`note.dart:842-863`), after the `SplitNoteToNewThread` entry (line 855):

```dart
    if (!note.draft) ForwardNote(note),
```

- [ ] **Step 5: Add the `ForwardSeed` type + `requestForward` stub** so this compiles (full application is Task 12). In `new_thread.dart`, near `requestReset` (line 156):

```dart
  /// Seed describing a forward-in-progress, consumed by a live/fresh page.
  static ForwardSeed? _pendingForward;

  /// Requests every live [NewThreadPage] open a forward of [seed].
  static void requestForward(ForwardSeed seed) {
    _pendingForward = seed;
    resetRequest.value++;
  }
```

and a top-level value type in `new_thread.dart`:

```dart
class ForwardSeed {
  const ForwardSeed({required this.sourceNote, required this.primaryLink});
  final Note sourceNote;
  final Link? primaryLink;
}
```

- [ ] **Step 6: Run the test + analyze.**

Run: `cd apps/plot && flutter test test/command/forward_note_test.dart && flutter analyze lib/command/note.dart lib/page/new_thread.dart`
Expected: PASS; analyze clean.

- [ ] **Step 7: Commit.**

```bash
git add apps/plot/lib/command/note.dart apps/plot/lib/page/new_thread.dart apps/plot/test/command/forward_note_test.dart
git commit -m "feat(app): ForwardNote command + requestForward signal"
```

### Task 12: Apply the forward seed in compose (default Via + forwarding state + jump to compose)

**Files:**
- Modify: `apps/plot/lib/page/new_thread.dart` (consume `_pendingForward` in reset/mount; add `_applyForward`; hold `_forwardSource` state)
- Test: manual via `run-app` (Task 14 adds a widget test that also covers seeding)

**Interfaces:**
- Consumes: `ForwardSeed`, `_pendingForward` (Task 11); `_applyConnectionChoice`/`_applyTarget` (existing, `new_thread.dart:1167`/`1213`).
- Produces: on forward, compose mounts on the compose step with Via = source connection (a `CreateLinkUserAction` on the draft) and `_forwardSourceNote` set; the draft note will carry `fwdNoteId` on send.

- [ ] **Step 1: Consume the pending forward in the reset path.** Wherever `resetRequest` is listened to / `_resetToFreshStart` runs (search: `rg -n "resetRequest|_resetToFreshStart|activateOnOpen|_initializeDraft" apps/plot/lib/page/new_thread.dart`), after the fresh-start reset, if `_pendingForward != null` call `_applyForward(_pendingForward!)` and null it out. Also consume it in `initState`/`didChangeDependencies` for a fresh mount (mirror how `feedback`/`activateOnOpen` are consumed).

- [ ] **Step 2: Add `_forwardSourceNote` field + `_applyForward`.** Near the other compose state fields (`new_thread.dart:205-233`):

```dart
  /// The note being forwarded, when this compose was opened via ForwardNote.
  /// Drives the "Forwarding" takeover bar and is attached to the sent note as
  /// `fwdNoteId`. Null for a normal compose.
  Note? _forwardSourceNote;
```

and the method:

```dart
  void _applyForward(ForwardSeed seed) {
    setState(() {
      _forwardSourceNote = seed.sourceNote;
      _step = _ComposeStep.compose;
    });
    // Default Via to the source connection when the note came from a connector.
    final link = seed.primaryLink;
    if (link != null && link.createdBy != null) {
      _applyConnectionChoiceForLink(link); // builds a CreateLinkUserAction from the link's connection
    }
    // else: plain Plot — leave the default Plot target.
  }
```

For `_applyConnectionChoiceForLink`: reuse the existing choice-application path. The connection picker builds a `CreateLinkUserAction` from a `TwistConnection`/`Channel`; resolve the `TwistInstance` for `link.createdBy` and its `Channel` for `link.channelId`, construct the `TargetConnectionChoice`/`CreateLinkUserAction` the same way `_applyConnectionChoice` (line 1167) does, and apply it to the draft. Confirm the construction with `rg -n "_applyConnectionChoice|TargetConnectionChoice|CreateLinkUserAction\(" apps/plot/lib/page/new_thread.dart apps/plot/lib/widget/compose/connection_choice.dart` and mirror it.

- [ ] **Step 3: Attach `fwdNoteId` on send.** In `finalizeThreadDraft` (`new_thread.dart:2114`), where the `Note` is built from the draft (~2181-2195), when `_forwardSourceNote != null` set `fwdNoteId: _forwardSourceNote!.id` on the note (via `copyWith(fwdNoteId: ...)` or the constructor). Also carry it to the thread POST as the denormalized `note_fwd_note` field so the server create-link path can resolve it — confirm where `note_content`/`note_actions` are serialized for the thread POST (`rg -n "note_content|note_actions|note_fwd_note" apps/plot/lib/store/`) and add `note_fwd_note` alongside.

- [ ] **Step 4: Analyze.**

Run: `cd apps/plot && flutter analyze lib/page/new_thread.dart`
Expected: clean.

- [ ] **Step 5: Commit.**

```bash
git add apps/plot/lib/page/new_thread.dart
git commit -m "feat(app): seed compose from a forward (default Via + fwdNoteId on send)"
```

### Task 13: "Forwarding" takeover bar

**Files:**
- Modify: `apps/plot/lib/widget/note_editor_top_bar.dart` (add `ForwardingState` + a `switch` arm)
- Modify: `apps/plot/lib/widget/note_editor.dart` (feed `ForwardingState` in new-thread/forward mode; add an `onClearForward` path)
- Modify: `apps/plot/lib/page/new_thread.dart` (clear `_forwardSourceNote` on clear)
- Test: `apps/plot/test/widget/forwarding_top_bar_test.dart`

**Interfaces:**
- Consumes: `_forwardSourceNote` (Task 12).
- Produces: a reply-styled takeover bar reading "Forwarding" with a one-line preview + × that clears the forward.

- [ ] **Step 1: Write the failing widget test.** Create `apps/plot/test/widget/forwarding_top_bar_test.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:plot/widget/note_editor_top_bar.dart';

void main() {
  testWidgets('ForwardingState renders "Forwarding" + preview + clear', (tester) async {
    var cleared = false;
    await tester.pumpWidget(FTheme(
      data: FThemes.zinc.light,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: NoteEditorTopBar(
          state: const ForwardingState(quotePreview: 'Q3 budget review'),
          roundTop: false,
          onClearReply: () {},
          onCancelEdit: () {},
          onClearForward: () => cleared = true,
        ),
      ),
    ));
    expect(find.text('Forwarding'), findsOneWidget);
    expect(find.text('Q3 budget review'), findsOneWidget);
    await tester.tap(find.byKey(const Key('top-bar-clear')));
    expect(cleared, isTrue);
  });
}
```

- [ ] **Step 2: Run to confirm failure.**

Run: `cd apps/plot && flutter test test/widget/forwarding_top_bar_test.dart`
Expected: FAIL — `ForwardingState`/`onClearForward` undefined.

- [ ] **Step 3: Add `ForwardingState` + wire it.** In `note_editor_top_bar.dart`, after `EditingState` (line 37):

```dart
/// Takeover chrome shown while composing a forward.
class ForwardingState extends TopBarState {
  final String quotePreview;

  const ForwardingState({required this.quotePreview});
}
```

Add `final VoidCallback onClearForward;` to `NoteEditorTopBar` (with the other callbacks, line 111) and its constructor; add the switch arm in `build` (line 124):

```dart
      final ForwardingState s => _TakeoverBar(
        icon: FontAwesomeIcons.share,
        label: 'Forwarding',
        quotePreview: s.quotePreview,
        onClear: onClearForward,
        roundTop: roundTop,
        context: context,
      ),
```

- [ ] **Step 4: Feed it from the editor.** In `note_editor.dart`, `_computeTopBarState` (line 790) currently reads `ThreadBloc` state. For the new-thread/forward path, the editor must render `ForwardingState` when the page is forwarding. Add a `Note? forwardSource` param to `NoteEditor` (passed from `NewThreadPage` step-3 build sites `new_thread.dart:2550`/`2623`); at the top of `_computeTopBarState`, if `widget.forwardSource != null` return `ForwardingState(quotePreview: _previewOf(widget.forwardSource!.content))`. Wire the `NoteEditorTopBar(... onClearForward: () => widget.onClearForward?.call())` and add an `onClearForward` callback param that `NewThreadPage` uses to clear `_forwardSourceNote` (and its default Via if desired) via `setState`.

- [ ] **Step 5: Clear on ×.** In `new_thread.dart`, pass `onClearForward: () => setState(() => _forwardSourceNote = null)` to the `NoteEditor` in the compose step.

- [ ] **Step 6: Run the widget test + analyze.**

Run: `cd apps/plot && flutter test test/widget/forwarding_top_bar_test.dart && flutter analyze lib/widget/note_editor_top_bar.dart lib/widget/note_editor.dart`
Expected: PASS; analyze clean.

- [ ] **Step 7: Commit.**

```bash
git add apps/plot/lib/widget/note_editor_top_bar.dart apps/plot/lib/widget/note_editor.dart apps/plot/lib/page/new_thread.dart apps/plot/test/widget/forwarding_top_bar_test.dart
git commit -m "feat(app): Forwarding takeover bar in compose"
```

### Task 14: Note rendering — author link vs. recipient snapshot

**Files:**
- Modify: `apps/plot/lib/widget/note.dart` (render forward affordances)
- Modify: `apps/plot/lib/widget/note_action.dart` (render `ForwardUserAction` for recipients)
- Test: `apps/plot/test/widget/forwarded_note_render_test.dart`

**Interfaces:**
- Consumes: `note.fwdNoteId` (Task 3), `ForwardUserAction` (Task 4).
- Produces: author sees content + a compact "Forwarded from …" link (from `fwdNoteId`) and NO snapshot; a non-author (or when `fwdNoteId` can't be resolved locally) sees content + the `ForwardUserAction` snapshot. Identical before/after sync for the author.

- [ ] **Step 1: Write the failing widget test.** Create `apps/plot/test/widget/forwarded_note_render_test.dart` with two cases: (a) author + `fwdNoteId` set → shows a "Forwarded from" link and hides any `ForwardUserAction`; (b) non-author with a `ForwardUserAction` in `actions` → shows the quoted snapshot. Use the note-widget test harness already present in `apps/plot/test/widget/` (confirm with `rg -n "NoteWidget|pumpWidget" apps/plot/test/widget/note*`). Assert:

```dart
// (a) author view — link present, snapshot suppressed
expect(find.textContaining('Forwarded from'), findsOneWidget);
expect(find.textContaining('> '), findsNothing); // no blockquoted snapshot
// (b) recipient view — snapshot shown
expect(find.textContaining('> Original body'), findsOneWidget);
```

- [ ] **Step 2: Run to confirm failure.**

Run: `cd apps/plot && flutter test test/widget/forwarded_note_render_test.dart`
Expected: FAIL — rendering not implemented.

- [ ] **Step 3: Implement the author affordance + suppression.** In `note.dart`, in the note body/action rendering:
  - Compute `final isForwardAuthor = note.fwdNoteId != null && note.authorId.isCurrentUser;`
  - When `isForwardAuthor`, render a compact tappable "Forwarded from {title}" row beneath the content that navigates to the source thread, resolving the source via `note.fwdNoteId` (use a `FutureBuilder` on `Note.getOne(note.fwdNoteId!)` → `Thread.getOne(sourceNote.threadId)` for the title/route; if it fails to resolve, fall through to the snapshot path). Confirm the note-open route with `rg -n "ThreadRoute\(" apps/plot/lib/widget/note.dart`.
  - Filter the rendered actions: when `isForwardAuthor`, drop any `ForwardUserAction` from the actions passed to the attachment renderer (that's the suppression). When not the author, keep it.

```dart
final visibleActions = isForwardAuthor
    ? (note.actions ?? const []).where((a) => a is! ForwardUserAction).toList()
    : note.actions;
```

- [ ] **Step 4: Render `ForwardUserAction` for recipients.** In `note_action.dart` (`NoteActionWidget`, class at 34), add a branch for `UserActionType.forward` that renders a quoted "forwarded message" card: a header line ("Forwarded from {sourceAuthorName} — {sourceTitle}") above the `quotedContent` shown as muted quoted text. Match the existing action-row visual style (forui, no material).

- [ ] **Step 5: Run the widget test + analyze.**

Run: `cd apps/plot && flutter test test/widget/forwarded_note_render_test.dart && flutter analyze lib/widget/note.dart lib/widget/note_action.dart`
Expected: PASS; analyze clean.

- [ ] **Step 6: Full app smoke via run-app.** Launch the app (invoke the `run-app` skill), forward a Gmail note to yourself, and confirm: compose opens on the compose step with Via = Gmail and the "Forwarding" bar; after send the author sees "Forwarded from …" and no blockquote; the rendering does not change when the note syncs.

- [ ] **Step 7: Commit.**

```bash
git add apps/plot/lib/widget/note.dart apps/plot/lib/widget/note_action.dart apps/plot/test/widget/forwarded_note_render_test.dart
git commit -m "feat(app): render forwarded notes (author link vs recipient snapshot)"
```

---

## Phase G — Finalization

### Task 15: Docs, changeset check, and full lint

**Files:**
- Create: `docs/updates.d/<slug>-<id>.md` (via `pnpm updates:new`)
- Modify: `docs/features.md`
- Modify: `docs/email-gaps.md:57` (mark "Forward action" done)

- [ ] **Step 1: Add the user-facing update fragment.**

Run: `pnpm updates:new "Forward emails and messages to new people"`
Then edit the fragment so it reads, under a `### Threads` (or existing best-fit) section, plainly:

```markdown
### Threads

- Forward any email or message to new people — emails forward the original with its attachments; other channels include the forwarded text.
```

- [ ] **Step 2: Update `features.md` + `email-gaps.md`.** Add a Forward bullet to the relevant capability list in `docs/features.md`, and in `docs/email-gaps.md` mark Tier 2 #5 "Forward action" (line 57) as shipped (and the `f` shortcut note at line 136 if a shortcut was added — none is in this plan, so leave that gap).

- [ ] **Step 3: Repo-wide lint (changed packages).**

Run: `pnpm --filter @plotday/api lint && cd apps/plot && flutter analyze && cd /Users/kris.braun/code/plot && cd public/twister && pnpm lint && cd /Users/kris.braun/code/plot`
Expected: all clean.

- [ ] **Step 4: Confirm public submodule state.** Ensure the submodule commits (Tasks 1, 9, 10) are in place and the changeset validates:

Run: `cd public && pnpm validate-changesets && git log --oneline -5 && cd /Users/kris.braun/code/plot`
Expected: validation passes; the three submodule commits present. (The submodule PR is opened separately with public-audience text per the spec.)

- [ ] **Step 5: Commit main-repo docs.**

```bash
git add docs/updates.d docs/features.md docs/email-gaps.md
git commit -m "docs: forward-a-note update fragment + features/email-gaps"
```

---

## Self-Review Notes (for the executor)

- **Spec coverage:** SDK capability (Task 1); `fwd_note` column + Note plumbing (Tasks 2–3); snapshot payload (Task 4); server decision/native/fallback/plain-Plot (Tasks 5–8); Gmail native forward (Tasks 9–10); command/compose/takeover-bar/rendering (Tasks 11–14); identical-before/after rendering (Task 14); finalization (Task 15).
- **Anchors to verify before editing** (they may have drifted): the `loadLinkTypeConfig` helper name (Task 5 Step 4), the opening-note lookup + `note.actions` update in `threads.ts` (Task 7 Step 4), the `body.note_*` denormalized serialization for the thread POST (Task 12 Step 3), the Gmail header/body/attachment helpers (Task 10 Step 4), and `Link.getForThread`/`Thread.primaryLink` (Task 11 Step 3). Each task step says exactly which `rg` to run.
- **No connector-only changeset:** the changeset (Task 1) targets `@plotday/twister` only; Gmail changes (Tasks 9–10) get NO changeset.
