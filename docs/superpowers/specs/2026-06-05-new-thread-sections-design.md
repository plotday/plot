# New Thread — sectioned picker redesign

**Date:** 2026-06-05
**Branch:** `new-thread-sections`
**Status:** Design approved, pending spec review

## Goal

Replace the initial New Thread view (`target` step) — currently a single flat,
searchable list of mixed "targets" — with a light, welcoming view organized into
labelled **sections of pills**. Introduce an intermediate **connection-picker**
step that appears only when a person/group is chosen, so the recipient and the
channel-to-reach-them are picked separately.

The compose surface (NoteEditor + connection/priority/contacts/title fields) is
mostly unchanged; the change is concentrated in step 1's presentation and the new
step 2.

## Current state (what we're changing)

- `apps/plot/lib/page/new_thread.dart` — `NewThreadPageState` drives a two-value
  state machine `enum _ComposeStep { target, compose }`.
- Step 1 (`target`) renders `TargetPickerList`
  (`apps/plot/lib/widget/compose/target_picker_list.dart`): a borderless
  fading-underline filter input over a **flat list** of `ComposeTargetView` rows
  (people/chat, focus-notes, twists, connector channels/DMs), with arrow-key
  navigation via `MoveListSelectionIntent` over a single index.
- Step 2 (`compose`) renders the compose surface with connection/priority/contacts/
  title fields and the NoteEditor.
- Data comes from `ComposeTargetsBloc` (`apps/plot/lib/state/compose_targets.dart`),
  which materializes and ranks `ComposeTarget`/`ComposeTargetView` and records MRU
  via `recordTarget()`. `ComposeTarget` has `kind ∈ {note, chat, connector, twist}`.

## New state machine

```
enum _ComposeStep { sections, connection, compose }
```

- `sections` (step 1) — the sectioned pill picker (replaces `target`).
- `connection` (step 2, NEW) — connection picker; reached **only** from a
  person/group pill.
- `compose` (step 3) — the existing compose surface, largely unchanged.

Transitions:

| From | Action | To |
|---|---|---|
| sections | pick contact/group pill | connection |
| sections | pick twist / channel / private-note pill | compose (skip step 2) |
| connection | pick a connection pill | compose |
| connection | Esc, or click the recipient chip's ✕ | sections (restore step-1 filter text) |
| compose | Esc | connection if a contact/group is involved, else sections |
| compose | tap connection field | connection (contact path) or sections (others) |

## Step 1 — sectioned picker (`sections`)

A **"Start a thread"** search bar at the top: a leading **search icon** glyph +
placeholder "Start a thread" (the existing fading-underline treatment is kept).
Generous vertical spacing separates three sections below it.

### Sections (in order)

1. **People and twists** — header rendered as "People and **twists**" with the word
   "twists" in a muted colour. Pills:
   - **Contact**: avatar + name + email. (`RecipientDisplay`-style data.)
   - **Group** (formal `Group`): count badge (member count) + group name +
     truncated member emails.
   - **Ad-hoc group** (a recent multi-contact combo, not a formal Group): count
     badge + truncated member **names** (no avatar).
   - **Twist** (non-connection twist / assistant): twist logo + name.
   - Hover on any group/ad-hoc pill → tooltip listing **all** member names +
     addresses.
2. **Channels** — non-person destinations only: connector logo + connection name +
   channel (e.g. `#general`, a Linear project). Person-reaching connectors (Gmail,
   Slack DM) do **not** appear here — they surface in step 2.
3. **Private notes** — focus pills: focus icon + focus name in the focus colour.

### Pill visual style (approved: Option A)

Hairline border (≈1px, theme border colour), transparent fill at rest; on
hover/focus a soft fill + slightly stronger border. Not attention-grabbing.
Radius = fully rounded (pill). Avatar/logo ≈ 22–24px, name medium weight, meta
(email/channel) muted.

### Counts & search

- At rest, each section shows up to ~6–8 of its most-relevant/recent pills.
- Typing in the search bar searches the **full** roster (all contacts, groups,
  channels, focuses, twists) via `ComposeTargetsBloc.search()`, and live-filters
  every section. A section with no matches hides its header and itself.
- Empty state: a section with nothing to show at rest is hidden. The Channels
  section's empty state offers a quiet "＋ Add connection" affordance (also shown
  as a trailing affordance when channels exist).

### Selection behaviour

- Contact or group/ad-hoc pill → **step 2** (connection), carrying the selected
  contacts/group.
- Twist pill → **step 3** (compose), no connection step, no contacts field;
  connection field shows the twist.
- Channel pill → **step 3**, no contacts field; channel shown on connection field.
- Private-note (focus) pill → **step 3**, no contacts field; focus shown in the
  priority field, connection = Plot (private).

## Step 2 — connection picker (`connection`)

Reached only from a contact/group. The filter bar **stays pinned in the same
vertical position** as step 1. On entry:

- The step-1 filter text is **stashed** and the field cleared; placeholder becomes
  "Select a connection".
- The chosen recipient is shown as a **leading chip inside the bar** — reusing the
  exact step-1 pill widget (contact pill, or group/ad-hoc pill with count) — with a
  trailing **✕**.
