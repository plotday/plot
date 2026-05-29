# RSVP chip — design

- **Date:** 2026-05-28
- **Status:** Approved (ready for implementation plan)
- **Area:** Flutter app (`apps/plot`)

## Summary

Replace the app's split RSVP UI — a non-interactive count summary on the agenda
plus separate attend/skip/toggle icon buttons in thread rows — with a single,
interactive **RSVP chip**. The chip shows the attendee tally and, through its
colour, the current user's own response. Tapping it opens a standard
`CommandModal` to change the RSVP; hovering it shows a grouped attendee-details
popover. The chip is the one RSVP surface across the app.

## Goals

- One consistent, premium-feeling RSVP component everywhere RSVP appears.
- Surface the user's *own* response prominently (it isn't shown at all today on
  the agenda) without adding clutter.
- Cleaner status iconography; calm, low-saturation colour treatment.
- Fit the agenda's tight row-2 height (`secondarySize * 1.25`, ~16px) with **no**
  row-height growth.
- Make the tally inspectable (who's going/declined/undecided) on hover.

## Non-goals

- No new RSVP value (no "Maybe"/tentative self-RSVP). The backend still stores
  only `attend` / `skip` / `null`; tentative-from-others and no-response both
  render the same neutral grey.
- No backend / schema changes (clearing to `null` is already supported).
- No RSVP UI for solo calendar events (no other invitees).

## Current state (what exists today)

- **Agenda** (`lib/widget/agenda.dart:760-761`): `RsvpSummary(activity, fontSize)`
  rendered as the row-2 trailing widget, gated on `thread.hasOtherAttendees`.
  Lives inside `SizedBox(height: secondarySize * 1.25)` (~16px).
- **`RsvpSummary`** (`lib/widget/thread.dart:1110-1155`): non-interactive. Shows
  `5✓ 2✗ 1?` as plain **text glyphs** — attend `ThemeColor(0)` muted (green),
  skip `ThemeColor(5)` muted (red), undecided `veryMuted` (grey). Only non-zero
  segments. Does **not** show the user's own status.
- **Thread rows** (`lib/widget/thread.dart:773-830`): for calendar events
  (`isLinkScheduleInstance`), separate icon buttons —
  `AttendRsvp` + `SkipRsvp` when `needsRsvp` (no response yet *and*
  `hasOtherAttendees`), otherwise a single `ToggleRsvp` (covers solo events and
  already-responded events). Buttons sit just left of the attendee `AvatarGroup`.
  These show whenever the thread is rendered by its own event timing
  (`showEventTiming`), not only on hover.
- **Avatar group tooltip** (`lib/widget/avatar.dart:407-491`, `_RsvpTooltipContent`):
  on hover over `AvatarGroup`, a flat list of attendees **sorted** attend → skip →
  undecided, each row prefixed with `check` / `xmark` / `question` (FontAwesome)
  and the contact name + email. No section headers. Rendered via Forui `FTooltip`
  (`tipAnchor` above by default, `tooltipBelow` flag flips it).
- **Commands** (`lib/command/thread.dart`): `AttendRsvp` (status `attend`),
  `SkipRsvp` (status `skip`), `ToggleRsvp` (flips attend↔skip). All POST
  `/sync/schedule/status` and optimistically apply `thread.withRsvpStatus(...)`.
  Only `ToggleRsvp` does occurrence-vs-series targeting; `AttendRsvp`/`SkipRsvp`
  always target the series. The three commands are referenced **only** by the
  thread-row buttons — no command-bar / shortcut / menu entries.
- **Backend** (`workers/api/src/app/sync/schedules.ts:284`, RPC
  `user.update_schedule_contact_status`): accepts `status` of `attend`, `skip`,
  or `null` (validated; `null` clears). No changes needed for "Clear response".
- **Data model** (`lib/store/thread.dart`): `currentUserRsvp`,
  `scheduleContacts` (excludes archived), `hasOtherAttendees`
  (`scheduleContacts.length > 1`), `rsvpCounts` `({attend, skip, undecided})`
  counting **all** contacts incl. the user, and `withRsvpStatus(newStatus)`
  (updates the user's contact entries + `currentUserStatus`; handles `null`).
  Thread resolution key includes `currentUserRsvp`
  (`lib/state/priority.dart:247`) so the chip re-resolves when the RSVP changes.

## Design

### 1. `RsvpChip` widget

A new widget replacing `RsvpSummary` (same file region, `lib/widget/thread.dart`).
Signature mirrors today's summary: `RsvpChip({required Thread activity, double? fontSize})`.

**Content**
- Only **non-zero** count segments, in order: going, declined, undecided.
- Each segment = a small **FontAwesome** glyph + tabular-figures number:
  `check` (going), `xmark` (declined), `minus` (undecided — a quiet dash, not a
  question mark).
- No leading status glyph, no separators — the user's own status is carried by
  colour alone (avoids double-icon confusion).
- Example renders: `✓5 –1` (nobody declined), `✓5 ✗2 –1` (all three present).

**Colour = the user's own response (the highlight)**
- Going → green (`ThemeColor(0)`).
- Declined → rose/red (`ThemeColor(5)`).
- No response **or** tentative → neutral muted grey (`plotColors` muted /
  `veryMuted`).
- Background is a tinted/translucent fill of that colour (reuse the existing
  theme-colour helpers — `context.colour.colours.backgroundFromTheme(...)` /
  `fromTheme(..., muted: true)` — the same system today's attend/skip colours use,
  so dark mode is handled by the theme, per the "use app theme, not system
  brightness" rule).
- Count glyphs + numbers are tinted to **match** the chip colour (one cohesive
  tone; no per-count colour differentiation).

**Sizing (fits the tight row)**
- Height-flexible, driven by `fontSize` (as `RsvpSummary` is today). On the
  agenda it's passed `secondarySize` and must fit **within** the existing
  `secondarySize * 1.25` row box — do not grow the row.
- Rounded pill (~radius 8), tight horizontal padding (~6–7px), glyphs ~10px,
  number ~`fontSize`. Hairline border or none — whichever keeps total height ≤
  the row box and reads calm. Verify the fit visually in-app (light + dark).

**Hover**
- Subtle background deepen + soft shadow lift, signalling "tappable".
- Pointer stays the **default desktop arrow** (project rule: it's a control, not
  a link).

**Interaction (tap)**
- The chip is wrapped in a `GestureDetector` (`HitTestBehavior.opaque`) whose
  `onTap` runs a command that opens the picker, and which **absorbs** the tap so
  it does not open the thread or start a block drag.
- Opening uses a standard **`CommandModal`** (chosen for styling + keyboard
  consistency), not a custom anchored popover.

### 2. RSVP picker (`CommandModal`)

- A new `ShowRsvpOptions(thread)` command (extends `ShowCommands`) builds a
  `Commands` with a single `StaticCommandGroup` (prompt e.g. "Your RSVP")
  containing **Going** (`AttendRsvp`), **Not going** (`SkipRsvp`), **Clear
  response** (new `ClearRsvp`). The chip's `onTap` runs it via the
  `BuildContext.run` extension. Routing the open through a `ShowCommands` keeps
  the chip free of Bloc references and makes the picker reusable.
- Each option shows its glyph (`check` / `xmark` / `minus`). Standard
  `CommandModal` keyboard handling applies.

### 3. Commands (`lib/command/thread.dart`)

- **Add `ClearRsvp`**: optimistic `thread.withRsvpStatus(null)`, POST
  `/sync/schedule/status` with `status: null` (clears the user's
  `schedule_contact`).
- **Unify occurrence-vs-series targeting**: extract the targeting logic that
  today lives only in `ToggleRsvp` (target the occurrence only when the user has
  an existing per-occurrence RSVP that isn't inherited from the series; otherwise
  target the series) into a shared helper used by `AttendRsvp`, `SkipRsvp`, and
  `ClearRsvp`. This fixes today's inconsistency where attend/skip always hit the
  series.
- **Remove `ToggleRsvp`** (and its button usage) — no longer referenced once the
  chip replaces the buttons. The doc comment in `lib/store/thread.dart:4398` that
  mentions `ToggleRsvp` should be updated to point at the shared helper.

### 4. Hover popover — shared `RsvpDetails`

- Extract `_RsvpTooltipContent` from `lib/widget/avatar.dart` into a shared,
  public widget (e.g. `RsvpDetails`), upgraded from a flat sorted list to
  **status-group sections**: `GOING` / `NOT GOING` / `UNDECIDED`, each a quiet
  muted header with a count, people listed beneath. The current user's row is
  marked ("you"). **Empty groups are omitted.** Undecided uses the `minus` glyph
  in headers to match the chip (drop the `question` glyph).
- The **chip** shows `RsvpDetails` on hover via Forui `FTooltip` (the same
  hover-tooltip mechanism `AvatarGroup` already uses; honour a `tooltipBelow`-style
  flag for chips near a clipped top edge). The **avatar group** adopts the same
  upgraded `RsvpDetails` so the two surfaces match.
- The chip's own background-deepen remains as the tap affordance; the popover
  carries the detail.

### 5. Placement & gating

- **Show the chip iff** the thread is a calendar event with other invitees —
  i.e. `thread.hasOtherAttendees` (already requires a schedule with >1 contact).
  Solo events show **no** RSVP UI (no chip, no toggle).
- **Agenda** (`lib/widget/agenda.dart`): `RsvpSummary` → `RsvpChip` in the row-2
  trailing slot, now interactive. Same `hasOtherAttendees` gate as today.
- **Thread rows** (`lib/widget/thread.dart`): remove the `AttendRsvp` /
  `SkipRsvp` / `ToggleRsvp` buttons; render a single `RsvpChip` in their place,
  sitting just left of the attendee `AvatarGroup`, gated on
  `isLinkScheduleInstance && hasOtherAttendees`. The grey "no response" chip is
  the RSVP prompt (replaces the explicit needs-RSVP attend/skip pair).

### 6. Web fonts

- The agenda moves from text glyphs `✓ ✗ ?` to FontAwesome `check` / `xmark` /
  `minus`. `minus` is newly referenced. **Bump `FONT_CACHE_VERSION` in
  `apps/plot/scripts/cache-bust-fonts.sh`** so tree-shaken web icon fonts don't
  serve stale glyphs (per `apps/plot/AGENTS.md`).

## Files to change

- `apps/plot/lib/widget/thread.dart` — replace `RsvpSummary` with `RsvpChip`
  (content, colour-by-status, sizing, hover-deepen, `FTooltip` → `RsvpDetails`,
  `GestureDetector` → `ShowRsvpOptions`); remove the RSVP buttons from the thread
  trailing row and insert `RsvpChip`.
- `apps/plot/lib/widget/agenda.dart` — `RsvpSummary` → `RsvpChip` in row-2
  trailing.
- `apps/plot/lib/widget/avatar.dart` — extract `_RsvpTooltipContent` → shared
  `RsvpDetails` with grouped headers; have `AvatarGroup` use it.
- `apps/plot/lib/command/thread.dart` — add `ClearRsvp`; add `ShowRsvpOptions`;
  extract shared occurrence/series targeting helper; use it in
  `AttendRsvp`/`SkipRsvp`/`ClearRsvp`; remove `ToggleRsvp`.
- `apps/plot/lib/store/thread.dart` — update the `ToggleRsvp` doc comment
  (~line 4398).
- `apps/plot/scripts/cache-bust-fonts.sh` — bump `FONT_CACHE_VERSION`.
- `docs/updates.md` — one plain-language line.
- Tests — see below.

## Edge cases & considerations

- **Tap vs row gesture**: the chip's `GestureDetector` must win the tap so the
  agenda block / thread row neither opens nor drags. Use opaque hit behaviour;
  verify on desktop and touch.
- **Counts include the user**: `rsvpCounts` counts the user's own contact, so
  changing your RSVP shifts the tally (e.g. undecided→going moves you from
  `minus` to `check`); the optimistic `withRsvpStatus` + resolution-key already
  drive the re-render.
- **Multiple linked contacts**: a user may have >1 contact on a schedule;
  `withRsvpStatus` / the RPC update all of the user's rows. `RsvpDetails` should
  not double-mark "you"; mark the user's row(s) sensibly.
- **Dark mode**: rely on the theme-colour helpers; verify green/rose/grey tints
  and the popover read well in both brightnesses.
- **Height**: the agenda fit is the explicit risk — confirm the pill never
  exceeds `secondarySize * 1.25` and doesn't clip glyphs.
- **`tooltipBelow`**: chips near the top of a clipped scroll area need the
  popover to flip below, as `AvatarGroup` already handles.

## Testing

- Update/replace tests asserting the old `RsvpSummary` text (`✓✗?`) and the
  attend/skip/toggle buttons (`apps/plot/test/...`, incl. the agenda widget /
  block-drag tests that render event rows).
- Add a `RsvpChip` widget test: correct non-zero segments; colour-by-status
  (going/declined/none); tap opens the picker; hidden when no other attendees.
- Add a `RsvpDetails` test: grouped sections, empty groups omitted, "you" marked.
- Add/extend a `ClearRsvp` command test (optimistic clear + correct
  occurrence/series targeting via the shared helper).
- Lint: `cd apps/plot && flutter analyze` on changed files.

## Verification

Run the app (the `run-app` skill) and confirm in a real agenda with a
multi-attendee event: chip fits the row, colour tracks your status, hover shows
the grouped popover, tap opens the picker and changing the RSVP updates both the
chip colour and the tally — in light and dark mode.

## Docs / finalize

- `docs/updates.md`: e.g. "Event RSVPs now show as a single colour-coded chip —
  your response sets the colour, and you can change it or see who's coming right
  from the chip."
- Run `/finalize` before completing.
