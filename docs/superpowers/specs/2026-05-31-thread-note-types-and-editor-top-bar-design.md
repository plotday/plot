# Thread note types and NoteEditor top bar

**Date:** 2026-05-31
**Status:** Approved design, ready for plan
**Scope:** `apps/plot/` Flutter app, `public/twister/` SDK, `public/connectors/*`

## Summary

Two changes that share a single underlying concept — the *type* of a note being created should be visible and changeable at the top of the editor, while the bottom row stays focused on *contents* (links, attachments, photos, twist toggle, send).

1. **NewThreadPage**: separate Plot threads into Note / Task / Chat (driven by two flags — `task` and `shared` — with the Chat label sticky once contacts have been added). Placeholder reflects the active mode.
2. **ThreadPage NoteEditor**: replace the bottom-bar mix of mode toggles (Task, Private) and content actions with a top "pill bar" that surfaces mode options. Reply-to-note and edit states continue to take over the bar in their existing loud accent style.

The redesign is motivated by user confusion: the current bottom row mixes "things added to the note" (links, attachments) with "changes to the note state" (task, private), and adding new affordances (reply variants, custom recipients) in the same row makes that worse. Moving mode signifiers to a top bar lets users see at a glance *how I'm sending/creating* with the content below.

## Definitions

- **Pill bar** — new top region of the editor. Hosts the type/mode pills at rest; "takes over" to show Reply / Edit chrome when those states are active.
- **Pill** — a single mode tile (label, optional avatar slot, active state). Styled to match the sidebar item: 6px radius, 14h/8v padding, transparent at rest, sidebar-accent fill on active.
- **Takeover** — existing loud accent chrome rendered when the user is replying to or editing a specific note. Excludes the pill row while active. Clicking the X exits and the pill row returns.
- **Mode** — one of: Note, Task, Reply, Reply to original, Comment, Private note. The active mode determines the placeholder, the Send-button label, and what happens on send.

## Data model

### Plot thread types: two flags, label flips

The three "types" Note / Task / Chat collapse to two existing flags:

- `task` — first note on the thread carries `Tag.task`
- `shared` — thread has 1+ contacts other than the author

Labels are functions of these:

| Label | Conditions |
|---|---|
| Note | `!task && !shared` |
| Task | `task` (regardless of `shared`) |
| Chat | `!task && shared` |

Note → Chat is a one-way auto-flip: adding the first contact flips Note's label to Chat; removing all contacts does **not** flip back. Sticky implementation: a draft-local boolean `hadContactsThisSession` is set the moment the first contact is added during compose; once true, the label remains Chat for the rest of that compose session. Not persisted — a fresh compose without contacts starts as Note again.

Plot threads can be Task even when shared (a shared task is fine). Connectors **cannot** be Task — Tasks are a Plot-only construct.

### Per-note recipient subset: generalize `Note.accessContacts`

Today `Note.accessContacts` is treated as a binary private flag: `null` = public, `[self]` = private. Generalize the semantics:

- `null` → thread default (all thread members)
- a list → explicit recipient subset and visibility set (those are the same set under the new model). Always includes `self` (the author can always see their own note).
- `[self]` → the "Private note" shortcut state

Connectors with `sharingModel: "message"` (e.g. Gmail) use the subset as the outbound recipient list, computed as `accessContacts.where((c) => c != self)` — the author is the sender, not a recipient. Connectors with `sharingModel: "channel"` (e.g. Linear) ignore subsets that aren't `[self]` — Private note (`[self]`) still means "do not post to the connector at all," matching today's behavior. Any other non-null subset on a channel-mode connector is treated as if `accessContacts` were `null` for connector-output purposes (the subset still affects Plot-side visibility).

**`Note.isPrivate` getter** in `apps/plot/lib/store/note.dart` keeps its current UI semantics — it returns `true` iff `accessContacts != null && accessContacts.length == 1 && accessContacts.contains(self)`. The UI uses it to render the "Private note" active state on the pill. The generalized model lives at the data layer; the getter is the narrow UI shortcut.

**No schema change.** The column already accepts arbitrary contact-id lists; only the interpretation changes in the API and Flutter app.

### "Truly private" connectors

A connector whose `LinkTypeConfig.sharingModel` is unset (or null) has no sharing concept at all (e.g. Google Keep, Obsidian). The Private note pill is suppressed for these — every note in such a connector is implicitly private to the user.

