# New-thread URL/link support — design

**Date:** 2026-06-08
**Status:** Approved (ready for planning)
**Area:** `apps/plot` — Flutter app, NewThreadPage compose flow

## Summary

Support starting a thread *about a shared/pasted URL* directly from the
NewThreadPage step-1 picker. When a URL is present in the "Start a thread"
input, the input is replaced by a link chip, the picker reorders to show
**Private notes** then link-supporting **Channels**, ordered by a link-specific
MRU. Selecting a destination opens the usual compose screen with the link
pre-added **to the note** (never promoted to a thread-level link). Share-sheet
intents (iOS/macOS/Android) feed the same path with the URL prefilled.

## Goals

- A URL in the step-1 field switches the picker into "link mode".
- In link mode: show **Private notes** first, then **Channels** filtered to
  connections that support links on notes. Hide People & twists (and Twists).
- Items in both lists are ordered by a **link-specific MRU** — the most recent
  link destinations first — independent of the existing connection MRU.
- Share-sheet content opens NewThreadPage with the URL prefilled.
- Selecting a destination shows the normal compose screen with the link added
  **to the note** (an `ExternalUserAction`), **not** to the thread.
- Submitting keeps the link on the note everywhere (no empty-body → thread-level
  link-bookmark promotion).

## Non-goals

- Sending a link to a contact / DM (People hidden for now; future work).
- Any server/connector change. This is client-only.
- Reworking the step-2 connection picker (link mode never reaches step 2 because
  People are hidden, and focuses/channels are direct targets).

## Background — what already exists

- **Share routing:** `main.dart` buffers shared content via `PendingShare.url`
  using `extractHttpUrl`; `root_provider.dart:284` replays it as
  `NewThreadRoute(sharedUrl: url)`. `NewThreadPage` already accepts a
  `@QueryParam('sharedUrl')`.
- **Init-time link add (to be replaced):** `new_thread.dart:727-751` adds the
  shared URL to the draft note as an `ExternalUserAction` at init, and
  `_resolveSharedUrlMetadata` (`:758`) upgrades title/favicon by URL match.
- **URL helper:** `extractHttpUrl(String?)` in `share_intent.dart:121` (handles
  plain URLs and "Title\nURL" blobs). Reused as the in-field detector.
- **Link-support flag:** `LinkTypeConfig.supportsLinks` (`store/link.dart:63`),
  carried on each `CreateTarget.linkType` (`connection_targets.dart`).
- **Connection MRU infra:** `LocalPreferencesBloc` (`state/local_preferences.dart`)
  with `recordConnectionUsage` / `rankSignaturesByMru` and a persisted
  `connection_mru` map. The link MRU mirrors this shape.
- **Sectioned picker:** `ComposeSectionsView` (`widget/compose/compose_sections_view.dart`)
  renders People & twists / Channels / Private notes from
  `ComposeTargetsBloc.loadSections` / `searchSections`
  (`state/compose_targets.dart:676`). Channels are built from `ctx.createTargets`
  (skipping DM types) plus Plot topics (`:717-726`); focuses from
  `ctx.focusNoteOrder` (`:728-735`).
- **Submit promotion (to be removed):** `note_editor.dart:1755` — an empty body
  with an `ExternalUserAction` calls `AddThreadWithLink` (`command/thread.dart:495`),
  which creates a thread-level `LinkRow` and **archives** the note. This is the
  exact "link on the thread" behavior we are eliminating.

## Design

### 1. Link-mode state on `NewThreadPage`

Add page state:

```dart
class _PendingLink {
  const _PendingLink({required this.url, this.title, this.favicon});
  final String url;
  final String? title;
  final String? favicon;
}

_PendingLink? _pendingLink; // non-null ⇒ link mode
```

- **Enter (paste/type):** the existing `_pickerSearchController` listener
  (`_onFilterChanged`) additionally runs `extractHttpUrl(text)`. On a non-null
  result while not already in link mode: set `_pendingLink = _PendingLink(url:…)`,
  clear the controller text (so it never doubles as a filter), and
  `unawaited(_resolvePendingLinkMetadata(url))`.
- **Enter (share):** in `_applyQueryParametersToDraft`, replace the current
  init-time `ExternalUserAction` add with `setState(() => _pendingLink = …)` and
  a metadata fetch. The link is **not** added to the note until a destination is
  chosen.
- **Metadata:** `_resolvePendingLinkMetadata(url)` calls `fetchUrlMetadata` and,
  if still in link mode for the same `url`, updates `_pendingLink` with the
  resolved title/favicon (drives the chip). Non-fatal on failure (chip shows raw
  URL); unexpected errors → `Tracker.captureException`.
- **Exit (✕):** `setState(() => _pendingLink = null)`, restore the empty input,
  re-focus the field (physical keyboard only), normal sections return.

### 2. Field ⇄ chip swap zone (`ComposeSectionsView`)

