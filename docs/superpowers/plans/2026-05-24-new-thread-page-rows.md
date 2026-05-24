# NewThreadPage Row Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the centered thread-type selector in NewThreadPage with a left-aligned stack of four rows (priority, connections, contacts with lock-led private toggle, and inline title) above the NoteEditor.

**Architecture:** Hoist `_CreateTarget` / `_loadCreateTargets` out of `link_input.dart` into a shared `connection_targets.dart`. Add per-priority MRU tracking for connections in `LocalPreferencesBloc`. Build two new widgets (`ConnectionChip`/`ConnectionPickerModal`, `InlineTitleInput`) plus a `LockChip` helper. Rewrite the NewThreadPage row stack to be left-aligned, drop the separate "Private/with" label row and the title modal, and fire MRU recording in `PriorityBloc.add`.

**Tech Stack:** Flutter, `flutter_bloc`, `forui` (FButton/FTooltip/SelectModal), Drift store entities, `shared_preferences` via `ProfilePreferences`.

**Spec:** `docs/superpowers/specs/2026-05-24-new-thread-page-rows-design.md`

---

## File map

### Modify
- `apps/plot/lib/widget/link_input.dart` — remove `_CreateTarget` + `_loadCreateTargets`; import them from new shared file
- `apps/plot/lib/widget/widget.dart` — add exports for new widget files
- `apps/plot/lib/state/local_preferences.dart` — add connection-MRU API + persistence keys
- `apps/plot/lib/state/local_preferences_state.dart` — add `connectionMru` field
- `apps/plot/lib/command/thread.dart` — fire `recordConnectionUsage` from `AddThreadWithNote.run`
- `apps/plot/lib/page/new_thread.dart` — rewrite layout, drop title modal, integrate new widgets

### Create
- `apps/plot/lib/widget/connection_targets.dart` — shared `CreateTarget` model, `loadCreateTargets()` loader, `createTargetTile()` list-tile builder
- `apps/plot/lib/widget/connection_chip.dart` — `ConnectionChip` widget, `ConnectionPickerModal`
- `apps/plot/lib/widget/inline_title_input.dart` — `InlineTitleInput` widget
- `apps/plot/test/state/local_preferences_test.dart` — unit tests for connection MRU

Widget-level behavior (chip rendering, inline title state transitions) is verified manually in Task 10. The existing test surface for `forui` chips in this project is thin, and stubbing `TwistInstance`/`Channel`/`LinkTypeConfig` for a chip widget test costs more than it pays back.

---

## Task 1: Hoist `_CreateTarget` and `_loadCreateTargets` into shared file

Pure refactor, no behavior change. Keeps LinkModal working unchanged while exposing the same types/loader for the new chip row.

