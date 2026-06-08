# New-thread URL/link support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a URL is present in the NewThreadPage step-1 "Start a thread" input (typed, pasted, or shared from the OS), replace the input with a link chip, show only Private notes then link-supporting Channels in a link-specific MRU order, and on selecting a destination open the compose screen with the link added to the **note** (never the thread).

**Architecture:** Client-only (Flutter, `apps/plot`). A new `linkMru` map in `LocalPreferencesBloc` mirrors the existing connection MRU. A pure `linkModeSections` helper transforms the at-rest `ComposeSections` (drop people/twists, filter channels to `LinkTypeConfig.supportsLinks`, order by link MRU). `ComposeSectionsView` gains a fixed-height header zone that swaps the search field for a link chip, and reorders sections in link mode. `NewThreadPage` owns the pending-link state, URL detection, share entry, metadata fetch, and adds the link as an `ExternalUserAction` to the draft note on destination select. The empty-body→thread-level-link promotion in `note_editor.dart` is removed so links always stay on the note.

**Tech Stack:** Flutter, flutter_bloc, forui, drift, shared_preferences (via `ProfilePreferences`). Tests use `flutter_test`.

---

## File Structure

- **Modify** `apps/plot/lib/state/local_preferences_state.dart` — add `linkMru` to state.
- **Modify** `apps/plot/lib/state/local_preferences.dart` — `recordLinkUsage` / `rankByLinkMru` + persistence.
- **Modify** `apps/plot/lib/state/compose_targets.dart` — top-level `linkModeSections` helper + `loadSections({bool linkMode})`.
- **Modify** `apps/plot/lib/widget/compose/compose_sections_view.dart` — link-mode header swap (field ⇄ chip), section reorder, reload on toggle.
- **Modify** `apps/plot/lib/page/new_thread.dart` — `_PendingLink` state, URL detection, share entry, metadata, clear, wire view, add-to-note on select, record link MRU on submit; pure helper `appendExternalLink`.
- **Modify** `apps/plot/lib/widget/note_editor.dart` — remove empty-body→`AddThreadWithLink` promotion.
- **Test** `apps/plot/test/state/local_preferences_test.dart` — link MRU.
- **Test** `apps/plot/test/state/compose_sections_test.dart` — `linkModeSections`.
- **Test** `apps/plot/test/page/new_thread_link_test.dart` (create) — `appendExternalLink` helper.
- **Test** `apps/plot/test/widget/compose/compose_sections_link_mode_test.dart` (create) — chip swap + section reorder widget test.

All commands run from `apps/plot`. Run a single test file with:
`flutter test test/<path> --reporter expanded`
Lint with: `flutter analyze`

---

## Task 1: Link-specific MRU in `LocalPreferencesBloc`

**Files:**
- Modify: `apps/plot/lib/state/local_preferences_state.dart`
- Modify: `apps/plot/lib/state/local_preferences.dart`
- Test: `apps/plot/test/state/local_preferences_test.dart`

- [ ] **Step 1: Write the failing tests**

Append to `apps/plot/test/state/local_preferences_test.dart` (inside `void main()`, after the existing connection-MRU group):

```dart
  group('LocalPreferencesBloc link MRU', () {
    test('ranks most-recently-used link destination first, unseen last',
        () async {
      final bloc = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);

      await bloc.recordLinkUsage('A');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await bloc.recordLinkUsage('B');

      // B used most recently → first; A next; C never used → keeps input order last.
      final ranked = bloc.rankByLinkMru(signatures: ['A', 'B', 'C']);
      expect(ranked, ['B', 'A', 'C']);
    });

    test('is independent of the connection MRU', () async {
      final bloc = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);

      await bloc.recordConnectionUsage(channelKey: 'A');
      // Link MRU has no record of A, so rank leaves input order untouched.
      expect(bloc.rankByLinkMru(signatures: ['A', 'B']), ['A', 'B']);
    });

    test('persists across instances', () async {
      final bloc1 = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      await bloc1.recordLinkUsage('A');

      final bloc2 = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      expect(bloc2.rankByLinkMru(signatures: ['B', 'A']), ['A', 'B']);
    });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/state/local_preferences_test.dart --reporter expanded`
Expected: FAIL — `recordLinkUsage` / `rankByLinkMru` are undefined.

- [ ] **Step 3: Add `linkMru` to the state**

In `apps/plot/lib/state/local_preferences_state.dart`, add the field to the constructor, the field declaration, `copyWith`, and `props`:

In the constructor (after `this.reactionMru = const [],`):
```dart
    this.linkMru = const {},
```

After the `reactionMru` field declaration:
```dart
  /// MRU of link destinations, keyed by target signature
  /// ([ComposeTarget.signature]) → last-used epoch ms. Independent of
  /// [connectionMru]: it ranks where the user last *attached a link*, which
  /// drives the link-mode order of the new-thread step-1 picker.
  final Map<String, int> linkMru;
```

In `copyWith` params (after `List<Reaction>? reactionMru,`):
```dart
    Map<String, int>? linkMru,
```

In the `copyWith` body (after `reactionMru: reactionMru ?? this.reactionMru,`):
```dart
      linkMru: linkMru ?? this.linkMru,
```

