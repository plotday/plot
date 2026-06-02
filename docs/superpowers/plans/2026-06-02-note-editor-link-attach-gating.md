# NoteEditor "Add link" / "Attach file" Capability Gating — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show "Add link" and "Attach file" in the NoteEditor only for link types whose source can carry that action; private Plot notes always show both.

**Architecture:** Add two opt-in boolean capability flags (`supportsLinks`, `supportsFileAttachments`, both default `false`) to `LinkTypeConfig` in Twister (TS) and the Flutter store (Dart). They ride the existing `channel.link_types` jsonb — no DB migration. The NoteEditor resolves the active `LinkTypeConfig` (thread's primary link in note mode; the selected create-action's type in new-thread mode; `null` = private Plot note) and conditionally renders each button + gates the `Cmd+Shift+L` shortcut. A completed audit shows only Gmail, Slack, Linear forward file attachments and no connector forwards the link action, so exactly three connectors get `supportsFileAttachments: true`.

**Tech Stack:** TypeScript (Twister SDK, connectors), Dart/Flutter (forui), Changesets.

**Spec:** `docs/superpowers/specs/2026-06-02-note-editor-link-attach-gating-design.md`

---

## File Structure

- `public/twister/src/tools/integrations.ts` — add two fields to the `LinkTypeConfig` type (the SDK contract).
- `public/.changeset/note-editor-link-attach-capabilities.md` — required changeset for the Twister change.
- `apps/plot/lib/store/link.dart` — add two `bool` fields + parse them in `LinkTypeConfig.fromJson` (default `false`).
- `apps/plot/test/store/link_test.dart` — unit tests for the new parsing.
- `apps/plot/lib/widget/note_editor.dart` — gating helpers + conditional buttons in both bottom bars + shortcut gate.
- `public/connectors/gmail/src/gmail.ts`, `public/connectors/slack/src/slack.ts`, `public/connectors/linear/src/linear.ts` — set `supportsFileAttachments: true`.

---

## Task 1: Twister — add capability flags to `LinkTypeConfig`

**Files:**
- Modify: `public/twister/src/tools/integrations.ts` (the `LinkTypeConfig` type, after `supportsContactChanges?`)
- Create: `public/.changeset/note-editor-link-attach-capabilities.md`

- [ ] **Step 1: Add the two fields to the type**

In `public/twister/src/tools/integrations.ts`, find the `supportsContactChanges?: boolean;` field inside the `LinkTypeConfig` type (it has a doc comment ending "Defaults to false when omitted."). Immediately **after** that field's `supportsContactChanges?: boolean;` line, insert:

```typescript
  /**
   * Whether a note/reply on this link type can carry a link (a pasted URL or
   * connector-created item) that Plot forwards to the source. When false (the
   * default), the "Add link" button is hidden for threads of this link type.
   * Only set true if the connector's reply path actually forwards the link
   * action to the source. Private Plot notes (no link type) always allow links.
   */
  supportsLinks?: boolean;
  /**
   * Whether a note/reply on this link type can carry an uploaded file that Plot
   * forwards to the source as an attachment. When false (the default), the
   * "Attach file" button is hidden for threads of this link type. Only set true
   * if the connector's reply path actually uploads file actions to the source.
   * Private Plot notes (no link type) always allow attachments.
   */
  supportsFileAttachments?: boolean;
```

- [ ] **Step 2: Create the changeset**

Create `public/.changeset/note-editor-link-attach-capabilities.md` with exactly:

```markdown
---
"@plotday/twister": minor
---

Added: `supportsLinks` and `supportsFileAttachments` capability flags on `LinkTypeConfig` so connectors can declare whether a note/reply of that link type can carry a link or a file attachment back to the source.
```

- [ ] **Step 3: Build Twister**

Run: `cd public/twister && pnpm build`
Expected: build succeeds, no TypeScript errors.

- [ ] **Step 4: Validate the changeset**

Run: `cd public && pnpm validate-changesets`
Expected: passes (no validation errors).

- [ ] **Step 5: Refresh the workspace link**

Run: `cd /Users/kris.braun/code/plot && pnpm install`
Expected: completes; the workspace link to `@plotday/twister` picks up the rebuilt dist.