**Files:**
- Create: `apps/plot/lib/widget/connection_targets.dart`
- Modify: `apps/plot/lib/widget/link_input.dart` (drop `_CreateTarget`, `_loadCreateTargets`, refactor `itemBuilder`'s "createExternal" branch to call shared tile builder)
- Modify: `apps/plot/lib/widget/widget.dart` (export new file)

- [ ] **Step 1: Create the shared file**

Write `apps/plot/lib/widget/connection_targets.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/theme.dart' show ThemeBloc;
import 'package:plot/store/store.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/widget.dart';

/// A connector link type the current user can create from Plot. Sourced from
/// enabled channels whose link types declare a `createDefault: true` status.
class CreateTarget {
  CreateTarget({
    required this.twist,
    required this.channel,
    required this.linkType,
    required this.defaultStatus,
  })  : connectorName =
            CreateLinkUserAction.parseTwistName(twist.name).connectorName,
        accountName =
            CreateLinkUserAction.parseTwistName(twist.name).accountName;

  final TwistInstance twist;
  final Channel channel;
  final LinkTypeConfig linkType;
  final LinkStatus defaultStatus;
  final String connectorName;
  final String? accountName;

  /// Stable identity for MRU keying and de-duping.
  String get key => '${twist.id}|${channel.channelId}|${linkType.type}';

  String get title =>
      'Create new $connectorName ${linkType.label.toLowerCase()}';

  String get subtitle =>
      accountName == null ? channel.title : '${channel.title} ($accountName)';

  String get searchText =>
      '$connectorName ${linkType.label} ${channel.title} ${accountName ?? ''}'
          .toLowerCase();

  /// Short label for chip text: "Gmail · thread".
  String get chipLabel =>
      '$connectorName · ${linkType.label.toLowerCase()}';

  CreateLinkUserAction toUserAction() => CreateLinkUserAction(
        twistInstanceId: twist.id.toString(),
        channelId: channel.channelId,
        linkType: linkType.type,
        status: defaultStatus.status,
        connectorName: connectorName,
        linkTypeLabel: linkType.label,
        channelName: channel.title,
        accountName: accountName,
        logo: linkType.logo,
        logoDark: linkType.logoDark,
      );
}

/// Build every create-target available to the current user across all
/// enabled channels.
///
/// A link type opts in by declaring a status with `createDefault: true`.
/// Channel-level linkTypes (dynamic, per-team) take precedence for the
/// status list, but if the channel-level config has no `createDefault`
/// status (typical for connections set up before a connector added the
/// marker), the twist-level linkTypes are consulted for a default. The
/// connector's `onCreateLink` must accept the resulting status id
/// (Linear, for example, resolves a category like "unstarted" to a
/// team-specific state UUID).
Future<List<CreateTarget>> loadCreateTargets() async {
  final channels = await Channel.getAllEnabled();
  final result = <CreateTarget>[];
  for (final channel in channels) {
    final twist = TwistInstance.fromCache(channel.twistInstanceId);
    if (twist == null) continue;
    final channelConfigs = channel.parsedLinkTypes;
    final twistConfigs = twist.parsedLinkTypes;
    if (channelConfigs == null && twistConfigs == null) continue;

    final primaryConfigs = channelConfigs ?? twistConfigs!;
    for (final linkType in primaryConfigs) {
      var defaultStatus = linkType.statuses
          ?.where((s) => s.createDefault)
          .firstOrNull;
      if (defaultStatus == null && channelConfigs != null) {
        defaultStatus = twistConfigs
            ?.where((c) => c.type == linkType.type)
            .firstOrNull
            ?.statuses
            ?.where((s) => s.createDefault)
            .firstOrNull;
      }
      if (defaultStatus == null) continue;
      result.add(CreateTarget(
        twist: twist,
        channel: channel,
        linkType: linkType,
        defaultStatus: defaultStatus,
      ));
    }
  }
  return result;
}

/// Shared list-tile builder for "Create new …" rows in pickers.
ListTile createTargetTile(BuildContext context, CreateTarget target) {
  final isDark = context.read<ThemeBloc>().isDarkMode(context);
  final logo = isDark
      ? (target.linkType.logoDark ?? target.linkType.logo)
      : target.linkType.logo;
  return ListTile(
    leadingBuilder: logo != null
        ? (_, _) => Builder(
              builder: (context) => Padding(
                padding: EdgeInsets.only(
                  left: context.theme.spacing.lg,
                  right: 8,
                ),
                child: LogoImage(
                  url: logo,
                  size: 16,
                  fallback: const Icon(PlotIcon.add, size: 16),
                ),
              ),
            )
        : null,
    icon: logo == null ? PlotIcon.add : null,
    title: target.title,
    subtitle: target.subtitle,
  );
}
```

- [ ] **Step 2: Replace usages in `link_input.dart`**

Open `apps/plot/lib/widget/link_input.dart`. Delete the `_CreateTarget` class (lines ~41–65), delete the `_loadCreateTargets()` static method (lines ~304–340), and delete the `_LinkItem.createExternal` and `createTarget` field (replacing with the public `CreateTarget`).

Replace the imports at the top with:

```dart
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:plot/state/theme.dart' show ThemeBloc;
import 'package:plot/store/store.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/util/url_title.dart' show fetchUrlMetadata;
import 'package:plot/widget/connection_targets.dart';
import 'package:plot/widget/widget.dart' hide Link;
```

Inside `LinkModal.open()`, replace `List<_CreateTarget>? createTargets;` with `List<CreateTarget>? createTargets;` and replace `createTargets ??= await _loadCreateTargets();` with `createTargets ??= await loadCreateTargets();`.

Inside `itemBuilder`, replace the entire `if (item.isCreateExternal) { ... }` block with:

```dart
if (item.isCreateExternal) {
  return createTargetTile(context, item.createTarget!);
}
```

Inside the result-handling block, replace the `_CreateTarget` reference:

```dart
if (item.isCreateExternal) {
  return LinkModalResult.create(item.createTarget!.toUserAction());
}
```

Update the `_LinkItem` private class field type:

```dart
class _LinkItem {
  final _LinkSearchResult? linkResult;
  final CreateTarget? createTarget;
  // ...
  _LinkItem.createExternal(this.createTarget)
      : linkResult = null,
        url = null,
        title = null,
        favicon = null;
  // ...
}
```

- [ ] **Step 3: Export the new file from the widget barrel**

In `apps/plot/lib/widget/widget.dart`, add (alphabetically) after `export 'connection_status_tile.dart';` (or in the right alphabetical slot — check the file):

```dart
export 'connection_targets.dart';
```

- [ ] **Step 4: Verify the refactor compiles**

Run: `cd apps/plot && flutter analyze lib/widget/link_input.dart lib/widget/connection_targets.dart lib/widget/widget.dart`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/widget/connection_targets.dart apps/plot/lib/widget/link_input.dart apps/plot/lib/widget/widget.dart
git commit -m "Extract CreateTarget from LinkModal into shared file"
```

---

## Task 2: Add connection MRU API to `LocalPreferencesBloc`

Per-priority MRU. Storage: a single JSON string in `ProfilePreferences` under `connection_mru` whose shape is `{channelKey: {priorities: {priorityId: epochMs}, last: epochMs}}`. Ranking: priority-specific recency, then global recency, then deterministic alpha.

**Files:**
- Modify: `apps/plot/lib/state/local_preferences_state.dart`
- Modify: `apps/plot/lib/state/local_preferences.dart`
- Test: `apps/plot/test/state/local_preferences_test.dart`

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/state/local_preferences_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/state/local_preferences.dart';
import 'package:plot/util/profile_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ProfilePreferences.init();
  });

  group('LocalPreferencesBloc connection MRU', () {
    test('records per-priority usage and ranks priority-recency first',
        () async {
      final bloc = LocalPreferencesBloc();
      // Ensure async constructor load has settled.
      await Future.delayed(Duration.zero);

      // Use B once globally, A once in priority p1.
      await bloc.recordConnectionUsage(channelKey: 'B', priorityId: 'pX');
      await bloc.recordConnectionUsage(channelKey: 'A', priorityId: 'p1');

      // Rank for p1: A (priority match) before B (global only).
      final ranked = bloc.rankConnectionsByMru(
        keys: ['B', 'A', 'C'],
        priorityId: 'p1',
      );
      expect(ranked, ['A', 'B', 'C']);
    });

    test('within priority, most recent priority use wins', () async {
      final bloc = LocalPreferencesBloc();
      await Future.delayed(Duration.zero);

      await bloc.recordConnectionUsage(channelKey: 'A', priorityId: 'p1');
      await Future.delayed(const Duration(milliseconds: 2));
      await bloc.recordConnectionUsage(channelKey: 'B', priorityId: 'p1');

      final ranked = bloc.rankConnectionsByMru(
        keys: ['A', 'B'],
        priorityId: 'p1',
      );
      expect(ranked, ['B', 'A']);
    });

    test('persists across instances', () async {
      final bloc1 = LocalPreferencesBloc();
      await Future.delayed(Duration.zero);
      await bloc1.recordConnectionUsage(channelKey: 'A', priorityId: 'p1');

      final bloc2 = LocalPreferencesBloc();
      await Future.delayed(Duration.zero);

      final ranked = bloc2.rankConnectionsByMru(
        keys: ['B', 'A'],
        priorityId: 'p1',
      );
      expect(ranked, ['A', 'B']);
    });

    test('unseen keys preserve their input order', () async {
      final bloc = LocalPreferencesBloc();
      await Future.delayed(Duration.zero);

      final ranked = bloc.rankConnectionsByMru(
        keys: ['Z', 'A', 'M'],
        priorityId: 'p1',
      );
      expect(ranked, ['Z', 'A', 'M']);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/state/local_preferences_test.dart`
Expected: FAIL — `The method 'recordConnectionUsage' isn't defined for the class 'LocalPreferencesBloc'` and similar for `rankConnectionsByMru`.

- [ ] **Step 3: Add the `connectionMru` field to state**

Open `apps/plot/lib/state/local_preferences_state.dart` (this is the `part` file of `local_preferences.dart`). Read the existing `LocalPreferencesState` class. Add a new field `connectionMru` of type `Map<String, ConnectionMruEntry>` defaulting to const empty, and include it in `copyWith`, `props`, and the constructor.

If the existing state file is small enough (likely is), add this in the same file before the state class:

```dart
class ConnectionMruEntry extends Equatable {
  const ConnectionMruEntry({
    required this.lastUsedMs,
    required this.priorityLastUsedMs,
  });

  final int lastUsedMs;
  final Map<String, int> priorityLastUsedMs;

  ConnectionMruEntry copyWith({
    int? lastUsedMs,
    Map<String, int>? priorityLastUsedMs,
  }) =>
      ConnectionMruEntry(
        lastUsedMs: lastUsedMs ?? this.lastUsedMs,
        priorityLastUsedMs: priorityLastUsedMs ?? this.priorityLastUsedMs,
      );

  Map<String, dynamic> toJson() => {
        'lastUsedMs': lastUsedMs,
        'priorityLastUsedMs': priorityLastUsedMs,
      };

  factory ConnectionMruEntry.fromJson(Map<String, dynamic> json) =>
      ConnectionMruEntry(
        lastUsedMs: (json['lastUsedMs'] as num).toInt(),
        priorityLastUsedMs: (json['priorityLastUsedMs'] as Map)
            .map((k, v) => MapEntry(k as String, (v as num).toInt())),
      );

  @override
  List<Object?> get props => [lastUsedMs, priorityLastUsedMs];
}
```

Then add to the state class itself: a `connectionMru` field, include it in the constructor with `this.connectionMru = const {}`, in `copyWith`, and in `props`.

- [ ] **Step 4: Add the API and persistence in the bloc**

Open `apps/plot/lib/state/local_preferences.dart`. Add `import 'dart:convert';` at top if not present. Add the new key constant inside the class:

```dart
static const String _kConnectionMruKey = 'connection_mru';
```

Add the public API (place near `recordMentionUsage`):

```dart
/// Record that the user just used [channelKey] (a `CreateTarget.key`) while
/// in [priorityId]. Both this priority's timestamp and the global timestamp
/// are bumped to now so rankings reflect the latest use.
Future<void> recordConnectionUsage({
  required String channelKey,
  required String priorityId,
}) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final next = Map<String, ConnectionMruEntry>.from(state.connectionMru);
  final existing = next[channelKey];
  final priorityMap = Map<String, int>.from(
    existing?.priorityLastUsedMs ?? const {},
  )..[priorityId] = now;
  next[channelKey] = ConnectionMruEntry(
    lastUsedMs: now,
    priorityLastUsedMs: priorityMap,
  );
  emit(state.copyWith(connectionMru: next));
  await _persistConnectionMru();
}

/// Reorder [keys] by MRU. Bucket 1: keys with a recorded use in
/// [priorityId], sorted by that priority's timestamp descending. Bucket 2:
/// remaining keys with any recorded use, sorted by global timestamp
/// descending. Bucket 3: keys with no recorded use, preserving their
/// position in [keys].
List<String> rankConnectionsByMru({
  required List<String> keys,
  required String priorityId,
}) {
  final mru = state.connectionMru;
  final priorityBucket = <String>[];
  final globalBucket = <String>[];
  final unseenBucket = <String>[];
  for (final key in keys) {
    final entry = mru[key];
    if (entry == null) {
      unseenBucket.add(key);
      continue;
    }
    if (entry.priorityLastUsedMs.containsKey(priorityId)) {
      priorityBucket.add(key);
    } else {
      globalBucket.add(key);
    }
  }
  priorityBucket.sort((a, b) {
    final at = mru[a]!.priorityLastUsedMs[priorityId]!;
    final bt = mru[b]!.priorityLastUsedMs[priorityId]!;
    return bt.compareTo(at);
  });
  globalBucket.sort(
    (a, b) => mru[b]!.lastUsedMs.compareTo(mru[a]!.lastUsedMs),
  );
  return [...priorityBucket, ...globalBucket, ...unseenBucket];
}
```

In `_loadFromPreferences()`, add load logic before the `emit`:

```dart
final mruJson = prefs.getString(_kConnectionMruKey);
Map<String, ConnectionMruEntry> connectionMru = const {};
if (mruJson != null && mruJson.isNotEmpty) {
  try {
    final decoded = jsonDecode(mruJson) as Map<String, dynamic>;
    connectionMru = decoded.map(
      (k, v) => MapEntry(
        k,
        ConnectionMruEntry.fromJson(v as Map<String, dynamic>),
      ),
    );
  } catch (_) {
    connectionMru = const {};
  }
}
```

And include `connectionMru: connectionMru` in the `state.copyWith(...)` call.

Add a new private persist helper:

```dart
Future<void> _persistConnectionMru() async {
  final prefs = ProfilePreferences.instance;
  await prefs.setString(
    _kConnectionMruKey,
    jsonEncode(
      state.connectionMru.map((k, v) => MapEntry(k, v.toJson())),
    ),
  );
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd apps/plot && flutter test test/state/local_preferences_test.dart`
Expected: PASS (all 4 tests).

- [ ] **Step 6: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/state/local_preferences.dart lib/state/local_preferences_state.dart test/state/local_preferences_test.dart`
Expected: `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add apps/plot/lib/state/local_preferences.dart apps/plot/lib/state/local_preferences_state.dart apps/plot/test/state/local_preferences_test.dart
git commit -m "Add per-priority connection MRU to LocalPreferencesBloc"
```

---

## Task 3: Fire `recordConnectionUsage` from `AddThreadWithNote`

When the submit-thread command runs, record the corresponding `CreateTarget.key` so the chip row's MRU updates the next time the user opens NewThreadPage. Done at the command level — `LocalPreferencesBloc` is already provided as a global bloc (see `apps/plot/lib/app.dart:52`) so `context.read` is the natural injection point and avoids touching `PriorityBloc` internals.

**Files:**
- Modify: `apps/plot/lib/command/thread.dart` (`AddThreadWithNote.run`, line ~452)

- [ ] **Step 1: Add the MRU recording**

In `apps/plot/lib/command/thread.dart`, modify the body of `AddThreadWithNote.run`:

```dart
@override
Future<CommandReturn> run(BuildContext context) async {
  final priorityBloc = context.read<PriorityBloc>();
  final prefsBloc = context.read<LocalPreferencesBloc>();

  final createAction = _data.note?.actions
      ?.whereType<CreateLinkUserAction>()
      .firstOrNull;

  // Persist the thread + first note before navigating. Running these in
  // parallel with the route flip let a late `_saveDraft` from the
  // disposing NewThreadPage NoteEditor flip the just-published note row
  // back to draft=true, which the sync push filter excludes — the note
  // would then never reach the server.
  final savedThread = await priorityBloc.add(_data.thread, note: _data.note);

  if (createAction != null) {
    await prefsBloc.recordConnectionUsage(
      channelKey:
          '${createAction.twistInstanceId}|${createAction.channelId}|${createAction.linkType}',
      priorityId: savedThread.priority.id.toString(),
    );
  }

  if (!navigate) {
    return const CommandDone();
  }

  if (context.mounted) {
    // Prime the cache so ThreadBlocProvider builds synchronously, skipping
    // a redundant Thread.getOne and the LoadingPage flash.
    priorityBloc.setThread(savedThread);
    await context.router.replace(
      ThreadRoute(threadIdString: savedThread.id.toShortString()),
    );
  }

  return const CommandDone();
}
```

If `LocalPreferencesBloc` is not already imported in `thread.dart`, add:

```dart
import 'package:plot/state/local_preferences.dart';
```

- [ ] **Step 2: Verify it compiles**

Run: `cd apps/plot && flutter analyze lib/command/thread.dart`
Expected: `No issues found!`

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/command/thread.dart
git commit -m "Record connection MRU when AddThreadWithNote runs"
```

---

## Task 4: Build `ConnectionChip` widget and `ConnectionPickerModal`

Single-purpose widget for Row 2 of NewThreadPage. Mirrors the contact chip shape.

**Files:**
- Create: `apps/plot/lib/widget/connection_chip.dart`
- Modify: `apps/plot/lib/widget/widget.dart` (export)

- [ ] **Step 1: Write the widget**

Create `apps/plot/lib/widget/connection_chip.dart`:

```dart
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/theme.dart' show ThemeBloc;
import 'package:plot/store/store.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/widget/connection_targets.dart';
import 'package:plot/widget/widget.dart';

/// A chip that toggles a [CreateTarget] on/off on the current draft.
class ConnectionChip extends StatefulWidget {
  const ConnectionChip({
    super.key,
    required this.target,
    required this.selected,
    required this.onTap,
  });

  final CreateTarget target;
  final bool selected;
  final Future<void> Function() onTap;

  @override
  State<ConnectionChip> createState() => _ConnectionChipState();
}

class _ConnectionChipState extends State<ConnectionChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    const chipRadius = BorderRadius.all(Radius.circular(24));
    final chipPadding = EdgeInsets.symmetric(
      horizontal: 10,
      vertical: isMobilePlatform() ? 10 : 5,
    );
    final isDark = context.read<ThemeBloc>().isDarkMode(context);
    final logo = isDark
        ? (widget.target.linkType.logoDark ?? widget.target.linkType.logo)
        : widget.target.linkType.logo;

    final button = FButton(
      onPress: widget.onTap,
      variant: widget.selected
          ? FButtonVariant.primary
          : FButtonVariant.secondary,
      style: FButtonStyleDelta.delta(
        decoration: FVariantsDelta.delta([
          FVariantOperation.all(
            DecorationDelta.boxDelta(borderRadius: chipRadius),
          ),
        ]),
        contentStyle: FButtonContentStyleDelta.delta(
          padding: EdgeInsetsGeometryDelta.value(chipPadding),
        ),
      ),
      mainAxisSize: MainAxisSize.min,
      prefix: Opacity(
        opacity: widget.selected || _hovered ? 1.0 : (isDark ? 0.5 : 0.9),
        child: logo != null
            ? LogoImage(
                url: logo,
                size: context.theme.iconSizes.sm,
                fallback: Icon(
                  PlotIcon.link,
                  size: context.theme.iconSizes.sm,
                ),
              )
            : Icon(PlotIcon.link, size: context.theme.iconSizes.sm),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 200),
        child: Text(
          widget.target.chipLabel,
          overflow: TextOverflow.ellipsis,
          style: (!widget.selected && !_hovered)
              ? TextStyle(color: context.theme.plotColors.veryMuted)
              : null,
        ),
      ),
    );

    final hoverable = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: button,
    );

    if (widget.target.accountName == null) return hoverable;
    return FTooltip(
      tipBuilder: (context, controller) => Text(widget.target.subtitle),
      child: hoverable,
    );
  }
}

/// Modal listing every create-target. Result is the picked target or null.
class ConnectionPickerModal {
  ConnectionPickerModal._();

  static Future<CreateTarget?> open(BuildContext context) async {
    final targets = await loadCreateTargets();
    if (!context.mounted || targets.isEmpty) return null;

    final result = await SelectModal.open<CreateTarget>(
      context,
      items: (search) async {
        final text = search?.trim().toLowerCase() ?? '';
        final filtered = text.isEmpty
            ? targets
            : targets.where((t) => t.searchText.contains(text)).toList();
        return [SelectGroup(title: 'Create new', items: filtered)];
      },
      itemBuilder: (target, _) => createTargetTile(context, target),
      prompt: 'Pick a connection',
      emptyMessage: 'No connections available',
      showFilter: true,
    );
    if (!result.present) return null;
    return result.value;
  }
}
```

- [ ] **Step 2: Export from the widget barrel**

In `apps/plot/lib/widget/widget.dart`, add the export alphabetically:

```dart
export 'connection_chip.dart';
```

- [ ] **Step 3: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/widget/connection_chip.dart`
Expected: `No issues found!`

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/widget/connection_chip.dart apps/plot/lib/widget/widget.dart
git commit -m "Add ConnectionChip widget and ConnectionPickerModal"
```

---

## Task 5: Build `InlineTitleInput` widget

Chip ↔ input state machine. Owns its own controller and focus; calls back on save/clear.

**Files:**
- Create: `apps/plot/lib/widget/inline_title_input.dart`
- Modify: `apps/plot/lib/widget/widget.dart` (export)

- [ ] **Step 1: Write the widget**

Create `apps/plot/lib/widget/inline_title_input.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/state/theme.dart' show ThemeBloc;
import 'package:plot/style/button.dart' show ghostSizedStyleDelta;
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart';

/// Inline title input for the NewThreadPage row stack. Collapsed shows a
/// sparkles/pen chip; expanded shows a single-line text field.
class InlineTitleInput extends StatefulWidget {
  const InlineTitleInput({
    super.key,
    required this.title,
    required this.onChanged,
  });

  /// Current title (null = no title set).
  final String? title;

  /// Persist a new value. `null` clears.
  final Future<void> Function(String? next) onChanged;

  @override
  State<InlineTitleInput> createState() => InlineTitleInputState();
}

class InlineTitleInputState extends State<InlineTitleInput> {
  bool _expanded = false;
  bool _hovered = false;
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.title ?? '');
    _focusNode = FocusNode();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(InlineTitleInput old) {
    super.didUpdateWidget(old);
    if (!_expanded && widget.title != old.title) {
      _controller.text = widget.title ?? '';
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Expand and focus. Called by the chip on tap and by external code
  /// (e.g. ⌘⇧H shortcut on NewThreadPage).
  void focus() {
    if (!_expanded) {
      setState(() {
        _expanded = true;
        _controller.text = widget.title ?? '';
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _handleFocusChange() {
    if (!_focusNode.hasFocus && _expanded) {
      _commit(_controller.text);
    }
  }

  Future<void> _commit(String value) async {
    final trimmed = value.trim();
    final next = trimmed.isEmpty ? null : trimmed;
    if (next != widget.title) {
      await widget.onChanged(next);
    }
    if (mounted) setState(() => _expanded = false);
  }

  Future<void> _clearAndCollapse() async {
    _controller.clear();
    if (widget.title != null) await widget.onChanged(null);
    if (mounted) setState(() => _expanded = false);
  }

  void _cancel() {
    _controller.text = widget.title ?? '';
    setState(() => _expanded = false);
  }

  @override
  Widget build(BuildContext context) {
    return _expanded ? _buildExpanded(context) : _buildChip(context);
  }

  Widget _buildChip(BuildContext context) {
    final hasTitle = (widget.title ?? '').isNotEmpty;
    final IconData icon;
    final String? label;
    final Color color;
    if (hasTitle) {
      icon = FontAwesomeIcons.pen;
      label = widget.title!;
      color = _hovered
          ? context.theme.colors.foreground
          : context.theme.plotColors.muted;
    } else if (_hovered) {
      icon = FontAwesomeIcons.pen;
      label = 'Set title';
      color = context.theme.colors.foreground;
    } else {
      icon = PlotIcon.sparkles;
      label = 'Title';
      color = context.theme.plotColors.veryMuted;
    }

    final button = FButton(
      onPress: focus,
      variant: FButtonVariant.ghost,
      style: ghostSizedStyleDelta(
        context,
        textStyle: context.theme.typography.sm,
      ),
      mainAxisSize: MainAxisSize.min,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          FaIcon(icon, size: context.theme.iconSizes.base, color: color),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: context.theme.typography.sm.copyWith(
                color: color,
                height: 1,
              ),
            ),
          ),
        ],
      ),
    );

    final hoverable = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: button,
    );

    if (!hasPhysicalKeyboard()) return hoverable;
    return FTooltip(
      tipBuilder: (context, controller) => Text(
        hasTitle ? 'Edit title' : 'Set title',
      ),
      child: hoverable,
    );
  }

  Widget _buildExpanded(BuildContext context) {
    final hasText = _controller.text.trim().isNotEmpty;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _cancel,
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          FaIcon(
            hasText ? FontAwesomeIcons.pen : PlotIcon.sparkles,
            size: context.theme.iconSizes.base,
            color: context.theme.plotColors.muted,
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360, minWidth: 200),
            child: FTextField(
              controller: _controller,
              focusNode: _focusNode,
              hint: 'Title',
              style: context.theme.typography.sm,
              onChange: (_) => setState(() {}),
              onSubmit: _commit,
              textInputAction: TextInputAction.done,
            ),
          ),
          FButton.icon(
            onPress: _clearAndCollapse,
            variant: FButtonVariant.ghost,
            child: Icon(PlotIcon.close, size: context.theme.iconSizes.sm),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Export from barrel**

Add to `apps/plot/lib/widget/widget.dart` (alphabetical):

```dart
export 'inline_title_input.dart';
```

- [ ] **Step 3: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/widget/inline_title_input.dart`
Expected: `No issues found!`

If the analyzer flags any forui API names (`FTextField` field names, `FButton.icon` signature) that don't match what the project actually has, open `apps/plot/lib/widget/note_editor.dart` and `apps/plot/lib/widget/input_tile.dart` to find the canonical text-field invocation and adapt.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/widget/inline_title_input.dart apps/plot/lib/widget/widget.dart
git commit -m "Add InlineTitleInput widget"
```

---

## Task 6: Refactor NewThreadPage row stack to left-aligned

Drop the `Center`/`WrapAlignment.center` wrappers from `_buildThreadTypeSelector` and its rows. No new rows yet — this is the layout-only change so the visual diff stays reviewable.

**Files:**
- Modify: `apps/plot/lib/page/new_thread.dart`

- [ ] **Step 1: Rewrite `_buildThreadTypeSelector`**

Replace the body of `_buildThreadTypeSelector` (currently a `Column` with `CrossAxisAlignment.start` already, but with centered children inside) so each row left-aligns:

```dart
Widget _buildThreadTypeSelector(BuildContext context, PriorityState state) {
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _buildPriorityChipRow(context, state),
      SizedBox(height: context.theme.spacing.md),
      _buildWithSelector(context, state),
    ],
  );
}
```

(The `_buildWithLabel` call is dropped — the lock chip in Task 8 will replace it. Until then, the "with"/Private text just disappears.)

- [ ] **Step 2: Left-align `_buildPriorityChipRow`**

Replace the body of `_buildPriorityChipRow` so it no longer wraps in `Center` or uses `WrapAlignment.center`:

```dart
Widget _buildPriorityChipRow(BuildContext context, PriorityState state) {
  final draftIdStr = state.draft.id.toString();
  final auto = ThreadsBase.autoFileIds.contains(draftIdStr);
  final showLeadingSparkles = !state.context.root && !auto;
  return Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 4,
    runSpacing: 8,
    children: [
      if (showLeadingSparkles) _buildAutoSparklesToggle(context),
      _buildPriorityChip(context, state, auto: auto),
    ],
  );
}
```

- [ ] **Step 3: Left-align `_buildWithSelector`**

Find the existing `_buildWithSelector` `return Center(...)` and replace its outer `Center` + `ConstrainedBox(maxWidth: 500)` + `Column` with a left-aligned `Wrap`:

```dart
Widget _buildWithSelector(BuildContext context, PriorityState state) {
  final selfUuids = Actor.getCurrentUserActorIds()
      .map((a) => a.toUuid())
      .toSet();
  final selectedIds = state.draft.contacts
      .where((id) => !selfUuids.contains(id))
      .toSet();
  final pendingEmails = state.draft.inviteEmails.toSet();
  final groupIds = state.draft.groups.toSet();
  final hasMore =
      selectedIds.length > _pinnedActors.length ||
      pendingEmails.length > _pinnedEmails.length ||
      groupIds.length > _pinnedGroups.length;

  return Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final group in _pinnedGroups)
        _buildGroupChip(context, group,
            selected: groupIds.contains(group.id)),
      for (final actor in _pinnedActors)
        _buildContactChip(context, actor,
            selected: selectedIds.contains(actor.id.toUuid())),
      for (final email in _pinnedEmails)
        _buildEmailChip(context, email,
            selected: pendingEmails.contains(email)),
      for (final suggestion in _pinnedSuggestions)
        switch (suggestion) {
          ActorShareCandidate(:final actor) => _buildContactChip(
              context, actor,
              selected: selectedIds.contains(actor.id.toUuid())),
          GroupShareCandidate(:final group) => _buildGroupChip(
              context, group,
              selected: groupIds.contains(group.id)),
        },
      _buildAddContactChip(context, state, hasMore: hasMore),
    ],
  );
}
```

- [ ] **Step 4: Drop the unused `_buildWithLabel` method**

Delete `_buildWithLabel` entirely from `new_thread.dart` (lines ~845–877).

- [ ] **Step 5: Update single-panel and multi-panel branches in `build`**

Both branches currently call `_buildThreadTypeSelector(context, state)` and (separately) `_buildAutoOrganizeLine(context, state)`. In Task 9 we move the title into the row stack; for now, **leave `_buildAutoOrganizeLine` where it is**. Just verify the layout still compiles.

- [ ] **Step 6: Run analyzer**

Run: `cd apps/plot && flutter analyze lib/page/new_thread.dart`
Expected: `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add apps/plot/lib/page/new_thread.dart
git commit -m "Left-align NewThreadPage row stack"
```

---

## Task 7: Add connection chip row (Row 2)

Wire `loadCreateTargets()`, MRU ranking, chip rendering, and the "more" button.

**Files:**
- Modify: `apps/plot/lib/page/new_thread.dart`

- [ ] **Step 1: Add state fields**

Inside `NewThreadPageState`, after `_pinnedSuggestions`, add:

```dart
/// All available create-targets for this user, loaded once on mount and
/// rerun when the priority changes (so MRU rerank reflects the new
/// priority).
List<CreateTarget> _allConnectionTargets = const [];