In `props`, replace the list with:
```dart
  List<Object?> get props =>
      [mentionMruIds, showAllPriorities, connectionMru, reactionMru, linkMru];
```

- [ ] **Step 4: Add record / rank / persistence to the bloc**

In `apps/plot/lib/state/local_preferences.dart`:

Add a key constant beside the others (after `static const String _kReactionMruKey = 'reaction_mru';`):
```dart
  static const String _kLinkMruKey = 'link_mru';
  static const int _maxLinkMruItems = 100;
```

Add the methods (place after `lastUsedConnectionKey`, before `sortByMentionMru`):
```dart
  /// Record that the user just attached a link to a thread filed at
  /// [signature] (a [ComposeTarget.signature]). Bumps its link-MRU timestamp.
  Future<void> recordLinkUsage(String signature) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final next = Map<String, int>.from(state.linkMru);
    next[signature] = now;
    // Cap: drop the oldest entries beyond the limit so the map can't grow
    // unbounded across a long-lived profile.
    if (next.length > _maxLinkMruItems) {
      final ordered = next.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      next
        ..clear()
        ..addEntries(ordered.take(_maxLinkMruItems));
    }
    emit(state.copyWith(linkMru: next));
    await _persistLinkMru();
  }

  /// Reorder [signatures] by link-MRU recency: signatures with a recorded link
  /// use sorted by timestamp descending, then signatures with no recorded use
  /// preserving their input order. Mirrors [rankSignaturesByMru].
  List<String> rankByLinkMru({required List<String> signatures}) {
    final mru = state.linkMru;
    final seen = <String>[];
    final unseen = <String>[];
    for (final sig in signatures) {
      if (mru.containsKey(sig)) {
        seen.add(sig);
      } else {
        unseen.add(sig);
      }
    }
    seen.sort((a, b) => mru[b]!.compareTo(mru[a]!));
    return [...seen, ...unseen];
  }
```

Add the persistence helper (after `_persistReactionMru`):
```dart
  Future<void> _persistLinkMru() async {
    final prefs = ProfilePreferences.instance;
    await prefs.setString(_kLinkMruKey, jsonEncode(state.linkMru));
  }
```

Load it in `_loadFromPreferences` — add before the final `emit(...)`:
```dart
    final linkMruJson = prefs.getString(_kLinkMruKey);
    Map<String, int> linkMru = const {};
    if (linkMruJson != null && linkMruJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(linkMruJson) as Map<String, dynamic>;
        linkMru = decoded.map((k, v) => MapEntry(k, (v as num).toInt()));
      } catch (_) {
        linkMru = const {};
      }
    }
```

And add `linkMru: linkMru,` to the `state.copyWith(...)` call at the end of `_loadFromPreferences`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test test/state/local_preferences_test.dart --reporter expanded`
Expected: PASS (all groups).

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/state/local_preferences.dart apps/plot/lib/state/local_preferences_state.dart apps/plot/test/state/local_preferences_test.dart
git commit -m "feat(app): link-specific MRU in LocalPreferencesBloc"
```

---

## Task 2: `linkModeSections` helper + `loadSections(linkMode:)`

**Files:**
- Modify: `apps/plot/lib/state/compose_targets.dart`
- Test: `apps/plot/test/state/compose_sections_test.dart`

The pure helper drops people & twists, keeps only link-supporting channels (topics always qualify), and orders channels and focuses by a caller-supplied link-MRU ranking. `loadSections` calls it when `linkMode` is true.

- [ ] **Step 1: Write the failing test**

Append to `apps/plot/test/state/compose_sections_test.dart` (inside `void main()`):

```dart
  group('linkModeSections', () {
    // A focus-note target (always link-capable).
    ComposeTarget focus(String pid) => ComposeTarget.focusNote(
          priorityId: Uuid.fromString(pid),
          teamId: null,
          title: 'Focus $pid',
        );
    // A topic target (Plot-only channel; always link-capable).
    ComposeTarget topic(String tid, String name) => ComposeTarget.topic(
          topicId: Uuid.fromString(tid),
          name: name,
        );

    const p1 = '00000000-0000-0000-0000-0000000000a1';
    const p2 = '00000000-0000-0000-0000-0000000000a2';
    const t1 = '00000000-0000-0000-0000-0000000000b1';

    test('drops people & twists; orders focuses + topics by link MRU', () {
      final base = ComposeSections(
        people: [
          ComposePeopleEntry(
            contacts: [Uuid.fromString(p1)],
            groups: const [],
            inviteEmails: const [],
            display: const _StubPill(),
          ),
        ],
        twists: const [],
        channels: [topic(t1, 'Marketing')],
        focuses: [focus(p1), focus(p2)],
      );

      // Pretend focus p2 is the most-recently-used link destination.
      List<String> rank(List<String> sigs) {
        final f2 = focus(p2).signature;
        return [f2, ...sigs.where((s) => s != f2)];
      }

      final result = linkModeSections(base, rank, perSection: 8);

      expect(result.people, isEmpty);
      expect(result.twists, isEmpty);
      // Topic survives (Plot-only channels always support links).
      expect(result.channels.map((t) => t.label), ['Marketing']);
      // p2 floated to the front by the link-MRU ranking.
      expect(result.focuses.map((t) => t.priorityId.toString()), [p2, p1]);
    });
  });
```