- [ ] **Step 6: Commit**

```bash
cd /Users/kris.braun/code/plot/public
git add src/tools/integrations.ts .changeset/note-editor-link-attach-capabilities.md
git commit -m "feat(twister): add supportsLinks/supportsFileAttachments to LinkTypeConfig"
```

> Note: `public/` is a submodule. Per AGENTS.md this is a separate PR. Commit here; the submodule-ref bump in the parent repo happens in Task 6.

---

## Task 2: Dart — add fields to `LinkTypeConfig` + parse in `fromJson` (TDD)

**Files:**
- Modify: `apps/plot/lib/store/link.dart` (the `LinkTypeConfig` class, ~lines 26–135)
- Test: `apps/plot/test/store/link_test.dart`

- [ ] **Step 1: Write the failing tests**

In `apps/plot/test/store/link_test.dart`, inside the existing `group('LinkTypeConfig.fromJson', () { ... })` (before its closing `});` at line 47), add:

```dart
    test('parses supportsLinks / supportsFileAttachments (camelCase)', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'email',
        'label': 'Thread',
        'supportsLinks': true,
        'supportsFileAttachments': true,
      });
      expect(cfg.supportsLinks, isTrue);
      expect(cfg.supportsFileAttachments, isTrue);
    });

    test('parses supportsLinks / supportsFileAttachments (snake_case)', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'email',
        'label': 'Thread',
        'supports_links': true,
        'supports_file_attachments': true,
      });
      expect(cfg.supportsLinks, isTrue);
      expect(cfg.supportsFileAttachments, isTrue);
    });

    test('supportsLinks / supportsFileAttachments default to false', () {
      final cfg = LinkTypeConfig.fromJson({
        'type': 'note',
        'label': 'Note',
      });
      expect(cfg.supportsLinks, isFalse);
      expect(cfg.supportsFileAttachments, isFalse);
    });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd apps/plot && flutter test test/store/link_test.dart`
Expected: FAIL — `The getter 'supportsLinks' isn't defined for the type 'LinkTypeConfig'`.

- [ ] **Step 3: Add the fields to the class**

In `apps/plot/lib/store/link.dart`, in the `LinkTypeConfig` field list, immediately after the `supportsContactChanges` field declaration (the `final bool supportsContactChanges;` line and its doc comment), add:

```dart
  /// Whether a note/reply on this link type can carry a link (pasted URL or
  /// connector-created item) that Plot forwards to the source. False (default)
  /// hides the "Add link" button for threads of this link type. Private Plot
  /// notes (no link type) always allow links.
  final bool supportsLinks;
  /// Whether a note/reply on this link type can carry an uploaded file that
  /// Plot forwards to the source. False (default) hides the "Attach file"
  /// button for threads of this link type. Private Plot notes always allow
  /// attachments.
  final bool supportsFileAttachments;
```

- [ ] **Step 4: Add them to the constructor**

In the `const LinkTypeConfig({ ... })` constructor, after `this.supportsContactChanges = false,`, add:

```dart
    this.supportsLinks = false,
    this.supportsFileAttachments = false,
```

- [ ] **Step 5: Parse them in `fromJson`**

In the `factory LinkTypeConfig.fromJson(...)`, after the `supportsContactChanges:` parsing block (the one ending `false,`), add:

```dart
      supportsLinks:
          json['supportsLinks'] as bool? ??
          json['supports_links'] as bool? ??
          false,
      supportsFileAttachments:
          json['supportsFileAttachments'] as bool? ??
          json['supports_file_attachments'] as bool? ??
          false,
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd apps/plot && flutter test test/store/link_test.dart`
Expected: PASS (all tests, including the three new ones).

- [ ] **Step 7: Analyze**

Run: `cd apps/plot && flutter analyze lib/store/link.dart test/store/link_test.dart`
Expected: No issues.