/// The 3 chips shown in the connection row, ranked per-priority then
/// global by [LocalPreferencesBloc.rankConnectionsByMru].
List<CreateTarget> _pinnedConnections = const [];
```

Import at the top:

```dart
import 'package:plot/widget/connection_chip.dart';
import 'package:plot/widget/connection_targets.dart';
```

- [ ] **Step 2: Load and rank connections**

Add a new helper and call it from the existing `_loadRecentCandidates()` and `_switchToPriority` / `_switchToAuto`:

```dart
Future<void> _loadConnections() async {
  try {
    final targets = await loadCreateTargets();
    if (!mounted) return;
    setState(() => _allConnectionTargets = targets);
    _refreshPinnedConnections();
  } catch (e, t) {
    log.warning('[NewThreadPage._loadConnections] failed', e, t);
  }
}

void _refreshPinnedConnections() {
  if (_allConnectionTargets.isEmpty) {
    setState(() => _pinnedConnections = const []);
    return;
  }
  final bloc = context.read<PriorityBloc>();
  final priorityId = bloc.state.draft.priority.id.toString();
  final prefs = context.read<LocalPreferencesBloc>();
  final keys = _allConnectionTargets.map((t) => t.key).toList();
  final ranked = prefs.rankConnectionsByMru(
    keys: keys,
    priorityId: priorityId,
  );
  final byKey = {for (final t in _allConnectionTargets) t.key: t};
  setState(() {
    _pinnedConnections =
        ranked.take(3).map((k) => byKey[k]!).toList(growable: false);
  });
}
```

Call `_loadConnections()` from `_initializeDraft()` after `_loadRecentCandidates()`. Call `_refreshPinnedConnections()` from inside `_switchToPriority` and `_switchToAuto` (in addition to the existing `_loadRecentCandidates` / `_refreshPinnedChips` calls).

- [ ] **Step 3: Implement the active getter and toggle**

Add helpers near the contacts toggle methods:

```dart
CreateLinkUserAction? get _activeCreateAction {
  final note = context.read<PriorityBloc>().state.draftNote;
  return note.actions?.whereType<CreateLinkUserAction>().firstOrNull;
}