Add this minimal stub pill at the top of `void main()` (a `ComposePillData` is required by `ComposePeopleEntry`; the helper never reads it, so a const stub is fine):

```dart
  // (placed near the other local helpers in main)
```

And add this top-level class at the **bottom** of the test file (outside `main`):

```dart
class _StubPill extends ComposePillData {
  const _StubPill();
  @override
  List<Object?> get props => const [];
}
```

Add imports at the top of the test file if missing:
```dart
import 'package:plot/widget/compose/compose_pill.dart';
```

> Note: if `ComposePillData` is not a simple `Equatable` with an unnamed const constructor, replace `_StubPill` with the simplest concrete subclass the analyzer accepts (check `compose_pill.dart`); the helper under test never inspects `display`.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/state/compose_sections_test.dart --reporter expanded`
Expected: FAIL — `linkModeSections` is undefined.

- [ ] **Step 3: Add the `linkModeSections` helper**

In `apps/plot/lib/state/compose_targets.dart`, add this top-level function near `dedupePeopleByRoster` (after the `ComposeSections` class / `_rosterKey`, anywhere at top level):

```dart
/// Transforms at-rest [sections] for **link mode** (a URL is in the picker):
/// drops People & twists, keeps only link-supporting channels (Plot topics
/// always qualify; connector channels qualify when their
/// [LinkTypeConfig.supportsLinks] is true), and orders both the channels and
/// focuses by [rankByLinkMru] (most-recently-used link destination first).
/// [perSection] caps each surviving list.
ComposeSections linkModeSections(
  ComposeSections sections,
  List<String> Function(List<String> signatures) rankByLinkMru, {
  required int perSection,
}) {
  final linkChannels = sections.channels
      .where((t) =>
          t.kind == ComposeTargetKind.topic ||
          (t.linkType?.supportsLinks ?? false))
      .toList();
  return ComposeSections(
    people: const [],
    twists: const [],
    channels: _orderBySignature(linkChannels, rankByLinkMru).take(perSection).toList(),
    focuses: _orderBySignature(sections.focuses, rankByLinkMru).take(perSection).toList(),
  );
}

/// Reorders [items] so their [ComposeTarget.signature]s follow the order
/// [rankByLinkMru] returns. Stable for signatures the ranking leaves in place.
List<ComposeTarget> _orderBySignature(
  List<ComposeTarget> items,
  List<String> Function(List<String> signatures) rankByLinkMru,
) {
  final ranked = rankByLinkMru(items.map((t) => t.signature).toList());
  final pos = {for (var i = 0; i < ranked.length; i++) ranked[i]: i};
  final out = [...items];
  out.sort((a, b) =>
      (pos[a.signature] ?? 1 << 30).compareTo(pos[b.signature] ?? 1 << 30));
  return out;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/state/compose_sections_test.dart --reporter expanded`
Expected: PASS.

- [ ] **Step 5: Wire `linkMode` into `loadSections`**

In `apps/plot/lib/state/compose_targets.dart`, change the `loadSections` signature (line ~676) from:
```dart
  Future<ComposeSections> loadSections({int perSection = 8}) async {
```
to:
```dart
  Future<ComposeSections> loadSections({
    int perSection = 8,
    bool linkMode = false,
  }) async {
```

Then change the channels/focuses construction + the final return. Replace the existing `final channels = <ComposeTarget>[ ... ].take(perSection)...` block and the `final focuses = ...` block and the `return ComposeSections(...)` with:

```dart
    // Plot topics (Plot-only channels) lead the Channels section, most-recently
    // active first, so a just-created topic surfaces at the top.
    final topicTargets = await _topicTargets();
    final allChannels = <ComposeTarget>[
      ...topicTargets,
      for (final t in ctx.createTargets)
        if (!t.isDmType)
          ComposeTarget.connector(
            t,
            connectionCount: ctx.connectionCount(t),
            channelDetail: t.channel?.title,
          ),
    ];

    final allFocuses = <ComposeTarget>[
      for (final f in ctx.focusNoteOrder)
        ComposeTarget.focusNote(
          priorityId: f.priorityId,
          teamId: f.teamId,
          title: ctx.priorityById[f.priorityId]?.displayTitle ?? 'Note',
        ),
    ];

    if (linkMode) {
      // Link mode: only Private notes + link-supporting Channels, link-MRU
      // ordered. People & twists are hidden (links-to-contacts is future work).
      return linkModeSections(
        ComposeSections(
          people: const [],
          twists: const [],
          channels: allChannels,
          focuses: allFocuses,
        ),
        (sigs) => _prefs.rankByLinkMru(signatures: sigs),
        perSection: perSection,
      );
    }

    return ComposeSections(
      people: people,
      twists: twists.take(perSection).toList(),
      channels: allChannels.take(perSection).toList(),
      focuses: allFocuses.take(perSection).toList(),
    );
```

(Delete the now-removed inline `final channels` / `final focuses` declarations and the old `return` — the block above replaces all of them. Leave the `final twists = await _twistTargets(ctx);` and the `people` building above untouched.)

- [ ] **Step 6: Run analyze + the section test**

Run: `flutter analyze lib/state/compose_targets.dart && flutter test test/state/compose_sections_test.dart --reporter expanded`
Expected: analyze clean (no new issues), test PASS.

- [ ] **Step 7: Commit**

```bash
git add apps/plot/lib/state/compose_targets.dart apps/plot/test/state/compose_sections_test.dart
git commit -m "feat(app): link-mode section filtering + ordering for new-thread picker"
```

---

## Task 3: `ComposeSectionsView` link-mode rendering (chip swap + section reorder)

**Files:**
- Modify: `apps/plot/lib/widget/compose/compose_sections_view.dart`
- Test: `apps/plot/test/widget/compose/compose_sections_link_mode_test.dart` (create)

The view gains a `LinkChipData? pendingLink` + `VoidCallback? onClearLink` + uses them to (a) swap the search field for a link chip inside a no-reflow `IndexedStack`, (b) when `pendingLink != null`, order sections **Private notes → Channels** and hide People & twists, (c) load with `linkMode: true` and reload when the pending link toggles.

- [ ] **Step 1: Add the `LinkChipData` value type**

At the top of `compose_sections_view.dart` (after imports, before the widget class), add:

```dart
/// The link currently held in the step-1 picker (URL plus resolved metadata).
/// When non-null the search field is replaced by a chip and the picker renders
/// in link mode.
class LinkChipData {
  const LinkChipData({required this.url, this.title, this.favicon});
  final String url;
  final String? title;
  final String? favicon;

  /// What the chip shows: the resolved title, else the raw URL.
  String get display => (title != null && title!.isNotEmpty) ? title! : url;
}
```

- [ ] **Step 2: Add the constructor params**

Add to the `ComposeSectionsView` constructor (after `this.activeListenable,`):
```dart
    this.pendingLink,
    this.onClearLink,
```

Add the field declarations (after the `activeListenable` field):
```dart
  /// When non-null, the picker is in link mode: the search field is replaced
  /// by a link chip and the sections show Private notes then link-supporting
  /// Channels (People & twists hidden). Null = normal text-filter mode.
  final LinkChipData? pendingLink;

  /// Clears the pending link (the chip's ✕), returning to text-filter mode.
  final VoidCallback? onClearLink;
```

- [ ] **Step 3: Load in link mode + reload on toggle**

In `_ComposeSectionsViewState`, add a getter near the top:
```dart
  bool get _linkMode => widget.pendingLink != null;
```

Change `_loadSections` to pass the flag — replace `.loadSections()` with:
```dart
        .loadSections(linkMode: _linkMode)
```

In `initState`, the at-rest branch must respect link mode (a freshly-shared link mounts straight into link mode with an empty controller). Replace the `initState` body's load decision:
```dart
    // Restore a pre-filled filter (returning from step 2) or load at rest.
    if (!_linkMode && widget.searchController.text.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isDisposed) _runSearch(widget.searchController.text);
      });
    } else {
      _loadSections();
    }