- Below the bar: **connection pills** = Plot (in-app) plus each connector connection
  that can reach the selected contacts (Gmail, Slack DM, etc.), each as
  logo + connection name + reach detail (e.g. account/"direct message"). Ordered
  **MRU for the selected contacts** (most recently used to reach any of them first).
- Typing filters the connection pills.

Back navigation:

- **✕ on the chip, or Esc** → back to step 1, restoring the stashed filter text.
- Picking a connection → step 3.
- Step 2 **always** appears for a contact/group, even when Plot is the only option,
  so the back-stack stays consistent.

## Step 3 — compose surface (`compose`)

Existing compose surface, with these path-dependent rules:

- **Contact path**: contacts field shows the recipients; connection field shows the
  chosen connection. Tapping the connection field returns to **step 2**.
- **Channel path**: **no contacts field**; the **channel is shown on the connection
  field** (logo + connection name + `#channel`). Tapping connection field → step 1.
- **Private-note path**: no contacts field; focus shown in the priority field;
  connection = Plot (private). Tapping connection field → step 1.
- **Twist path**: no contacts field; connection field shows the twist. Tapping
  connection field → step 1.
- **Esc on compose** → step 2 when a contact/group is involved, otherwise step 1.

## Keyboard navigation (2D grid)

Focus starts in the search bar (typing filters). From the bar, ↓ moves focus into
the first pill of the first visible section.

- **←/→** move pill-by-pill within the reading order, wrapping across a section's
  visual rows and across section boundaries.
- **↑/↓** move between **visual rows** (including across section boundaries),
  choosing the pill in the target row nearest by horizontal centre (x-position).
  From the top row, ↑ returns focus to the search bar.
- **Enter** activates the focused pill.
- The same grid model applies to step 2's connection pills.

Because pills wrap, navigation needs **real pill geometry** (rects), not the
current estimated row-height. A small grid-nav helper will track each pill's
position/size (e.g. via keys / a layout-aware model) and resolve ←/→/↑/↓ to the
correct neighbour, plus scroll the focused pill into view.

## Architecture / components

Reuse the data layer and compose surface; replace step-1 presentation and add
step 2.

- **Keep / reuse**:
  - `ComposeTargetsBloc`, `ComposeTarget`, `ComposeTargetView`, `RecipientDisplay`,
    MRU recording (`recordTarget`), and `search()`.
  - The compose surface (`connection_compose_field`, `priority_compose_field`,
    `contacts_compose_field`, `title_compose_field`, NoteEditor) and submission
    (`_onChatSubmitted`).
  - `FocusLabel`, `Avatar`/`AvatarGroup` for rendering.
- **New widgets** (under `apps/plot/lib/widget/compose/`):
  - `ComposePill` — the shared pill (contact / group / ad-hoc / twist / channel /
    focus / connection variants), Option-A styling, hover, optional ✕, hover
    tooltip for groups. Reused as the step-2 leading chip.
  - `ComposeSectionsView` — step 1: search bar + sections of `ComposePill`s + 2D
    grid navigation. Replaces `TargetPickerList` as the `sections`-step body.
  - `ConnectionPickerView` — step 2: pinned bar + leading recipient chip +
    connection pills + 2D grid navigation.
  - `PillGridNavigator` (or similar helper) — geometry-aware ←/→/↑/↓ resolution +
    scroll-into-view, shared by both views.
- **Data shaping** (in `ComposeTargetsBloc` / a thin adapter): produce
  - sectioned results: people+twists, channels, private-note focuses — each limited
    to ~6–8 at rest, expanded by `search()`.
  - "connections that can reach contacts X" with MRU ordering, for step 2.
  - recent ad-hoc multi-contact combos (from recorded MRU targets with >1 contact).
- **State machine**: extend `_ComposeStep` to `{sections, connection, compose}`;
  add `_selectedRecipients` (contacts/group) and `_stashedSectionsQuery`; wire Esc
  / ✕ / connection-field-tap transitions per the table above.

`TargetPickerList` is retired once `ComposeSectionsView` replaces it.

## Out of scope

- No change to thread submission, draft model, priority/contacts/title fields, or
  the NoteEditor itself.
- No backend/schema changes.
- No change to how connections are added/authed (only a quiet affordance link to
  the existing flow).

## Testing & verification

- `flutter analyze` on changed files clean (full-app analyze if any non-nullable
  constructor changes — none expected here).
- Run-app verification of: section layout/spacing; pill style + hover; group hover
  tooltip; typing filters all sections + global search; 2D arrow navigation within
  and across sections; contact → step 2 → connection → compose; ✕/Esc back to step
  1 with filter restored; twist/channel/private-note skip step 2; Esc from compose
  returns to the right step; channel visible on connection field; contacts field
  hidden on channel/private-note/twist paths.

## Open questions / decisions made

- **Section order**: People and twists → Channels → Private notes. (Decided.)
- **Twists live in section 1** (muted in header), selecting one skips step 2.
  (Decided.)
- **Step 2 always shows** for a contact/group, even with a single (Plot) option.
  (Decided — keeps Esc/back consistent.)
- **Channels = non-person destinations only.** (Decided.)