bool _isActive(CreateTarget target) {
  final active = _activeCreateAction;
  if (active == null) return false;
  return active.twistInstanceId == target.twist.id.toString() &&
      active.channelId == target.channel.channelId &&
      active.linkType == target.linkType.type;
}

Future<void> _toggleConnection(CreateTarget target) async {
  final bloc = context.read<PriorityBloc>();
  final note = bloc.state.draftNote;
  final actions = List<UserAction>.from(note.actions ?? const []);
  actions.removeWhere((a) => a is CreateLinkUserAction);
  if (!_isActive(target)) {
    actions.add(target.toUserAction());
  }
  await bloc.updateDraft(
    bloc.state.draft,
    note: note.copyWith(actions: actions.isEmpty ? null : actions),
  );
}

Future<void> _openConnectionPicker() async {
  final picked = await ConnectionPickerModal.open(context);
  if (picked == null || !mounted) return;
  await _toggleConnection(picked);
}
```

- [ ] **Step 4: Build the row**

Add a `_buildConnectionRow` method:

```dart
Widget? _buildConnectionRow(BuildContext context, PriorityState state) {
  if (_allConnectionTargets.isEmpty) return null;
  final hasMore = _allConnectionTargets.length > _pinnedConnections.length;
  return Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final target in _pinnedConnections)
        ConnectionChip(
          target: target,
          selected: _isActive(target),
          onTap: () => _toggleConnection(target),
        ),
      Button.icon(
        _ConnectionPickerCommand(
          onOpen: _openConnectionPicker,
          hasMore: hasMore,
        ),
      ),
    ],
  );
}
```

Add a command class near `_ShareNewThread` at the bottom of the file:

```dart
class _ConnectionPickerCommand extends Command {
  _ConnectionPickerCommand({required this.onOpen, bool hasMore = false})
      : super(
          title: 'Pick a connection',
          icon: hasMore ? PlotIcon.more : PlotIcon.shareAdd,
          eventObject: EventObject.activity,
          eventAction: EventAction.updated,
        );