```

Add `didUpdateWidget` (after `dispose`) so toggling the pending link reloads:
```dart
  @override
  void didUpdateWidget(covariant ComposeSectionsView old) {
    super.didUpdateWidget(old);
    if ((old.pendingLink == null) != (widget.pendingLink == null)) {
      _loadSections();
    }
  }
```

- [ ] **Step 4: Reorder sections in link mode (rewrite `_buildSections`)**

Replace the **entire** `_buildSections` method body so the sections are assembled as named locals and ordered per mode (link mode → Private notes then Channels, People & twists hidden; normal mode → People, Channels, Private notes as before):

```dart
  List<PillGridSection> _buildSections() {
    final s = _sections;
    if (s == null) return const [];

    // People & twists (hidden in link mode, where s.people/s.twists are empty).
    final personItems = [
      for (final e in s.people)
        PillGridItem(
          data: e.display,
          onActivate: () => widget.onPickRecipient(e),
          onMore: _rowMoreFor(e.display),
        ),
    ];
    final twistItems = [
      for (final t in s.twists)
        PillGridItem(
          data: TwistPillData(t),
          onActivate: () => widget.onPickTarget(t),
        ),
    ];
    final hasQuery = widget.searchController.text.trim().isNotEmpty;
    final peopleItems =
        hasQuery ? [...twistItems, ...personItems] : [...personItems, ...twistItems];
    final PillGridSection? peopleSection = peopleItems.isEmpty
        ? null
        : PillGridSection(header: _peopleHeader(), items: peopleItems);

    // Channels (Plot topics + connector channels).
    final channelItems = [
      for (final t in s.channels)
        PillGridItem(
          data: t.kind == ComposeTargetKind.topic
              ? TopicPillData(t.label)
              : ChannelPillData(t),
          onActivate: () => widget.onPickTarget(t),
        ),
    ];
    // In normal mode the Channels section is always shown (for the "+ Topic"
    // affordance); in link mode it's shown only when it has link-capable items.
    final PillGridSection? channelSection =
        (_linkMode && channelItems.isEmpty)
            ? null
            : PillGridSection(header: _channelsHeader(), items: channelItems);

    // Private notes (focuses).
    final focusItems = <PillGridItem>[];
    for (final t in s.focuses) {
      final pid = t.priorityId;
      if (pid == null) continue;
      final priority = _priorityById[pid];
      if (priority == null) continue;
      focusItems.add(
        PillGridItem(
          data: FocusPillData(priority),
          onActivate: () => widget.onPickTarget(t),
        ),
      );
    }
    final PillGridSection? focusSection = focusItems.isEmpty
        ? null
        : PillGridSection(header: _sectionHeader('Private note'), items: focusItems);

    // Order: link mode → Private notes, then Channels (people hidden).
    // Normal mode → People, Channels, Private notes (unchanged).
    final ordered = _linkMode
        ? <PillGridSection?>[focusSection, channelSection]
        : <PillGridSection?>[peopleSection, channelSection, focusSection];
    return [for (final sec in ordered) if (sec != null) sec];
  }
