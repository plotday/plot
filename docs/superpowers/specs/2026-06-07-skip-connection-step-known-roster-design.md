# Skip the connection step for a previously-used roster

**Date:** 2026-06-07
**Area:** Flutter app — new thread compose flow

## Problem

The new-thread compose flow is three steps: `_ComposeStep.sections → connection →
compose`. Picking a people pill in step 1 (`_pickRecipient`) **always** advances
to the connection step, even when the user has messaged that exact set of
recipients before and there is an obvious "last connection used" to default to.
This adds a needless tap for the common case of replying to the same people the
same way.

## Goal

When the user picks a people pill whose **exact roster** (same contacts, same
groups, same pending invites) matches a roster they have authored a thread to
before, skip the connection step and jump straight to compose, defaulting to the
**most-recently-used** connection for that roster. The user can still change the
connection: tapping the connection field in compose goes "back" to the
connection picker, exactly as it does today.

## Decisions (confirmed with user)

- **Match scope:** exact roster only. A `{Alice}` pick must not borrow a
  connection used with `{Alice, Bob}`.
- **Stale fallback:** if the most-recently-used connection for that roster is no
  longer available (e.g. the Slack/Gmail connection was removed), do **not**
  skip — show the connection step as today.

## How it works today (grounding)

- `ComposeTargetsBloc.loadSections` / `searchSections`
  (`apps/plot/lib/state/compose_targets.dart`) build the step-1 people pills
  (`ComposePeopleEntry`) from `rosterTargets` — used-combo `ComposeTarget`s
  derived from recently authored threads and **ranked most-recently-used first**
  (`buildUsedTargetSignatures` → `rankSignaturesByMru` →
  `_composeTargetForScanThread`). Each `ComposeTarget` carries the concrete
  connection that was used.
- A `ComposePeopleEntry` carries only the roster (`contacts`, `groups`,
  `inviteEmails`) — not its source target.
- `_pickRecipient(entry)` (`apps/plot/lib/page/new_thread.dart`) stashes the
  step-1 query, sets `_selectedRecipient = entry`, and advances to
  `_ComposeStep.connection`.
- `_applyTarget(target)` applies a chosen connection + roster to the draft and
  advances to `_ComposeStep.compose`, then suggests an MRU focus.
- `_backFromCompose()` routes the compose-step "go back" (connection field tap /
  Esc) to the connection step **whenever `_selectedRecipient != null`**, else to
  step 1.
- `connectionsForRoster({contacts, groups, inviteEmails})` returns the
  currently-available connection choices for a roster.

## Design

**Single choke point: `_pickRecipient`.** It becomes `async`. Before advancing to
the connection step it asks the bloc for a remembered, still-available target for
the picked roster:

1. **New bloc method** `ComposeTargetsBloc.lastUsedTargetForRoster({contacts,
   groups, inviteEmails})` → `Future<ComposeTarget?>`:
   - Re-derive the MRU-ranked `rosterTargets` from the cached scan context
     (same source as `loadSections`).
   - Return the **first** (MRU-top) used-combo target whose roster is an **exact**
     match for the requested roster. Exact match compares the contact set, group
     set, and invite set order-insensitively — reuse the existing roster-key
     normalization (`_rosterKey`).
   - **Validate availability:** confirm that target's connection is present in
     `connectionsForRoster(...)` for the same roster (compare by connection
     signature). If absent, return `null`.
   - Return `null` when there is no exact-roster history.

2. **`_pickRecipient(entry)`** (now async):
   - Call `lastUsedTargetForRoster(...)` with the entry's roster.
   - **If a target comes back:** set `_selectedRecipient = entry` (so the
     connection field can navigate back to the connection step), then
     `await _applyTarget(target)` to jump to compose with the remembered
     connection + MRU focus. Do **not** stash/clear the step-1 query the way the
     connection-step path does — `_applyTarget` already moves to compose.
   - **If `null`:** advance to the connection step exactly as today (stash query,
     clear field, set `_selectedRecipient`, set `_step = connection`).

Because the lookup is keyed on the roster and re-derives from the scan, it works
uniformly no matter how the pill was constructed (at-rest list, name-match search
synthesis, or typed email).

### Components / changes

- `apps/plot/lib/state/compose_targets.dart`
  - Add `lastUsedTargetForRoster(...)`.
  - Add a small roster-equality helper if `_rosterKey` isn't directly reusable.
- `apps/plot/lib/page/new_thread.dart`
  - Make `_pickRecipient` async with the skip branch above. Ensure all callers
    `await`/handle the future (or fire it safely) without breaking focus
    management.

### Data flow

people pill picked → `_pickRecipient(entry)` →
`bloc.lastUsedTargetForRoster(entry.roster)`
→ (target) `_selectedRecipient = entry` + `_applyTarget(target)` → compose
→ (null) connection step (unchanged).

Compose connection field tap → `_backFromCompose()` → connection step (works
because `_selectedRecipient` is set on the skip path).

### Error handling

- No history / connection gone → return `null` → show connection step. No error
  surfaced to the user; the flow degrades to today's behavior.
- The lookup reads cached scan data and the local DB cache; any unexpected
  failure should be caught and treated as "no match" (fall through to step 2)
  rather than blocking the pick.

### Testing

Bloc unit tests for `lastUsedTargetForRoster`:
- exact-roster history present + connection available → returns the MRU-top
  target.
- exact-roster history present + that connection removed → returns `null`.
- only a superset roster in history (`{Alice, Bob}` when picking `{Alice}`) →
  returns `null`.
- no history → returns `null`.
- multiple past connections for the roster → returns the most-recent.

## Out of scope

- No schema/migration changes.
- No change to the connection picker UI, MRU recording, or focus suggestion.
- No new persisted state.