  final Future<void> Function() onOpen;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await onOpen();
    return const CommandDone();
  }
}
```

- [ ] **Step 5: Insert the row in `_buildThreadTypeSelector`**

Update `_buildThreadTypeSelector`:

```dart
Widget _buildThreadTypeSelector(BuildContext context, PriorityState state) {
  final connectionRow = _buildConnectionRow(context, state);
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _buildPriorityChipRow(context, state),
      if (connectionRow != null) ...[
        SizedBox(height: context.theme.spacing.md),
        connectionRow,
      ],
      SizedBox(height: context.theme.spacing.md),
      _buildWithSelector(context, state),
    ],
  );
}
```

- [ ] **Step 6: Listen for note changes to keep selected chip in sync**

The chip's selected state reads from `draft.note`. Since `BlocBuilder` already rebuilds on `draftNote != curr.draftNote` (existing `buildWhen` in `build`), the chip will rebuild on toggle automatically. No change needed.

- [ ] **Step 7: Analyze and commit**

Run: `cd apps/plot && flutter analyze lib/page/new_thread.dart`
Expected: `No issues found!`

```bash
git add apps/plot/lib/page/new_thread.dart
git commit -m "Add connection chip row to NewThreadPage"
```

---

## Task 8: Add lock chip to contacts row (Row 3)

Prepend a lock-icon chip that visually conveys "private" when no contacts/groups/emails are selected and clears all sharing when tapped while shared.

**Files:**
- Modify: `apps/plot/lib/page/new_thread.dart`

- [ ] **Step 1: Add the lock chip builder**

Add a method near `_buildContactChip`:

```dart
Widget _buildLockChip(BuildContext context, {required bool isPrivate}) {
  const chipRadius = BorderRadius.all(Radius.circular(24));
  final chipPadding = EdgeInsets.symmetric(
    horizontal: 10,
    vertical: isMobilePlatform() ? 10 : 5,
  );
  final isDark = context.read<ThemeBloc>().isDarkMode(context);

  Widget buildChip(bool hovered) {
    return FButton(
      onPress: isPrivate ? null : _clearShareTargets,
      variant: isPrivate ? FButtonVariant.primary : FButtonVariant.secondary,
      style: FButtonStyleDelta.delta(
        decoration: FVariantsDelta.delta([
          FVariantOperation.all(
            DecorationDelta.boxDelta(borderRadius: chipRadius),
          ),
        ]),
        contentStyle: FButtonContentStyleDelta.delta(
          padding: EdgeInsetsGeometryDelta.value(chipPadding),
        ),
      ),
      mainAxisSize: MainAxisSize.min,
      child: Opacity(
        opacity: isPrivate || hovered ? 1.0 : (isDark ? 0.5 : 0.9),
        child: FaIcon(
          FontAwesomeIcons.lock,
          size: context.theme.iconSizes.sm,
          color: isPrivate
              ? null
              : context.theme.plotColors.veryMuted,
        ),
      ),
    );
  }

  final chip = isPrivate
      ? buildChip(false)
      : _HoverBuilder(builder: (context, hovered) => buildChip(hovered));

  if (!hasPhysicalKeyboard()) return chip;
  return FTooltip(
    tipBuilder: (context, controller) => Text(
      isPrivate ? 'Private' : 'Make private',
    ),
    child: chip,
  );
}