```

(Replace the existing `_buildSections` body entirely with the above.)

- [ ] **Step 5: Swap the search field for the chip in a no-reflow zone**

In `build`, replace the `ComposeSearchField(...)` child (the first child of the `Column`) with an `IndexedStack` that holds both the field and the chip so the header never changes height when swapping:

```dart
          IndexedStack(
            alignment: Alignment.centerLeft,
            sizing: StackFit.loose,
            index: _linkMode ? 1 : 0,
            children: [
              ComposeSearchField(
                controller: widget.searchController,
                focusNode: widget.searchFocusNode,
                hint: 'Start a thread',
                hintDetail: 'with a name, email, channel, or focus',
                // Don't autofocus the hidden field when mounting in link mode.
                autofocus: widget.autofocusSearch && !_linkMode,
                activeListenable: widget.activeListenable,
                leading: leading,
                onChanged: _onSearchChanged,
                onArrowDown: () => _gridKey.currentState?.moveHighlight(1),
                onArrowUp: () => _gridKey.currentState?.moveHighlight(-1),
                onSubmit: () => _gridKey.currentState?.activateHighlighted(),
                onEscape: null,
              ),
              _buildLinkChip(context),
            ],
          ),
```

Add the chip builder method (after `_sectionHeader`):
```dart
  /// The link chip shown in place of the search field while in link mode:
  /// favicon (or link icon) + title/url + a ✕ to clear and return to the input.
  Widget _buildLinkChip(BuildContext context) {
    final link = widget.pendingLink;
    final colors = context.theme.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        border: Border.all(color: colors.border, width: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            if (link?.favicon != null)
              LogoImage(
                url: link!.favicon!,
                size: 16,
                fallback: const Icon(PlotIcon.link, size: 16),
              )
            else
              const Icon(PlotIcon.link, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                link?.display ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.theme.typography.sm,
              ),
            ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onClearLink,
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Icon(PlotIcon.close, size: 16, color: colors.mutedForeground),
              ),
            ),
          ],
        ),
      ),
    );
  }
```

Add the imports needed at the top of `compose_sections_view.dart`:
```dart
import 'package:plot/widget/logo_image.dart';
```
(`PlotIcon`, `LogicalKeyboardKey`, theme are already imported. Verify `PlotIcon.close` exists with `grep -n "close" lib/widget/icon.dart`; if the name differs, use the matching constant — e.g. `PlotIcon.x` / `PlotIcon.xmark`.)

- [ ] **Step 6: Write the widget test**

Create `apps/plot/test/widget/compose/compose_sections_link_mode_test.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/compose/compose_sections_view.dart';

void main() {
  test('LinkChipData.display prefers title, falls back to url', () {
    const withTitle = LinkChipData(url: 'https://x.com/a', title: 'Hello');
    const noTitle = LinkChipData(url: 'https://x.com/a');
    expect(withTitle.display, 'Hello');
    expect(noTitle.display, 'https://x.com/a');
    const emptyTitle = LinkChipData(url: 'https://x.com/a', title: '');
    expect(emptyTitle.display, 'https://x.com/a');
  });
}
```

> A full-render widget test of `ComposeSectionsView` requires a `ComposeTargetsBloc` + DB and is covered by run-app verification at the end. This test pins the chip's display logic, which is the pure part most likely to regress.

- [ ] **Step 7: Run analyze + test**

Run: `flutter analyze lib/widget/compose/compose_sections_view.dart && flutter test test/widget/compose/compose_sections_link_mode_test.dart --reporter expanded`
Expected: analyze clean, test PASS.

- [ ] **Step 8: Commit**

```bash
git add apps/plot/lib/widget/compose/compose_sections_view.dart apps/plot/test/widget/compose/compose_sections_link_mode_test.dart
git commit -m "feat(app): link-chip header swap + link-mode section order in compose picker"
```

---

## Task 4: `NewThreadPage` pending-link state, detection, share entry, add-to-note

**Files:**
- Modify: `apps/plot/lib/page/new_thread.dart`
- Test: `apps/plot/test/page/new_thread_link_test.dart` (create)

The page owns the pending link. URL detection runs on the existing filter listener; share sets it at init; metadata fills it; the ✕ clears it; selecting a destination appends the link to the draft note (pure helper `appendExternalLink`) and derives the thread title/icon when untitled; submit records the link MRU.

- [ ] **Step 1: Write the failing test for the pure note helper**

Create `apps/plot/test/page/new_thread_link_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/page/new_thread.dart';
import 'package:plot/store/store.dart';

