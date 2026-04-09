# Thread Visibility UI Enhancements

## Context

The data model for thread/note visibility has been redesigned (see `2026-04-08-thread-visibility-redesign.md`). The database, API, SDK types, and Flutter data layer are updated. This spec covers the remaining UI work that builds on top of the completed data layer.

**Prerequisite PR:** plotday/core#173 (data model changes)
**Prerequisite:** Twister SDK submodule PR with access/accessContacts type changes

## 1. Access Selection Modal

A new modal for managing who can see a thread or note. Follows the `PickNoteAssignee` / `ShowCommands` pattern.

### Behavior

- Opens when tapping the lock icon on a restricted/members thread or private note
- "Make public" option at top (since contact list may be long)
- Current user always shown, can't deselect
- Other priority contacts listed with checkboxes
- For `members` access: member contacts shown checked but not toggleable; only viewer contacts selectable
- Changes apply immediately (no save button — matches assignment modal pattern)

### Layout

```
┌─────────────────────────────┐
│  Thread access              │
│                             │
│  Make public                │
│  ─────────────────────────  │
│  ☑ You            (locked)  │
│  ☐ Alice                    │
│  ☐ Bob                      │
│  ☐ Charlie                  │
└─────────────────────────────┘
```

### Implementation

Create `apps/plot/lib/command/access.dart` with:
- `PickAccessContacts` (extends `ShowCommands`) — opens the modal
- `MakePublicCommand` — sets thread access='public' or note accessContacts=null
- `ToggleAccessContact` — adds/removes a contact from access_contacts
- `LockedSelfAccess` — non-interactive row showing current user

Follow the `PickNoteAssignee` pattern in `apps/plot/lib/command/note.dart` (lines 399-475):
- `commandsBuilder` fetches priority contacts
- `StaticCommandGroup` for "Make public" and self
- `ActorGroup` for priority contacts

### Thread vs Note

The modal works for both threads and notes but with different semantics:
- **Thread**: changes `Thread.access` and `Thread.accessContacts`
- **Note**: changes `Note.accessContacts` only (note access is always a restriction on top of thread)

## 2. NoteEditor Bottom Bar — Lock Icon Updates

### Non-viewer priorities

- Shown in bottom bar, not accented by default (access='members' = everyone)
- Tap → switch to restricted (author only), icon accents
- Tap when restricted → open `PickAccessContacts` modal
- Count badge: total people with access (author + accessContacts), shown only when > 1
- When restricted with accessContacts: show names list below icon (same pattern as assigned tags)

### Viewer priorities

- Shown and accented by default (access='members' = hidden from viewers)
- Tap → open `PickAccessContacts` modal (never direct toggle — making public is a publishing action)
- Count badge: number of viewers in accessContacts (not members), shown starting at 1
- When viewers added: show names list below icon
- On saved/rendered notes: when thread is public, lock icon shown only on hover

### Viewers

- Lock not shown in NoteEditor (viewers cannot toggle access)

### Note-level lock

- Public threads, members: accented by default (accessContacts=[]), tap → modal
- Public threads, viewers: forced private, not shown
- Private threads: default off (accessContacts=null), members can tap to restrict

## 3. Connector Icon (Plug) in Bottom Bar

- Only shown when thread was created by a connector with `handleReplies=true`
- Accented by default (connector is in mentions)
- Tap toggles off/on (removes/adds connector from note mentions)
- Toggling off skips connector processing for that note

### Implementation

In `_buildNoteBottomBar()`:
- Check `threadState.threadTwists` for a source with `handleReplies` that matches `thread.createdBy`
- Render `Button.icon` with plug icon, selected state based on connector being in draft mentions
- Create `ToggleConnectorMention` command in `note.dart` or a new file

## 4. Twist Icon in Bottom Bar

- Shown when priority has twists (non-source priority twists)
- Tap when off → show twist picker (single select via `ShowCommands`)
- Tap when on → toggle off (remove twist from mentions)
- Default: on if last note in thread mentioned a twist or is from a twist; if user toggles off, next note defaults off too

### Implementation

- Remove the existing twist toggle chips above the editor (`_buildTwistToggleChip` method)
- Add twist icon to bottom bar
- Create `PickTwistMention` (extends `ShowCommands`) for single-select picker
- Create `ToggleTwistMention` for toggling off
- Track selected twist in `NoteEditorState`

## 5. Access Names Display

Show names of `access_contacts` below the lock icon, using the same pattern as assigned tag names.

- For restricted threads (non-viewer priorities): show contact names
- For members threads with added viewers (viewer priorities): show viewer names
- Follow existing assigned tag name resolution and display pattern

### Where to look

Search for how assigned tag names are displayed in the thread header or note bottom bar. The pattern likely involves resolving ActorIds to Actor names and rendering as a comma-separated list or chips.

## 6. Saved Note Lock Icon Hover (Viewer Priorities)

In the note rendering widget (`apps/plot/lib/widget/note.dart` or similar), when a thread is public in a viewer priority:
- Lock icon shown only on hover
- Tapping it re-restricts the thread (sets access='members')

Follow existing hover-only UI patterns in the codebase.

## Key files

- `apps/plot/lib/widget/note_editor.dart` — bottom bar, twist chips
- `apps/plot/lib/command/note.dart` — PickNoteAssignee pattern to follow
- `apps/plot/lib/command/base.dart` — ShowCommands class
- `apps/plot/lib/store/thread.dart` — Thread model with access/accessContacts
- `apps/plot/lib/store/note.dart` — Note model with accessContacts
- `apps/plot/lib/state/thread.dart` — ThreadBloc state management
- `apps/plot/lib/state/thread_state.dart` — threadTwists getter
- `apps/plot/lib/widget/note.dart` — saved note rendering

## Verification

- Test lock icon in non-viewer vs viewer priorities
- Test note-level lock in public vs private threads
- Test connector icon appears only for handleReplies connectors
- Test twist picker single-select behavior
- Test access modal adds/removes contacts immediately
- Test names display below lock icon
- Test hover lock on saved notes in viewer priorities