Future<void> _clearShareTargets() async {
  final bloc = context.read<PriorityBloc>();
  await bloc.updateDraft(
    bloc.state.draft.copyWith(
      contacts: const Value(null),
      groups: const Value(null),
      inviteEmails: const Value(null),
    ),
  );
  _refreshPinnedChips();
}
```

- [ ] **Step 2: Prepend the lock chip in `_buildWithSelector`**

Modify the body of `_buildWithSelector` (the version from Task 6) to compute `isPrivate` and prepend `_buildLockChip` as the leading item in the `Wrap`:

```dart
Widget _buildWithSelector(BuildContext context, PriorityState state) {
  final selfUuids = Actor.getCurrentUserActorIds()
      .map((a) => a.toUuid())
      .toSet();
  final selectedIds = state.draft.contacts
      .where((id) => !selfUuids.contains(id))
      .toSet();
  final pendingEmails = state.draft.inviteEmails.toSet();
  final groupIds = state.draft.groups.toSet();
  final hasMore =
      selectedIds.length > _pinnedActors.length ||
      pendingEmails.length > _pinnedEmails.length ||
      groupIds.length > _pinnedGroups.length;
  final isPrivate = selectedIds.isEmpty &&
      groupIds.isEmpty &&
      pendingEmails.isEmpty;

  return Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 8,
    runSpacing: 8,
    children: [
      _buildLockChip(context, isPrivate: isPrivate),
      for (final group in _pinnedGroups)
        _buildGroupChip(context, group,
            selected: groupIds.contains(group.id)),
      for (final actor in _pinnedActors)
        _buildContactChip(context, actor,
            selected: selectedIds.contains(actor.id.toUuid())),
      for (final email in _pinnedEmails)
        _buildEmailChip(context, email,
            selected: pendingEmails.contains(email)),
      for (final suggestion in _pinnedSuggestions)
        switch (suggestion) {
          ActorShareCandidate(:final actor) => _buildContactChip(
              context, actor,
              selected: selectedIds.contains(actor.id.toUuid())),
          GroupShareCandidate(:final group) => _buildGroupChip(
              context, group,
              selected: groupIds.contains(group.id)),
        },
      _buildAddContactChip(context, state, hasMore: hasMore),
    ],
  );
}
```

- [ ] **Step 3: Analyze and commit**

Run: `cd apps/plot && flutter analyze lib/page/new_thread.dart`
Expected: `No issues found!`

```bash
git add apps/plot/lib/page/new_thread.dart
git commit -m "Add lock chip to contacts row, drop separate Private label"
```

---

## Task 9: Replace title chip + modal with `InlineTitleInput` (Row 4)

Drop `_buildAutoOrganizeLine`, `_buildTitleChip`, `_buildClearTitleButton`, `_clearTitle`, `_openTitleModal`, `_SaveDraftTitle`. Wire `InlineTitleInput` into the row stack and into the ⌘⇧H shortcut.

**Files:**
- Modify: `apps/plot/lib/page/new_thread.dart`

- [ ] **Step 1: Add an `InlineTitleInput` key**

Inside `NewThreadPageState`, add:

```dart
final GlobalKey<InlineTitleInputState> _titleInputKey =
    GlobalKey<InlineTitleInputState>();
