# Reply tabs for message threads + simplified Plot/twist threads

**Date:** 2026-06-05
**Status:** Approved design, pending implementation plan
**Area:** `apps/plot` — note editor top bar (reply pill row), recipient picker

## Problem

The note-editor top bar renders "reply" pills with an `AvatarGroup` cluster of
recipients. Two issues:

1. **Plot threads are over-complicated.** Link-less Plot threads (and twist-chat
   threads) currently get message-style pills: `Reply` + `Reply to <original
   author>` + `Private note`, with an avatar cluster and a recipient picker.
   We want these to be chat-like and simple: a single `Reply` (goes to everyone
   on the thread) plus `Private note`. The backend supports per-note audience
   subsets, but the UX is too complex for the chat-like model we want.

2. **Message-thread reply tabs need a clearer recipient affordance.** For
   connector message threads (e.g. Gmail), the avatar cluster should become an
   explicit, labeled affordance: a "Reply all" tab with a recipient count and an
   edit pencil, and a narrow "Reply" tab.

## Scope decision: how sharing model maps to threads

`SharingModel` is a property of a *connector link type config*
(`primaryLinkTypeConfig.sharingModel`). **Plot threads have no connector link**,
so `primaryLinkTypeConfig == null` and they have no `SharingModel` — they are a
special case, not message/thread/channel. Contact roles (To/Cc) also come *only*
from the connector link config (`link.getTypeConfig()?.contactRoles`), so Plot
threads never have roles.

Therefore:
- **Plot threads + twist-chat threads** (link-less) → simplified chat-like pills.
- **Connector message threads** (`SharingModel.message`) → the Reply-all / Reply
  redesign with recipient editing.
- **Connector channel/thread/none threads** → unchanged (single comment pill +
  Private note).

## Design

### A. Plot threads & twist-chat threads (link-less)

Shared Plot threads and twist chats show exactly:

- **`Reply`** — no leading icon, no trailing affordance. Goes to everyone on the
  thread (existing `_activatePlotReply` → `_draftAsThreadDefault()`).
- **`Private note`**.

Drop the `Reply to <original author>` pill, the avatar cluster, and the recipient
picker for these threads. Unshared Plot threads stay as-is (no bar — just a
note).

### B. Connector message threads (`SharingModel.message`)

The narrow "Reply to <original author>" pill appears only when
`_originalAuthorIfDistinct(s) != null` (original author ≠ self AND 2+ other
recipients on the thread). Call that condition **bothTabs**.

**When bothTabs is true:**

- **`[replyAll icon] Reply all  (N) [pencil]`**
  - Leading `FontAwesomeIcons.replyAll` icon.
  - Count `N` = non-self contacts + groups (`_replyAudience(s).total`), rendered
    in a small pill/circle badge.
  - Trailing pencil icon.
  - The `(N) [pencil]` region is a single tap target → opens the recipient
    editor (section C). Brightens on hover. Tooltip: **"Edit recipients"**.
  - `onTap` (the label/body) keeps replying to the whole audience
    (`_activateConnectorReply`).
- **`[reply icon] Reply to <name>`**
  - Leading `FontAwesomeIcons.reply` icon.
  - **No trailing avatar** (the old single avatar is dropped). No editing
    affordance.
- **`Private note`**.

**When bothTabs is false** (0-1 other recipients, or you are the original
author — single reply tab):

- **`Reply  [userPlus]`**
  - **No leading icon**, label is just `Reply` (not "Reply all").
  - Trailing **`FontAwesomeIcons.userPlus`** (`PlotIcon.share`) icon → opens the
    recipient editor (to add people). Tooltip: **"Edit recipients"**.
- **`Private note`**.

Rule of thumb (per user): leading reply/replyAll icons appear **only** when both
reply tabs are shown; otherwise it's a plain "Reply" with no leading icon and a
userPlus add-recipients affordance.

### C. Recipient editor (per-note picker)

Both the pencil (bothTabs) and the userPlus (single) open the existing per-note
`RecipientPickerModal` (`apps/plot/lib/widget/recipient_picker_modal.dart`),
which wraps `PickShared`. One change:

- **Placeholder**: change the picker prompt from `"Share with contact or email"`
  to **`"Select recipients"`**. Thread a `prompt` parameter through
  `PickShared` → `buildSharedSelectionCommands` so only this picker changes; the
  thread-header Share button keeps its existing prompt.

**Role editing is explicitly out of scope** (deferred — see below). The picker
edits *who* receives the reply (per-note `accessContacts`), which already flows
correctly to the Gmail reply path (it filters recipients by the note's
`accessContacts`).

### D. Mechanics

`TopBarPill` (`apps/plot/lib/widget/note_editor_top_bar.dart`) changes:

- **Remove**: `avatarActors`, `avatarTotalCount`, `onAvatarsTap`, and the
  `AvatarGroup` rendering in `_Pill` (no reply pill uses avatars anymore). Remove
  the now-unused `AvatarGroup`/`avatar.dart` import if nothing else needs it.
- **Add**:
  - `IconData? leadingIcon` — drawn before the label (reply / replyAll), only
    when set.
  - `int? recipientCount` — when set, render a small count pill before the edit
    icon.
  - `IconData? editIcon` — pencil or userPlus; null = no edit affordance.
  - `String? editTooltip` — e.g. "Edit recipients".
  - `VoidCallback? onEdit` — opens the recipient editor. The
    `recipientCount` + `editIcon` region is the tap target; it brightens on
    hover and shows `editTooltip`.

`note_editor.dart` `_buildPills` changes per sections A/B. `_replyAudience` is
still used (for the count). `_singleAvatar` is no longer needed (the
reply-to-original avatar is dropped). The recipient-picker open handler
(`_openRecipientPicker`) is reused for both pencil and userPlus.

New FontAwesome glyph `replyAll` is introduced → **bump `FONT_CACHE_VERSION`** in
`scripts/cache-bust-fonts.sh` (web tree-shaking serves a stale font otherwise and
the glyph renders as tofu). `reply` and `userPlus` already ship.

## Out of scope / follow-up: per-message contact roles

The original ask included editing each contact's **role** (To/Cc/Bcc) in the
picker. Investigation showed this is not supportable without new backend work,
and would be misleading if faked at the thread level:

- Notes have no per-recipient role storage — only `accessContacts`/`accessGroups`
  (visibility). Roles live only in `thread.contactMeta` (one thread-wide value
  per contact).
- The Gmail connector's reply path (`onNoteCreated` in
  `public/connectors/gmail/src/gmail.ts`) reconstructs To/Cc from the *original
  message's headers* and never reads `thread.contactMeta`. Only new-email compose
  (`onCreateLink`) honors roles. So a thread-level role change has no effect on a
  reply's To/Cc today.

Supporting per-message role editing would require: a per-note role store (e.g.
`note.role_overrides`), sync-schema exposure, an API endpoint to persist it, and
a change to the Gmail reply path to read roles from the note. Filed as a separate
follow-up; **not** part of this work.

## Testing

- Pill-building unit/widget coverage in `apps/plot`:
  - Plot/twist threads → only `Reply` (no icon, no edit affordance) + `Private
    note`.
  - Message thread, bothTabs → `Reply all` (replyAll icon + count pill + pencil)
    + `Reply to <name>` (reply icon, no avatar) + `Private note`.
  - Message thread, single → `Reply` (no leading icon) + userPlus + `Private
    note`.
- `flutter analyze` clean on changed files.
- Recipient picker shows the `"Select recipients"` placeholder.
- Manual run-app verification of a Gmail thread (both-tabs and single cases) and
  a shared Plot thread.