- [ ] **Step 8: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/store/link.dart apps/plot/test/store/link_test.dart
git commit -m "feat(store): parse supportsLinks/supportsFileAttachments on LinkTypeConfig"
```

---

## Task 3: Flutter — gating helpers + note-mode bottom bar

**Files:**
- Modify: `apps/plot/lib/widget/note_editor.dart` (`_buildNoteBottomBar`, ~line 1316; add helper methods)

> Verification for Tasks 3–4 is `flutter analyze` + a manual run via the `run-app` skill. A full widget test for the bottom bar requires standing up `ThreadBloc` + draft plumbing for marginal value; the parsing logic that decides gating is already unit-tested in Task 2. State the manual-verification result explicitly when done.

- [ ] **Step 1: Add gating helper methods**

In `apps/plot/lib/widget/note_editor.dart`, in the same `State` class (place just above `// -- Bottom bars --`, near line 1314), add:

```dart
  // -- Capability gating --

  /// True when "Add link" should be shown for [cfg]. Null config = private Plot
  /// note (always allowed); otherwise the link type must declare support.
  bool _canAddLink(LinkTypeConfig? cfg) => cfg == null || cfg.supportsLinks;

  /// True when "Attach file" should be shown for [cfg]. Null config = private
  /// Plot note (always allowed); otherwise the link type must declare support.
  bool _canAttachFile(LinkTypeConfig? cfg) =>
      cfg == null || cfg.supportsFileAttachments;

  /// The LinkTypeConfig governing the note currently being edited: the selected
  /// create-action's type in new-thread mode, else the thread's primary link.
  /// Null means a private Plot note (both actions allowed).
  LinkTypeConfig? _activeLinkTypeConfig(BuildContext context) {
    if (widget.isNewThreadMode) {
      return linkTypeConfigForCreateAction(
        widget.draft.actions?.whereType<CreateLinkUserAction>().firstOrNull,
      );
    }
    return context.read<ThreadBloc>().state.primaryLinkTypeConfig;
  }
```

- [ ] **Step 2: Gate the buttons in `_buildNoteBottomBar`**