```

Import `inline_title_input.dart` is already covered by the widget barrel — no extra import needed if `widget.dart` re-exports it.

- [ ] **Step 2: Build the title row**

Add a method:

```dart
Widget _buildTitleRow(BuildContext context, PriorityState state) {
  return InlineTitleInput(
    key: _titleInputKey,
    title: state.draft.title,
    onChanged: (next) async {
      final bloc = context.read<PriorityBloc>();
      await bloc.updateDraft(
        bloc.state.draft.copyWith(title: Value(next)),
      );
    },
  );
}
```

- [ ] **Step 3: Insert into the row stack**

Update `_buildThreadTypeSelector`:

```dart
Widget _buildThreadTypeSelector(BuildContext context, PriorityState state) {
  final connectionRow = _buildConnectionRow(context, state);
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _buildPriorityChipRow(context, state),
      if (connectionRow != null) ...[
        SizedBox(height: context.theme.spacing.md),
        connectionRow,
      ],
      SizedBox(height: context.theme.spacing.md),
      _buildWithSelector(context, state),
      SizedBox(height: context.theme.spacing.md),
      _buildTitleRow(context, state),
    ],
  );
}
```

- [ ] **Step 4: Remove the old title widgets and modal**

In `new_thread.dart`, delete:

- `_buildAutoOrganizeLine(...)` method (and remove both call sites in single-panel and multi-panel branches of `build`)
- `_buildTitleChip(...)`
- `_buildClearTitleButton(...)`
- `_clearTitle(...)`
- `_openTitleModal(...)`
- The `_SaveDraftTitle` class at the bottom of the file

In the single-panel branch of `build`, remove:

```dart
if (!isViewerMode)
  Padding(
    padding: EdgeInsets.symmetric(
      horizontal: context.contentPaddingH,
    ),
    child: _buildAutoOrganizeLine(context, state),
  ),