## SDK changes (`public/twister/src/tools/integrations.ts`)

Add four optional strings to `LinkTypeConfig`:

```ts
composePlaceholder?: string;  // e.g. "Send a Gmail email" — NewThreadPage editor placeholder when this link type is the target
composeVerb?: string;         // e.g. "Send" — NewThreadPage send-button label
replyPlaceholder?: string;    // e.g. "Reply" — in-thread editor placeholder for the default reply pill
replyVerb?: string;           // e.g. "Send" — in-thread send-button label
```

**Derivation when unset.** Flutter falls back to existing copy generators:

- `composePlaceholder` → `"Create a new ${connectorName} ${label.toLowerCase()}"` (current `composerHintForNewThread`)
- `composeVerb` → `"Create"`
- `replyPlaceholder` → `"Add a ${noteLabel?.toLowerCase() ?? "note"}"` (current `composerHintForNote`)
- `replyVerb` → `"Send"`

**Connector updates in this PR series:**

- `public/connectors/gmail/src/gmail.ts` → `composePlaceholder: "Send a Gmail email"`, `composeVerb: "Send"`, `replyPlaceholder: "Reply"`, `replyVerb: "Send"`.
- `public/connectors/linear/src/linear.ts` → `composePlaceholder: "Create a Linear issue"`, `composeVerb: "Create"`, `replyPlaceholder: "Add a comment"`, `replyVerb: "Comment"`.
- Other connectors (`slack`, `google-calendar`, etc.) get conservative defaults via derivation for now; revisit per connector if the derived copy reads awkwardly.

**Twister changeset:** `public/.changeset/<name>.md` with minor bump — `Added: composePlaceholder / composeVerb / replyPlaceholder / replyVerb on LinkTypeConfig`.

**Dart mirror.** `apps/plot/lib/store/link.dart`'s `LinkTypeConfig` mirror gets the four new fields (parsed from snake_case JSON: `compose_placeholder`, `compose_verb`, `reply_placeholder`, `reply_verb`).

## NewThreadPage (placeholder-only change)

Structurally unchanged. The connection chip remains the target picker. The task toggle remains in the editor bottom bar.

**Placeholder rule for the body editor:**

| Target | task | shared | Placeholder | Send button |
|---|---|---|---|---|
| Plot | false | false | Add a note | Save |
| Plot | true | * | Add a task | Save task |
| Plot | false | true (incl. sticky) | Start a chat | Send |
| Connector | false | * | `composePlaceholder` (derived if unset) | `composeVerb` (derived if unset) |