In `_buildNoteBottomBar`, the `threadState` local already exists. Replace the two button widgets (the `Button.icon(AddLink(...))` and `Button.icon(AttachFile(...))` inside the inner `Row`'s `children:`) with conditional `if`-elements. The block currently reads:

```dart
                    // Link button
                    Button.icon(
                      AddLink(
                        currentActions: _currentActions,
                        onActionsChanged: applyActions,
                        onNavigateToThread: widget.onNavigateToThread,
                      ),
                    ),
                    Button.icon(
                      AttachFile(
                        priorityId: priorityId,
                        currentLinks: _currentActions,
                        onLinksChanged: applyActions,
                      ),
                    ),
```

Replace it with:

```dart
                    // Link button — only when the source can carry a link.
                    if (_canAddLink(threadState.primaryLinkTypeConfig))
                      Button.icon(
                        AddLink(
                          currentActions: _currentActions,
                          onActionsChanged: applyActions,
                          onNavigateToThread: widget.onNavigateToThread,
                        ),
                      ),
                    if (_canAttachFile(threadState.primaryLinkTypeConfig))
                      Button.icon(
                        AttachFile(
                          priorityId: priorityId,
                          currentLinks: _currentActions,
                          onLinksChanged: applyActions,
                        ),
                      ),
```

- [ ] **Step 3: Analyze**

Run: `cd apps/plot && flutter analyze lib/widget/note_editor.dart`
Expected: No issues.

- [ ] **Step 4: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/widget/note_editor.dart
git commit -m "feat(note-editor): gate Add link / Attach file in note mode by link type"
```

---

## Task 4: Flutter — new-thread bottom bar + shortcut gate

**Files:**
- Modify: `apps/plot/lib/widget/note_editor.dart` (`_buildNewThreadBottomBar` ~line 1404, `_shortcutAddLink` ~line 1526)

- [ ] **Step 1: Resolve the config at the top of `_buildNewThreadBottomBar`**

In `_buildNewThreadBottomBar`, just after the existing two locals:

```dart
    final thread = widget.thread!;
    final draftNote = widget.draft;
```

add:

```dart
    final linkType = linkTypeConfigForCreateAction(
      draftNote.actions?.whereType<CreateLinkUserAction>().firstOrNull,
    );
```

- [ ] **Step 2: Gate the buttons in `_buildNewThreadBottomBar`**

Replace the two button widgets in the inner `Row`'s `children:` (currently `Button.icon(AddLink(...))` and `Button.icon(AttachFile(...))`):

```dart
                // Link button
                Button.icon(
                  AddLink(
                    currentActions: draftNote.actions ?? const [],
                    onActionsChanged: (actions) {
                      widget.onDraftChanged!(
                        thread,
                        note: draftNote.copyWith(actions: actions),
                      );
                    },
                    onNavigateToThread: widget.onNavigateToThread,
                  ),
                ),
                Button.icon(
                  AttachFile(
                    priorityId: thread.priority.id.toString(),
                    currentLinks: draftNote.actions ?? const [],
                    onLinksChanged: (actions) {
                      widget.onDraftChanged!(
                        thread,
                        note: draftNote.copyWith(actions: actions),
                      );
                    },
                  ),
                ),
```

with the same widgets wrapped in `if`-elements:

```dart
                // Link button — only when the target source can carry a link.
                if (_canAddLink(linkType))
                  Button.icon(
                    AddLink(
                      currentActions: draftNote.actions ?? const [],
                      onActionsChanged: (actions) {
                        widget.onDraftChanged!(
                          thread,
                          note: draftNote.copyWith(actions: actions),
                        );
                      },
                      onNavigateToThread: widget.onNavigateToThread,
                    ),
                  ),
                if (_canAttachFile(linkType))
                  Button.icon(
                    AttachFile(
                      priorityId: thread.priority.id.toString(),
                      currentLinks: draftNote.actions ?? const [],
                      onLinksChanged: (actions) {
                        widget.onDraftChanged!(
                          thread,
                          note: draftNote.copyWith(actions: actions),
                        );
                      },
                    ),
                  ),
```

- [ ] **Step 3: Gate the `Cmd+Shift+L` shortcut**

In `_shortcutAddLink`, replace:

```dart
  void _shortcutAddLink(BuildContext context) {
    if (_saving) return;
    context.run(
      AddLink(
        currentActions: _currentActions,
        onActionsChanged: _setCurrentActions,
        onNavigateToThread: widget.onNavigateToThread,
      ),
    );
  }
```

with:

```dart
  void _shortcutAddLink(BuildContext context) {
    if (_saving) return;
    // Respect the same per-link-type gating the toolbar button uses.
    if (!_canAddLink(_activeLinkTypeConfig(context))) return;
    context.run(
      AddLink(
        currentActions: _currentActions,
        onActionsChanged: _setCurrentActions,
        onNavigateToThread: widget.onNavigateToThread,
      ),
    );
  }
```

- [ ] **Step 4: Analyze**

Run: `cd apps/plot && flutter analyze lib/widget/note_editor.dart`
Expected: No issues.

- [ ] **Step 5: Manual verification (run-app skill)**

Invoke the `run-app` skill and verify:
- A private Plot thread note shows **both** buttons; `Cmd+Shift+L` opens the link modal.
- A Gmail thread reply shows **Attach file** but **not Add link**; `Cmd+Shift+L` does nothing.
- A Google Tasks thread (or compose) shows **neither**.
- A Linear / Slack thread reply shows **Attach file** (and not Add link).

State the observed result explicitly.

- [ ] **Step 6: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/widget/note_editor.dart
git commit -m "feat(note-editor): gate new-thread compose + Cmd+Shift+L by link type"
```

---

## Task 5: Connectors — declare `supportsFileAttachments: true` (gmail, slack, linear)

**Files:**
- Modify: `public/connectors/gmail/src/gmail.ts` (the `"email"` linkType, ~line 200)
- Modify: `public/connectors/slack/src/slack.ts` (the `"thread"` ~line 102 and `"dm"` ~line 119 linkTypes)
- Modify: `public/connectors/linear/src/linear.ts` (the `"issue"` linkType, ~line 72)

> Audit basis: gmail forwards file actions at `gmail.ts:1527-1544`; slack at `slack.ts:1212-1246` (shared `onNoteCreated` path covers both `thread` and `dm`); linear at `linear.ts:800-897`. None forward the `ExternalUserAction` link action, so `supportsLinks` is set nowhere.

- [ ] **Step 1: Gmail**

In `public/connectors/gmail/src/gmail.ts`, in the `readonly linkTypes = [ { type: "email", ... } ]` object, add a line after `replyVerb: "Send",`:

```typescript
      supportsFileAttachments: true,
```

- [ ] **Step 2: Slack (both link types)**

In `public/connectors/slack/src/slack.ts`, the `readonly linkTypes = [...]` array has two entries: `{ type: "thread", ... }` (~line 102) and `{ type: "dm", ... }` (~line 119). Add to **each** object (e.g. after its `noteLabel`/`sharingModel` line, anywhere inside the object literal):

```typescript
      supportsFileAttachments: true,
```

Verify there are exactly two `type:` entries in this `readonly linkTypes` array (`thread`, `dm`) and that both received the flag. (The other `type:` matches at ~lines 995/1040 are in a different construct — do not edit those unless they are also `LinkTypeConfig` entries in a `linkTypes` array; confirm by reading their surrounding context first.)

- [ ] **Step 3: Linear**

In `public/connectors/linear/src/linear.ts`, in the `readonly linkTypes = [ { type: "issue", ... } ]` object, add after `replyVerb: "Comment",`:

```typescript
      supportsFileAttachments: true,
```

- [ ] **Step 4: Lint the connectors**

Run: `cd public/connectors/gmail && pnpm lint` then repeat for `slack` and `linear` (`cd public/connectors/slack && pnpm lint`, `cd public/connectors/linear && pnpm lint`).
Expected: each passes with no errors.

- [ ] **Step 5: Commit (in the submodule)**

```bash
cd /Users/kris.braun/code/plot/public
git add connectors/gmail/src/gmail.ts connectors/slack/src/slack.ts connectors/linear/src/linear.ts
git commit -m "feat(connectors): declare supportsFileAttachments on gmail, slack, linear"
```

---

## Task 6: Finalize

**Files:**
- Possibly: `docs/updates.md` (user-facing bullet)
- The parent repo's submodule reference bump for `public/`

- [ ] **Step 1: Add a user-facing update note**

In `docs/updates.md`, add a bullet to the top section, in plain language:

```markdown
- The "Add link" and "Attach file" buttons now appear only when the item's source can actually accept them — for example, Gmail shows "Attach file" but not "Add link", and Google Tasks shows neither. Your private Plot notes still support both.
```

- [ ] **Step 2: Run the finalize checklist**

Invoke the `/finalize` skill. Ensure: `flutter analyze` clean on changed Dart files; `pnpm lint` clean in changed TS packages; no new `catch` blocks needing `captureException` (this change adds none); docs updated; public submodule changes are a separate PR with a changeset (Task 1).

- [ ] **Step 3: Bump the submodule reference in the parent repo**

```bash
cd /Users/kris.braun/code/plot
git add public docs/updates.md docs/superpowers
git commit -m "feat: gate NoteEditor Add link / Attach file by link-type capability"
```

(Confirm `git status` shows `public` as a new submodule commit reference, not unstaged submodule changes.)

- [ ] **Step 4: Final verification**

Run: `cd apps/plot && flutter analyze lib test/store/link_test.dart` — Expected: No issues.
Run: `cd apps/plot && flutter test test/store/link_test.dart` — Expected: PASS.

---

## Self-Review Notes

- **Spec coverage:** Flags (§1) → Tasks 1–2. Flutter gating note + new-thread + shortcut + null=private (§2) → Tasks 3–4. Connector audit + minimal edits (§3) → Task 5. No DB migration (§1) → no migration task, by design. Stale-config edge case (§ edge cases) → no action needed (safe failure mode), documented in spec. Out-of-scope items not implemented.
- **Type consistency:** `supportsLinks` / `supportsFileAttachments` used identically in TS (Task 1), Dart class + parse (Task 2), and gating helpers `_canAddLink` / `_canAttachFile` (Task 3). `_activeLinkTypeConfig` defined in Task 3, reused in Task 4.
- **No placeholders:** every code step shows exact code; every run step shows command + expected output.