```

In the multi-panel branch of `build`, inside the `Flexible(flex: 2, ...)` `Column`, remove:

```dart
if (!isViewerMode)
  _buildAutoOrganizeLine(context, state),
```

- [ ] **Step 5: Update the ⌘⇧H shortcut**

In `_buildThreadShortcuts`, replace the title shortcut binding:

```dart
platformSingleActivator(LogicalKeyboardKey.keyH, shift: true): () {
  _titleInputKey.currentState?.focus();
},
```

- [ ] **Step 6: Analyze**

Run: `cd apps/plot && flutter analyze lib/page/new_thread.dart`
Expected: `No issues found!`

Fix any imports left dangling (e.g. `ShowForm`, `FormData`, `FormTextInput`, `FormButton` may no longer be referenced — let the analyzer flag unused imports).

- [ ] **Step 7: Commit**

```bash
git add apps/plot/lib/page/new_thread.dart
git commit -m "Replace title chip + modal with inline title input"
```

---

## Task 10: Manual verification

Use the `run-app` skill to launch Plot.app (agent profile) and walk through the spec's test plan. Capture anything that doesn't match the spec and fix before declaring done.

- [ ] **Step 1: Launch the app**

Invoke the `run-app` skill: it starts Plot.app under the `agent` profile and wires up dart-mcp. The skill encodes the gotchas around `launch_app` not forwarding args and the placeholder DTD URI.

- [ ] **Step 2: Open NewThreadPage from root**

From the Everything (root) context, click the **New** button in the bottom nav. Verify:

- Four rows render top→bottom: priority, connections (if you have enabled connections that opt in to create), contacts (lock-led), title.
- All rows left-align to the same edge as the NoteEditor.
- Vertical spacing between rows is consistent.
- Priority row shows the Auto chip; no leading sparkles toggle (root context).

- [ ] **Step 3: Switch to a non-root priority**

Click the priority chip → pick another priority. Verify:

- Leading sparkles auto-toggle appears next to the priority chip.
- Connection chip MRU reranks (chips may swap order if you've used different connections in different priorities).
- Lock chip switches to `secondary/muted` if the chosen priority has default contacts/groups.

- [ ] **Step 4: Connection chips**

- Tap an inactive connection chip → it goes `primary`; chip text and logo fill.
- Tap a different connection chip → the previous deactivates, the new one activates (only one active at a time).
- Tap the active chip again → it deactivates; no `CreateLinkUserAction` left on the draft note.
- Tap the trailing `more` button → modal opens listing every create-target. Pick one → modal closes, chip row reflects the new active target.

Verify via debugger or the running app's behavior that the draft note's `actions` array contains exactly one `CreateLinkUserAction` when selected, zero when none selected.

- [ ] **Step 5: Lock chip**

- Initial state with no contacts: lock chip shows `primary` (filled). No "Private" text appears anywhere else.
- Tap a suggestion contact chip → lock chip switches to `secondary/muted`; suggestion chip switches to `primary`.
- Tap lock chip while shared → contacts/groups/emails clear; existing chips remain in the row but show as unselected; lock chip returns to `primary`.
- Tap lock chip while private → no-op (button is disabled).

- [ ] **Step 6: Inline title**

- Initial collapsed empty state: sparkles + "Title" label, very muted.
- Hover collapsed empty state: pen + "Set title" label, foreground color.
- Tap → expands to text input with sparkles prefix, autofocused.
- Type a title → prefix swaps to pen as soon as there's text.
- Press Enter → row collapses to pen + title chip; the title persists on the draft (verify by navigating away and back).
- Tap chip → expands pre-filled with the title; prefix is pen.
- Press the X → input clears, title clears on the draft, row collapses back to sparkles + "Title".
- Expand again, type new value, click somewhere else → row collapses; new value is saved (blur acts like Enter).
- Expand, type, press Esc → row collapses to whatever was saved before; typed value is discarded.
- ⌘⇧H from anywhere on the page → input expands and focuses.

- [ ] **Step 7: Submit a thread with an active connection**

Type into the NoteEditor, optionally set a title, optionally pick contacts, ensure a connection chip is active, then submit (Enter / submit button). Verify:

- The thread saves successfully.
- Server receives `pendingCreateLinks` (the existing path is unchanged — the test is that we didn't break it).
- Reopen New thread from the same priority — that connection now appears first in the chip row (MRU recorded).

- [ ] **Step 8: Submit without a connection**

Repeat without any active connection chip. Verify nothing breaks and no spurious `CreateLinkUserAction` is recorded.

- [ ] **Step 9: Submit on a priority without any create-target-enabled connections**

If possible, switch to a priority context where no enabled channels have a `createDefault` status. Verify:

- The connection row is omitted entirely (no empty row, no orphan spacing).

- [ ] **Step 10: Final analyzer pass**

Run: `cd apps/plot && flutter analyze`
Expected: `No issues found!` (or no new issues vs. baseline)

Run: `cd apps/plot && flutter test test/state/local_preferences_test.dart`
Expected: all pass.

- [ ] **Step 11: Open PR**

Use the `commit-commands:commit-push-pr` skill (or run `gh pr create` directly) targeting `main`. Title: `Redesign NewThreadPage rows`. Body includes the spec link and a screenshot before/after.