void main() {
  Note emptyNote() => Note(
        id: Uuid.generate(),
        threadId: Uuid.generate(),
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  group('appendExternalLink', () {
    test('adds an ExternalUserAction with title/favicon', () {
      final note = appendExternalLink(
        emptyNote(),
        url: 'https://x.com/a',
        title: 'Hello',
        favicon: 'https://x.com/favicon.ico',
      );
      final actions = note.actions ?? const <UserAction>[];
      expect(actions.length, 1);
      final a = actions.first as ExternalUserAction;
      expect(a.url, 'https://x.com/a');
      expect(a.title, 'Hello');
      expect(a.favicon, 'https://x.com/favicon.ico');
    });

    test('falls back to url as title when none given', () {
      final note = appendExternalLink(emptyNote(), url: 'https://x.com/a');
      expect((note.actions!.first as ExternalUserAction).title, 'https://x.com/a');
    });

    test('is idempotent for the same url (dedup)', () {
      var note = appendExternalLink(emptyNote(), url: 'https://x.com/a');
      note = appendExternalLink(note, url: 'https://x.com/a', title: 'New');
      expect(note.actions!.whereType<ExternalUserAction>().length, 1);
    });
  });
}
```

> Verify the `Note` constructor's required fields with `grep -n "Note({" lib/store/` and adjust `emptyNote()` to match (the store is generated; required positional/named fields may differ). Keep the test asserting the three behaviors.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/page/new_thread_link_test.dart --reporter expanded`
Expected: FAIL — `appendExternalLink` is undefined.

- [ ] **Step 3: Add the pure helper**

In `apps/plot/lib/page/new_thread.dart`, add a top-level function (place above `class NewThreadWrapper`, after the imports + `kNewThreadInactiveOpacity`):

```dart
/// Returns [note] with an [ExternalUserAction] for [url] appended (deduped by
/// url). When an action for [url] already exists it is replaced with the
/// upgraded title/favicon. Pure — used by the new-thread URL/link flow.
Note appendExternalLink(
  Note note, {
  required String url,
  String? title,
  String? favicon,
}) {
  final actions = [...(note.actions ?? const <UserAction>[])];
  final action = ExternalUserAction(
    title: (title != null && title.isNotEmpty) ? title : url,
    url: url,
    favicon: favicon,
  );
  final idx = actions.indexWhere((a) => a is ExternalUserAction && a.url == url);
  if (idx >= 0) {
    actions[idx] = action;
  } else {
    actions.add(action);
  }
  return note.copyWith(actions: actions);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/page/new_thread_link_test.dart --reporter expanded`
Expected: PASS.

- [ ] **Step 5: Add pending-link page state + import**

Add the import near the other `widget/compose` imports:
```dart
import 'package:plot/widget/compose/compose_sections_view.dart'
    show ComposeSectionsView, LinkChipData;
```
(If `compose_sections_view.dart` is already imported without a `show`, leave it and just ensure `LinkChipData` is visible.)

Add page state fields in `NewThreadPageState` (near `_selectedTarget`):
```dart
  /// The link held in the step-1 picker (typed/pasted/shared URL + metadata).
  /// Non-null ⇒ link mode: the filter input shows a chip and the sections are
  /// Private notes + link-supporting Channels. Added to the draft note only
  /// when a destination is chosen (see [_applyTarget]).
  LinkChipData? _pendingLink;
```

- [ ] **Step 6: Detect a URL in the filter input**

The filter listener is `_onFilterChanged` (wired to `_pickerSearchController`). Find it (`grep -n "_onFilterChanged" lib/page/new_thread.dart`) and add a detection call at its end:
```dart
    _maybeEnterLinkModeFromField();
```

Add the detection method (near `_resolveSharedUrlMetadata`):
```dart
  /// If the filter text is (or contains) an http(s) URL, switch to link mode:
  /// stash the URL as the pending link, clear the field (so it doesn't double
  /// as a filter), and resolve metadata. No-op when already in link mode.
  void _maybeEnterLinkModeFromField() {
    if (_pendingLink != null) return;
    final url = extractHttpUrl(_pickerSearchController.text);
    if (url == null) return;
    _pickerSearchController.clear();
    _enterLinkMode(url);
  }

  /// Enters link mode for [url] and kicks off a metadata fetch.
  void _enterLinkMode(String url) {
    setState(() => _pendingLink = LinkChipData(url: url));
    unawaited(_resolvePendingLinkMetadata(url));
  }

  /// Clears the pending link (chip ✕) and returns to the text filter input.
  void _clearPendingLink() {
    setState(() => _pendingLink = null);
    _focusPickerSearch(_ComposeStep.sections);
  }
```

Add the import for `extractHttpUrl` at the top (it lives in `share_intent.dart`):
```dart
import 'package:plot/share_intent.dart' show extractHttpUrl;
```

- [ ] **Step 7: Resolve metadata into the pending link (not the note)**

Add (near the old `_resolveSharedUrlMetadata`, which is being retired in Step 9):
```dart
  /// Fetches `<title>` + favicon for [url] and folds them into [_pendingLink]
  /// (so the chip shows them). No-op if link mode was cleared or changed.
  Future<void> _resolvePendingLinkMetadata(String url) async {
    try {
      final meta = await fetchUrlMetadata(url);
      if (!mounted) return;
      final current = _pendingLink;
      if (current == null || current.url != url) return;
      if (meta.title == null && meta.favicon == null) return;
      setState(() {
        _pendingLink = LinkChipData(
          url: url,
          title: meta.title ?? current.title,
          favicon: meta.favicon ?? current.favicon,
        );
      });
    } catch (e, s) {
      Tracker.captureException(e, s);
    }
  }
```

- [ ] **Step 8: Share entry → pending link (replace init-time note add)**

In `_applyQueryParametersToDraft`, replace the whole `// Share intent: add the shared URL as a link action on the draft note.` block (the `if (widget.sharedUrl != null && mounted) { ... }`, lines ~727-751) with:
```dart
    // Share intent: enter link mode with the shared URL prefilled. The link is
    // added to the note only when the user picks a destination (see
    // [_applyTarget]); until then it lives as the pending link / chip.
    if (widget.sharedUrl != null && mounted) {
      _enterLinkMode(widget.sharedUrl!);
    }
```

- [ ] **Step 9: Delete the retired `_resolveSharedUrlMetadata`**

Delete the now-unused `_resolveSharedUrlMetadata` method (lines ~754-787) — its job is replaced by `_resolvePendingLinkMetadata` (the link no longer lives on the note pre-select). Confirm no other references: `grep -n "_resolveSharedUrlMetadata" lib/page/new_thread.dart` should print nothing after deletion.

- [ ] **Step 10: Add the link to the note on destination select**

In `_applyTarget`, after the roster/team draft update (`await bloc.updateDraft(updated); if (!mounted) return;`) and before advancing to compose (`setState(() => _step = _ComposeStep.compose);`), insert:
```dart
    // Link mode: attach the pending link to the draft NOTE (never the thread),
    // deriving the thread title/icon from it when the user hasn't set one.
    final link = _pendingLink;
    if (link != null) {
      final latest = bloc.state.draft;
      final note = appendExternalLink(
        bloc.state.draftNote,
        url: link.url,
        title: link.title,
        favicon: link.favicon,
      );
      final hasUserTitle = latest.title?.isNotEmpty ?? false;
      final hasUserIcon = latest.icon?.isNotEmpty ?? false;
      final titledDraft = latest.copyWith(
        title: hasUserTitle ? const Value.absent() : Value(link.display),
        icon: hasUserIcon
            ? const Value.absent()
            : Value(link.favicon ?? 'link'),
      );
      await bloc.updateDraft(titledDraft, note: note);
      if (!mounted) return;
    }
```

- [ ] **Step 11: Wire the view's link params + clear in reset**

In the `ComposeSectionsView(...)` construction (line ~1809), add:
```dart
      pendingLink: _pendingLink,
      onClearLink: _clearPendingLink,
```

In `_resetToFreshStart`, clear the pending link so a fresh compose starts in text mode — add to the `setState(() { ... })` block (alongside `_selectedTarget = null;`):
```dart
      _pendingLink = null;
```

- [ ] **Step 12: Record the link MRU on submit**

In `_onChatSubmitted`, after the existing `recordTarget` block, add:
```dart
    // Link mode: remember this destination as a recent *link* destination so it
    // floats to the top of the next link-mode picker. Independent of the
    // connection MRU recorded above.
    if (target != null) {
      final note = _priorityBloc?.state.draftNote;
      final hasLink =
          note?.actions?.whereType<ExternalUserAction>().isNotEmpty ?? false;
      if (hasLink) {
        unawaited(
          Future(() => prefs.recordLinkUsage(target.signature)).catchError((
            Object e,
            StackTrace s,
          ) {
            Tracker.captureException(e, s);
          }),
        );
      }
    }
```

- [ ] **Step 13: Run analyze + the helper test**

Run: `flutter analyze lib/page/new_thread.dart && flutter test test/page/new_thread_link_test.dart --reporter expanded`
Expected: analyze clean (no new issues), test PASS.

- [ ] **Step 14: Commit**

```bash
git add apps/plot/lib/page/new_thread.dart apps/plot/test/page/new_thread_link_test.dart
git commit -m "feat(app): URL detection, share entry, and link-on-note in new-thread picker"
```

---

## Task 5: Keep links on the note at submit (remove thread-level promotion)

**Files:**
- Modify: `apps/plot/lib/widget/note_editor.dart`

Per the spec's "everywhere" decision, an empty body carrying a link must no longer promote the link to a thread-level `LinkRow`. The thread's title/icon are already derived from the link in Task 4 Step 10, so the `AddThreadWithNote` path produces a well-titled thread whose note holds the link.

- [ ] **Step 1: Remove the empty-body → `AddThreadWithLink` branch**

In `apps/plot/lib/widget/note_editor.dart`, in `_onNewThreadSubmitted`, delete the entire block (lines ~1752-1775):
```dart
    // Empty body + a link → create a thread *about* the link: title and
    // favicon come from the link, no Note is saved, the link is stored as a
    // thread-level LinkRow (matches how thread.dart renders link rows).
    if (body.trim().isEmpty) {
      final firstExternal = widget.draft.actions
          ?.whereType<ExternalUserAction>()
          .firstOrNull;
      if (firstExternal != null) {
        setState(() => _saving = true);
        widget.onSubmitted?.call();
        try {
          await context.run(
            AddThreadWithLink(
              linkUrl: firstExternal.url,
              linkTitle: firstExternal.title,
              linkFavicon: firstExternal.favicon,
            ),
          );
        } finally {
          if (mounted) setState(() => _saving = false);
        }
        return;
      }
    }
```

So that `_onNewThreadSubmitted` falls straight through from the `_finalized`/`_pendingDraftSave` guard to `finalizeThreadDraft(body, ...)` + `AddThreadWithNote(data)` for every submit. The send button already enables empty-body-with-link (`note_editor.dart` ~1602-1608), so an empty body + link still submits — now as a note.

- [ ] **Step 2: Verify the empty-body note path is accepted**

`finalizeThreadDraft` + `AddThreadWithNote` must accept an empty body when the note carries an `ExternalUserAction` (no validation rejection; thread title comes from Task 4's draft derivation). Inspect:

Run: `grep -n "finalizeThreadDraft" lib/widget/note_editor.dart && sed -n '/Future<ThreadWithNote> finalizeThreadDraft/,/^  }/p' lib/widget/note_editor.dart`
Expected: it builds a `ThreadWithNote` from the draft thread + note without requiring non-empty body content. If it throws/early-returns on empty body, add a guard so a note carrying a link action is allowed (mirror the send-button predicate at ~1602-1608). Note any change here in the commit.

- [ ] **Step 3: Confirm `AddThreadWithLink` callers**

Run: `grep -rn "AddThreadWithLink" lib`
Expected: only the class definition in `lib/command/thread.dart` remains (its sole new-thread caller was just removed). Leave the command in place (harmless, possibly used elsewhere later); do not delete it in this plan unless the grep shows it is now entirely unused AND you confirm with the user. If unreferenced, add a `// ignore: unused_element`-style note only if the analyzer flags it (it won't for a public class).

- [ ] **Step 4: Run analyze**

Run: `flutter analyze lib/widget/note_editor.dart`
Expected: clean (no new issues). If `AddThreadWithLink` import is now unused in `note_editor.dart`, remove that import line.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/widget/note_editor.dart
git commit -m "feat(app): keep shared/pasted links on the note, never promote to thread link"
```

---

## Task 6: Full verification

- [ ] **Step 1: Repo-wide analyze**

Run: `flutter analyze`
Expected: no new issues attributable to this change.

- [ ] **Step 2: Run the touched test suites**

Run:
```bash
flutter test test/state/local_preferences_test.dart test/state/compose_sections_test.dart test/page/new_thread_link_test.dart test/widget/compose/compose_sections_link_mode_test.dart --reporter expanded
```
Expected: all PASS.

- [ ] **Step 3: Run the broader compose/page suites for regressions**

Run:
```bash
flutter test test/state/compose_targets_test.dart test/widget/compose --reporter expanded
```
Expected: all PASS (no regression from the `loadSections` restructure or the view changes).

- [ ] **Step 4: Manual / run-app verification (use the `run-app` skill)**

Verify in the macOS app:
1. Paste a URL into the "Start a thread" field → the field becomes a link chip (no page shift); sections show **Private notes** then **Channels** (only link-supporting connections); People & twists hidden.
2. The chip's ✕ returns to the text input; sections return to normal (People, Channels, Private notes).
3. Pick a Private-note focus → compose screen opens with the link chip in the editor; submit with an empty body → a thread is created whose **note** shows the link (no separate thread-level link row); thread title/icon derived from the link.
4. Repeat with a different destination, then paste a URL again → the most recently used destination now sorts first in its list (link MRU).
5. Share a link from another app (Share sheet) → NewThreadPage opens in link mode with the URL prefilled as a chip.

- [ ] **Step 5: Finalize**

Run the `/finalize` checklist (lint, backwards-compat, error capture, docs). Add a user-facing line to `docs/updates.md` such as: "Share or paste a link when starting a thread — Plot now suggests the best notes and channels to drop it into, and keeps the link in your note." Update `docs/features.md` if link-sharing warrants a feature entry.

---

## Self-Review notes (for the executor)

- **Spec coverage:** §1 link state → Task 4; §2 chip swap → Task 3; §3 section reorder + channel filter → Tasks 2–3; §4 link MRU → Tasks 1, 4; §5 add-to-note on select + title/icon → Task 4 Step 10; §6 submit keeps link on note → Task 5; share entry → Task 4 Step 8.
- **Type consistency:** `recordLinkUsage(String)` / `rankByLinkMru({required List<String> signatures})` (Task 1) are the exact names called in Tasks 2 and 4. `linkModeSections(ComposeSections, rankFn, {required perSection})` (Task 2) matches its `loadSections` call. `LinkChipData{url,title,favicon,display}` (Task 3) matches the page's usage (Task 4). `appendExternalLink(Note, {url,title,favicon})` (Task 4) matches its test and call site.
- **Store-shape caveats:** the `Note` constructor (test, Task 4 Step 1) and `ExternalUserAction` fields are generated/store types — verify exact required params with `grep` before finalizing each test, as instructed inline.
- **Icon name caveat:** `PlotIcon.close` (Task 3 Step 6) — confirm the constant name in `lib/widget/icon.dart`; substitute the correct one if different.