(Task is Plot-only — for connector targets the task toggle is hidden, so the connector row of the table doesn't branch on `task`.)

**Implementation surface:**

- `apps/plot/lib/page/new_thread.dart` — wire `_buildNewThreadBottomBar` send button label and the NoteEditor `hint` parameter through the table above.
- `apps/plot/lib/util/link_type_copy.dart` — add a new helper `composerHintForNewThreadPlot(task, shared)` returning the Plot-specific strings; existing `composerHintForNewThread(cfg)` updated to prefer `cfg.composePlaceholder` over the derived default.

## ThreadPage: `NoteEditorTopBar` widget

**New file:** `apps/plot/lib/widget/note_editor_top_bar.dart`.

### State model

```dart
sealed class TopBarState {}

class PillRowState extends TopBarState {
  final List<TopBarPill> pills;  // size ≥ 1
  final String activeId;
}

class ReplyingState extends TopBarState {
  final Note replyTo;
}

class EditingState extends TopBarState {
  final Note editing;
}

class TopBarPill {
  final String id;            // "note" | "task" | "reply" | "replyOriginal" | "private" | "comment"
  final String label;
  final List<ActorId>? avatarSlot;  // null = no avatars; otherwise render avatar(s) inline
  final VoidCallback onTap;
  final VoidCallback? onAvatarsTap;  // opens the recipient picker; null when avatarSlot is null
}
```

### Rendering

- **PillRowState**: horizontal row of pills using sidebar-strength accent fill on the active pill (`context.colour.colours.accentBackground` at the same lightness used in `style/sidebar.dart` for selected items; foreground tinted toward accent). Inactive pills are transparent with muted foreground; hover fills with the same accent at lower intensity. Border radius 6, padding 5h/11v (slightly tighter than sidebar tiles to fit the editor density).
- **ReplyingState**: the existing reply chrome from `_buildReplyIndicatorContent`. The rendering moves into `NoteEditorTopBar`; the widget exposes `onClearReply` (called from the X button) which the parent `NoteEditor` wires to `ThreadBloc.setReplyTo(null)`. Styling unchanged.
- **EditingState**: same pattern with `_buildEditingIndicatorContent` and an `onCancelEdit` callback. Styling unchanged.

`_buildNoteIndicators()` is deleted from `note_editor.dart`; its responsibility now belongs to `NoteEditorTopBar`.

**Takeover is exclusive.** When `ReplyingState` or `EditingState` is active, the pill row is replaced entirely. Clicking the takeover X clears `replyTo` / `editingNote` and the bar returns to `PillRowState`. Users wanting a private quoted reply or a custom recipient subset must set those from the pill row *first* (the draft preserves `accessContacts` across takeover entry), then click Reply on the feed note. During takeover the recipient picker is not reachable — this is a deliberate consequence of the "takeover replaces the pill row" requirement.

### State computation

`NoteEditor` computes `TopBarState` from:

- `widget.thread` (`null` on NewThreadPage — but the top bar only renders on ThreadPage; NewThreadPage doesn't get the widget)
- `state.replyTo`, `state.editingNote` from `ThreadBloc`
- `state.primaryLinkTypeConfig`
- `widget.draft.tags` (for task / private active state)
- `widget.draft.accessContacts` (for reply avatar set and private active state)
- `widget.thread.contacts` and group membership (for avatar group composition)

Pure function; no I/O. Lives in a new method `_computeTopBarState()` on `_NoteEditorState`.

### Pill set rules

The pills returned are deterministic from thread state:

| Context | Pills (in order) |
|---|---|
| Unshared Plot thread | Note · Task |
| Shared Plot thread | Reply to [avatars] · Reply to [original] (conditional) · Task · Private note |
| Connector, `sharingModel: "message"` (Gmail) | Reply to [avatars] · Reply to [original] (conditional) · Private note |
| Connector, `sharingModel: "channel"` or `"thread"` (Linear, Slack channels) | Comment (or `noteLabel`) · Private note |
| Connector, `sharingModel` unset/null (Google Keep–style) | Single mode pill — label = `noteLabel` (or derived "Note"); pill is always active and not interactive |

**"Reply to [original]" pill conditions:**

- Original thread author is not the current user, AND
- Thread has ≥2 other people besides the user (so reply-all and reply-to-original target different recipient sets)

When shown, it's a single-avatar pill that pre-selects only the original author's contact on tap. It's a one-click equivalent of opening the picker and unchecking everyone except the original author.

### Avatar group interaction

The primary "Reply to" pill embeds the recipient avatar cluster inline (single avatar when one recipient, avatar group otherwise). Recipients are computed from the thread:

- **Contacts** are rendered as individual avatars (up to 3 visible; overflow shown as "+N").
- **Groups** on the thread (`thread.groups`) render as a single group-icon avatar with the group name on hover. The group is treated as one recipient slot in the avatar cluster regardless of member count.

The avatar region is its own tap target — tapping it opens the `RecipientPickerModal` (see below). Tapping the pill label (outside the avatars) selects the Reply mode but doesn't open the picker.

The "Reply to [original]" pill, when shown, behaves the same as any pill — tapping the pill body activates the mode and sets `draft.accessContacts = [self, originalAuthor]`. The single avatar on this pill is decorative (no separate tap target), since the picker would defeat the one-click purpose; users wanting a different subset use the picker on the main "Reply to" pill.

### Active-pill behavior

| Active pill | Placeholder | Send button label |
|---|---|---|
| Note | Add a note | Save |
| Task | Add a task | Save task |
| Reply (Plot shared) | Reply | Send |
| Reply (Gmail) | `replyPlaceholder` ("Reply") | `replyVerb` ("Send") |
| Reply to [original] | Reply to {name} | Send |
| Comment (Linear) | `replyPlaceholder` ("Add a comment") | `replyVerb` ("Comment") |
| Comment (other channel connectors) | derived from `noteLabel` | "Send" or `replyVerb` |
| Single mode pill (private connector) | `replyPlaceholder` (derived) | `replyVerb` (derived "Send") |
| Private note | Add a private note | Save |

The Send button's label is computed from the active pill at render time — no separate state.

## Recipient picker modal

**New file:** `apps/plot/lib/widget/recipient_picker_modal.dart`. Uses `FormModal` per the project's modal convention (keyboard-navigable, Tab/↑↓/Enter/Esc).

- **Input:** `List<ActorId> threadContacts`, `List<ActorId> currentSelection`, `ActorId self`, optional `ActorId? originalAuthor`.
- **UI:** multi-select list of `threadContacts` (each row: avatar, name, role hint), `self` row pinned and always-selected. "Just me (private)" quick action selects only self. "Reply to original" quick action selects only `originalAuthor` (shown only when `originalAuthor != null && originalAuthor != self`).
- **Output:** the chosen subset (always includes self). Empty selection (besides self) → `[self]` (Private note).
- **Groups are not selectable.** If a thread is shared via `thread.groups`, group members aren't enumerated in the picker. The user's choices reduce to: thread default (group sees it via existing access logic) or Private (`[self]`). A future iteration can add per-member-of-group picking; for now group-shared threads use the default-or-private control set only. The picker UI shows a one-line notice when groups are present ("This thread is shared with {group name} — group members see the default; pick Just me to make this note private").

Written to `draft.accessContacts`. The pill's avatar slot re-renders from the updated subset.

## Bottom bar simplification

`_buildNoteBottomBar()` in `apps/plot/lib/widget/note_editor.dart`:

**Remove:**
- `ToggleSelfTask` button (moved to top pill)
- `ToggleNoteTag(Tag.private)` button (moved to top pill)

**Keep:**
- `AddLink`
- `AttachFile`
- Take-photo (mobile only)
- Twist toggle button (`_buildTwistButton`)
- Save / Send button — `child` now reflects the active-pill Send label (see table above)

## Reply-from-feed flow

When the user clicks "Reply" on a specific note in the feed:

1. `ThreadBloc.setReplyTo(note)` sets the takeover target (existing behavior).
2. `TopBarState` becomes `ReplyingState` — the pill row hides; the loud accent "Replying" chrome shows with the quoted preview and X.
3. Send uses the current `draft.accessContacts` (whatever it was on the pill row before takeover; default = `null` = thread default = reply all).
4. Clicking X clears `replyTo`; bar returns to `PillRowState`.

## Edit flow

Mostly unchanged. Click Edit on an existing note → `ThreadBloc.startEditing(note)` → `TopBarState` becomes `EditingState`. The pill row is replaced by the existing "Editing" chrome. Private and Task state of the note being edited is preserved — those toggles are not editable mid-edit (matches today's behavior where Task and Private buttons are hidden during edit).

## Migration / compatibility

- **Drift schema:** none required. `Note.accessContacts` already exists.
- **Postgres schema:** none required. Visibility queries already handle arbitrary contact subsets via the contacts-OR-groups filter in `user.thread` and related views (see `AGENTS.md` "Thread Visibility Rules").
- **API code review:** audit any reads of `accessContacts.length == 1 && contains(self)` as a private-note check. Re-read as "subset of size 1 = self". Search points:
  - `workers/api/src/` — particularly notification / email-notify paths that compute "is this note private"
  - `apps/plot/lib/store/note.dart:isPrivate` getter — keep it (`accessContacts != null && accessContacts!.contains(self) && accessContacts!.length == 1`) to preserve UI semantics of "this is *the* Private note shortcut"
- **Connector outbound behavior:** Gmail connector must use `accessContacts` (when non-null) as the recipient list for the outbound email, intersected with thread members. This is a behavior change — today Gmail sends to whatever contactRoles define; it must additionally constrain by the per-note subset. Linear ignores `accessContacts` non-null subsets that aren't `[self]` — it only checks "is this note private = do not post."
- **Twister submodule:** changeset + minor version bump per `AGENTS.md` "Changesets" rule.
- **`docs/updates.md`:** add a single bullet at the top — "Pick recipients per message: tap the avatars in the new note bar to choose who sees a reply, or use the Private note button to keep it to yourself."
- **`docs/features.md`:** add a short section on note composition (Note / Task / Chat for Plot threads; mode pills and per-message recipients for shared threads and connectors).

## File and function inventory

### New files
- `apps/plot/lib/widget/note_editor_top_bar.dart` — `NoteEditorTopBar` widget, `TopBarState` sealed class, `TopBarPill` data class.
- `apps/plot/lib/widget/recipient_picker_modal.dart` — `RecipientPickerModal` using `FormModal`.

### Modified files
- `public/twister/src/tools/integrations.ts` — four new optional fields on `LinkTypeConfig`.
- `public/connectors/gmail/src/gmail.ts` — set the four new fields; constrain outbound recipients by `accessContacts` when non-null.
- `public/connectors/linear/src/linear.ts` — set the four new fields.
- `public/.changeset/<name>.md` — new changeset.
- `apps/plot/lib/store/link.dart` — mirror four new fields in Dart `LinkTypeConfig` and JSON parser.
- `apps/plot/lib/util/link_type_copy.dart` — `composerHintForNewThread(cfg)` and `composerHintForNote(cfg)` prefer the new SDK strings; new helper `composerHintForNewThreadPlot(task, shared)`.
- `apps/plot/lib/widget/note_editor.dart`:
  - Add `_computeTopBarState()` method.
  - `_buildNoteIndicators()` replaced by `NoteEditorTopBar(state: _computeTopBarState())`.
  - `_buildNoteBottomBar()` strips Task and Private buttons; Save button label becomes a function of the active pill.
  - `_resolvePlaceholder()` returns placeholder based on active-pill table.
- `apps/plot/lib/page/new_thread.dart`:
  - Wire NoteEditor `hint` parameter to the placeholder table.
  - Wire send button label to `composeVerb` / Plot defaults.
  - Track draft-local `hadContactsThisSession` to make "Chat" label sticky.
- `apps/plot/lib/page/thread.dart` — no structural change; `NoteEditor` continues to receive thread state and pass it through.

### Tests
Per the project's testing conventions, these are widget tests in `apps/plot/test/`:

- `note_editor_top_bar_test.dart`:
  - Renders `PillRowState` with each of the five pill-set contexts (unshared Plot, shared Plot, Gmail, Linear, Keep-style); asserts pill labels, active state, and avatar slot presence.
  - "Reply to [original]" pill appears only when original-author is not self AND thread has ≥2 other people; covered with three threads.
  - Tapping a pill calls its `onTap`; tapping the avatar region calls `onAvatarsTap` (verified by mock callbacks).
  - `ReplyingState` and `EditingState` render the existing chrome; clicking the X invokes `onClearReply` / `onCancelEdit`.
- `recipient_picker_modal_test.dart`:
  - Pre-selects current `accessContacts`; toggling rows produces the expected subset.
  - "Just me (private)" yields `[self]`; "Reply to original" yields `[self, originalAuthor]`.
  - Keyboard navigation (Tab / ↑↓ / Enter / Esc) works — required by the project's modal convention.
- Update `note_editor_test.dart` (or equivalent) for bottom-bar simplification — assert Task and Private buttons are gone and Save label is computed from active pill.
- Update `new_thread_test.dart` for the placeholder table and the sticky-Chat label behavior.

## Open questions resolved during brainstorm

- **Q: Three discrete modes vs label flip?** Two flags + label flip (Plot-thread-only).
- **Q: "Edit recipients" semantics?** Replaced with avatar-group interaction on the Reply pill; per-note override stored in `Note.accessContacts` (generalized).
- **Q: "Reply" on shared Plot thread vs takeover?** Reply is the default mode (post to thread); takeover is a separate state entered by clicking Reply on a feed note.
- **Q: Pill bar on NewThreadPage?** No — placeholder-only change there.
- **Q: Send button label?** Match the active pill.
- **Q: Note ↔ Chat auto-flip?** One-way (Note → Chat sticky).
- **Q: Truly private connectors?** Suppress Private note pill when `sharingModel` is unset/null; bar shows the single mode pill.

## Out of scope

- A connector mechanism for declaring *multiple* discrete reply modes (e.g. Slack's "reply in thread" vs "send to channel"). The "Reply to [avatars]" + picker pattern covers the recipient-subset case; new mode types would need a follow-up SDK design.
- Reordering or hiding the bottom-bar buttons beyond removing Task and Private. AddLink / AttachFile / take-photo / twist toggle remain in their current order.
- A unified "compose intent" persistence model across threads (e.g. remembering "this user always replies privately on Linear"). Out of scope.
- Updating the visual style of the existing Replying / Editing takeover chrome. It stays as-is; only the default state (pill row) is new.