`ComposeSectionsView` gains optional inputs: `pendingLink` (url/title/favicon)
and `onClearLink`. The header renders **either** the existing
`ComposeSearchField` **or** a link chip (favicon + title/url + ✕ button), inside
a **fixed-height container** so the swap never reflows the pill grid below.
Chip styling reuses the note-editor's existing link-chip presentation where
practical.

### 3. Section reordering in link mode

A `linkMode` flag flows into section loading. When set:

- Only **Private notes** (focuses) and **Channels** render, in that order;
  People & twists and Twists are omitted.
- Channels are filtered to link-supporting connections:
  `createTarget.linkType.supportsLinks == true`. Plot **topics** always qualify
  (Plot-only notes support links).
- Both lists order by the link MRU (see §4); never-used destinations fall back to
  the current ordering.

Implementation lives in `ComposeTargetsBloc` (it owns `createTargets` + prefs):
`loadSections({bool linkMode = false})` and `searchSections(query, {linkMode})`
produce a `ComposeSections` whose `people`/`twists` are empty and whose
`channels`/`focuses` are filtered + link-MRU-ordered in link mode. The view
already renders empty sections as absent, so hiding falls out naturally.

### 4. Link-specific MRU (`LocalPreferencesBloc`)

- New persisted map `Map<String,int> linkMru` (signature → `lastUsedMs`), prefs
  key `link_mru`, capped like other MRUs.
- `recordLinkUsage(String signature)` — move-to-front by timestamp.
- `rankByLinkMru({required List<String> signatures})` — seen-by-timestamp-desc,
  then unseen in input order (mirrors `rankSignaturesByMru`).
- `linkMruKey(ComposeTarget)` helper derives a stable identity: focus →
  `priorityId`; connector channel → `CreateTarget.key`; topic → `topicId`.
- **Recording:** on submit of a thread whose note carries an `ExternalUserAction`,
  record the chosen target's link key. The chosen target is available on the
  page (`_selectedTarget`); recording is wired where the submit completes.

### 5. Destination select → link on the note

In link mode every destination is a direct target (`_applyDirectTarget`; no step
2 because People are hidden). On pick:

1. Append `_pendingLink` to the draft note as
   `ExternalUserAction(title: title ?? url, url: url, favicon: favicon)`, deduped
   by `url`. Late metadata still upgrades it via the existing URL-matched
   replacement path.
2. When the draft has no user-set title, derive the thread **title/icon** from
   the link metadata (title → thread title, favicon → thread icon), matching the
   old `AddThreadWithLink` titling. This is titling only — the link itself stays
   solely on the note.
3. Advance to compose (`_step = compose`), focus the editor. The link renders as
   a chip in the editor as today.

### 6. Submit keeps the link on the note (global)

Remove the empty-body → `AddThreadWithLink` branch in `note_editor.dart`
`_onNewThreadSubmitted` (`:1755-1775`). Empty-body + link now always flows
through `AddThreadWithNote`, persisting the note with its `ExternalUserAction`.
The send button already enables empty-body-with-link (`:1602-1608`). The thread's
title/icon come from the link-derived draft set in §5.

`AddThreadWithLink` (the command) is left in place for any other callers; planning
will confirm whether the new-thread path was its only caller and, if so, whether
to retire it.

## Data flow

```
share / paste / type URL
  → _pendingLink set (link mode), controller cleared
  → fetchUrlMetadata fills title/favicon → chip updates
  → sections = Private notes, then link-supporting Channels (link-MRU order)
  → pick destination (_applyDirectTarget)
      → ExternalUserAction appended to draft note (dedup by url)
      → thread title/icon derived from link if untitled
      → advance to compose
  → optional body
  → submit → AddThreadWithNote (link stays on note)
  → recordLinkUsage(linkMruKey(target))
```

## Error handling

- Metadata fetch failures are non-fatal (chip shows the raw URL).
- Unexpected errors in new catch blocks call `Tracker.captureException`.
- Malformed paste that isn't an http(s) URL leaves the field as a normal filter
  (`extractHttpUrl` returns null).

## Testing

- **LocalPreferencesBloc:** `recordLinkUsage` / `rankByLinkMru` ordering +
  persistence round-trip; link MRU is independent of connection MRU.
- **ComposeTargetsBloc:** `loadSections(linkMode: true)` hides people/twists,
  filters channels to `supportsLinks`, keeps topics, orders by link MRU.
- **NewThreadPage state:** paste URL → chip (link mode); ✕ → input restored;
  destination select appends an `ExternalUserAction` (not a thread `LinkRow`) and
  advances to compose.
- **Submit:** empty body + link → `AddThreadWithNote`, asserting no `LinkRow` is
  created and the note retains the link action.

## Open items to confirm during planning

- `finalizeThreadDraft` / `AddThreadWithNote` handle an empty body carrying only a
  link action without validation rejection, and produce a sensible thread (title/
  icon from the §5 draft derivation).
- Whether the new-thread submit was the sole caller of `AddThreadWithLink`; retire
  it only if unused.
- Exact reuse of the note-editor link-chip widget for the step-1 chip, vs. a small
  dedicated chip in the compose folder.
