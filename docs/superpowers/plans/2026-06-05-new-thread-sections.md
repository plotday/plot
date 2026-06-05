# New Thread Sectioned-Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the New Thread step-1 flat target list with three labelled sections of pills (People & twists, Channels, Private notes), insert a connection-picker step between recipient and compose, and add 2D-grid keyboard navigation — reusing the existing `ComposeTargetsBloc` data and compose surface.

**Architecture:** A new presentation layer (`ComposePill`, `ComposeSearchField`, `PillGrid`, `ComposeSectionsView`, `ConnectionPickerView`) backed by three new `ComposeTargetsBloc` methods (`loadSections`, `searchSections`, `connectionsForRoster`). The page state machine grows from `{target, compose}` to `{sections, connection, compose}`. Section-1 people pills carry a *roster* (contacts/groups/invite-emails) and route to step 2; channel/twist/focus pills carry a full `ComposeTarget` and skip to compose. `_applyTarget`, the draft model, and the compose fields are unchanged.

**Tech Stack:** Flutter (forui theme), `flutter_bloc`, Drift (local store), `equatable`. Reuse: `FTextField`, `FocusLabel`, `Avatar`/`AvatarGroup`, `LogoImage`, `ComposeTarget`/`ComposeTargetView`, `ConnectionChoice`, `CreateTarget`, `LocalPreferencesBloc` MRU.

**Working directory:** `/Users/kris.braun/code/plot/.claude/worktrees/new-thread-sections` (branch `new-thread-sections`). Run all `flutter` commands from `apps/plot`.

**Verification norms (this project):** CI lint = `flutter analyze --no-fatal-infos` (info tolerated, errors not). The established workflow is **unit tests for pure logic** + **`flutter analyze`** + **run-app** for UI. Pure-logic tasks below are TDD; UI tasks verify via analyze + a run-app walkthrough (final task). Baseline analyze of the compose area is already clean except one pre-existing info at `new_thread.dart:1078`.

---

## Data → section mapping (reference)

The existing bloc produces a flat `List<ComposeTargetView>` at per-(person×connection) granularity. The new step 1 needs *one pill per recipient* (connection chosen later) plus channel/twist/focus pills. Mapping:

| Section | Source | Pill |
|---|---|---|
| People & twists (people) | recent authored-thread **rosters** (`ComposeTarget.chat` with contacts/groups/invite-emails), deduped by roster ignoring connection | Contact / Group / Ad-hoc-group pill → **step 2** |
| People & twists (twists) | `ComposeTarget.twist` (existing) | Twist pill → **compose** |
| Channels | `ctx.createTargets.where((t) => !t.isDmType)` → `ComposeTarget.connector` | Channel pill → **compose** |
| Private notes | `ComposeTarget.focusNote` (one per focus) | Focus pill → **compose** |

Step 2 (`connectionsForRoster`) lists, for the chosen roster: a Plot chat option per scope + each DM-type connector (`ctx.createTargets.where((t) => t.isDmType)`) carrying that roster, MRU-ordered via `LocalPreferencesBloc.rankSignaturesByMru`. Connector DMs are offered only when the roster has **no formal group** (a connector cannot address a Plot group).

---

## File structure

**Create:**
- `apps/plot/lib/widget/compose/compose_pill.dart` — `ComposePillData` (sealed) + `ComposePill` widget (Option-A styling, hover/focus, optional ✕, group tooltip).
- `apps/plot/lib/widget/compose/pill_grid_geometry.dart` — pure 2D-grid nav over `List<Rect>`.
- `apps/plot/lib/widget/compose/pill_grid.dart` — `PillGrid` widget (sections of `Wrap`ped pills, geometry measuring, arrow handling, scroll-into-view).
- `apps/plot/lib/widget/compose/compose_search_field.dart` — borderless fading-underline search input (extracted from `target_picker_list.dart`) with leading icon **or** leading chip + `onArrowDown`/`onEnter`/`onEscape`.
- `apps/plot/lib/widget/compose/compose_sections_view.dart` — step 1 view.
- `apps/plot/lib/widget/compose/connection_picker_view.dart` — step 2 view.
- `apps/plot/test/widget/compose/pill_grid_geometry_test.dart` — unit tests for geometry.
- `apps/plot/test/state/compose_sections_test.dart` — unit tests for the pure roster dedupe/classify helper.

**Modify:**
- `apps/plot/lib/state/compose_targets.dart` — add `ComposeSections`, `ComposePeopleEntry`, `loadSections`, `searchSections`, `connectionsForRoster`, and the pure helper `dedupePeopleByRoster`.
- `apps/plot/lib/page/new_thread.dart` — `_ComposeStep {sections, connection, compose}`; new transitions/back-nav; step-1/step-2 builders; per-path compose rules.
- `apps/plot/lib/widget/compose/compose_target_view.dart` — (only if needed) expose a helper; no field changes expected.

**Delete (final task):**
- `apps/plot/lib/widget/compose/target_picker_list.dart` — once nothing imports it. Its fading-underline + search field move to `compose_search_field.dart`; its keyboard primitives are superseded by `PillGrid`.

---

## Task 1: `PillGridGeometry` — pure 2D-grid navigation (TDD)

The only genuinely algorithmic piece. Operates on pill rectangles in reading order (content-space). `←/→` = prev/next in reading order (clamped). `↑/↓` = nearest pill in the adjacent visual row by horizontal centre; `↑` past the top row returns the sentinel `-1` (caller focuses the search bar); `↓` past the last row stays put.

**Files:**
- Create: `apps/plot/lib/widget/compose/pill_grid_geometry.dart`
- Test: `apps/plot/test/widget/compose/pill_grid_geometry_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// apps/plot/test/widget/compose/pill_grid_geometry_test.dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/compose/pill_grid_geometry.dart';

void main() {
  // Two rows: row 0 = indices 0,1,2 (y=0,h=30); row 1 = indices 3,4 (y=40,h=30).
  // x layout: 0:[0,40] 1:[50,90] 2:[100,140]  3:[0,40] 4:[50,90]
  Rect r(double x, double y, double w) => Rect.fromLTWH(x, y, w, 30);
  final rects = <Rect>[
    r(0, 0, 40), r(50, 0, 40), r(100, 0, 40), // row 0
    r(0, 40, 40), r(50, 40, 40), // row 1
  ];
  final g = PillGridGeometry(rects);

  test('horizontal moves clamp at ends', () {
    expect(g.horizontal(0, -1), 0); // already first
    expect(g.horizontal(0, 1), 1);
    expect(g.horizontal(2, 1), 3); // wraps across row boundary (reading order)
    expect(g.horizontal(4, 1), 4); // already last
  });

  test('down picks nearest pill in next row by centre-x', () {
    // index 0 centre-x = 20 -> next row nearest is index 3 (centre-x 20)
    expect(g.vertical(0, 1), 3);
    // index 2 centre-x = 120 -> next row only has 3(20),4(70); nearest is 4
    expect(g.vertical(2, 1), 4);
  });

  test('down from last row stays put', () {
    expect(g.vertical(3, 1), 3);
    expect(g.vertical(4, 1), 4);
  });

  test('up picks nearest pill in previous row by centre-x', () {
    expect(g.vertical(3, -1), 0); // centre-x 20 -> index 0
    expect(g.vertical(4, -1), 1); // centre-x 70 -> index 1 (centre 70)
  });

  test('up from top row returns -1 sentinel (focus search bar)', () {
    expect(g.vertical(0, -1), PillGridGeometry.toSearchBar);
    expect(g.vertical(2, -1), PillGridGeometry.toSearchBar);
  });

  test('empty geometry is safe', () {
    final e = PillGridGeometry(const []);
    expect(e.horizontal(0, 1), 0);
    expect(e.vertical(0, 1), 0);
    expect(e.vertical(0, -1), PillGridGeometry.toSearchBar);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/widget/compose/pill_grid_geometry_test.dart`
Expected: FAIL — `pill_grid_geometry.dart` / `PillGridGeometry` not found (compile error).

- [ ] **Step 3: Write minimal implementation**

```dart
// apps/plot/lib/widget/compose/pill_grid_geometry.dart
import 'package:flutter/widgets.dart';

/// Pure 2D-grid navigation over pill rectangles laid out (wrapped) in reading
/// order. Rects are in a shared content-space; index order == reading order.
///
/// `horizontal` walks reading order (clamped). `vertical` moves between visual
/// rows, choosing the pill in the adjacent row whose horizontal centre is
/// nearest. `vertical(_, -1)` past the first row returns [toSearchBar] so the
/// view can hand focus back to the search field; `vertical(_, 1)` past the last
/// row returns the same index (stay).
class PillGridGeometry {
  PillGridGeometry(this.rects);

  final List<Rect> rects;

  /// Sentinel returned by [vertical] when moving up past the first row.
  static const int toSearchBar = -1;

  /// Two rects share a row when their vertical centres are within half the
  /// smaller height.
  bool _sameRow(Rect a, Rect b) =>
      (a.center.dy - b.center.dy).abs() <
      (a.height < b.height ? a.height : b.height) / 2;

  int horizontal(int from, int delta) {
    if (rects.isEmpty) return 0;
    return (from + delta).clamp(0, rects.length - 1);
  }

  int vertical(int from, int dy) {
    if (rects.isEmpty || from < 0 || from >= rects.length) {
      return dy < 0 ? toSearchBar : (rects.isEmpty ? 0 : from);
    }
    final cur = rects[from];
    // Candidate pills strictly above (dy<0) or below (dy>0) the current row.
    final candidates = <int>[];
    for (var i = 0; i < rects.length; i++) {
      if (i == from) continue;
      final r = rects[i];
      if (_sameRow(r, cur)) continue;
      final below = r.center.dy > cur.center.dy;
      if (dy > 0 && below) candidates.add(i);
      if (dy < 0 && !below) candidates.add(i);
    }
    if (candidates.isEmpty) return dy < 0 ? toSearchBar : from;
    // Nearest adjacent row: min vertical distance to current centre.
    double rowKey(int i) => (rects[i].center.dy - cur.center.dy).abs();
    final nearestRowDy = candidates.map(rowKey).reduce((a, b) => a < b ? a : b);
    final inRow = candidates
        .where((i) => (rowKey(i) - nearestRowDy).abs() < cur.height / 2)
        .toList();
    // Within that row, nearest by horizontal centre.
    inRow.sort((a, b) => (rects[a].center.dx - cur.center.dx)
        .abs()
        .compareTo((rects[b].center.dx - cur.center.dx).abs()));
    return inRow.first;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/widget/compose/pill_grid_geometry_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/new-thread-sections
git add apps/plot/lib/widget/compose/pill_grid_geometry.dart apps/plot/test/widget/compose/pill_grid_geometry_test.dart
git commit -m "Add PillGridGeometry: pure 2D-grid pill navigation"
```

---

## Task 2: `ComposePillData` + `ComposePill` widget

A presentational pill. Focus/hover state is supplied by the parent (`PillGrid`); the pill just renders Option-A styling for `focused`. Tooltip on group/ad-hoc pills lists all member names + addresses.

**Files:**
- Create: `apps/plot/lib/widget/compose/compose_pill.dart`

Real APIs to use (verified): `FocusLabel(priority:, muted:, fontSize:, iconSize:)`; `AvatarGroup(actors:, totalCount:, maxVisible:, size:)`; `Avatar(actor:, size:, tooltip:)`; `LogoImage(url:, size:, fallback:)`; theme via `context.theme` (`typography`, `spacing`, `colors`), `context.colour.colours.fromTheme(ThemeColor, muted:)`, dark mode via `context.read<ThemeBloc>().isDarkMode(context)`. Group model: `Group.fromCache(Uuid) -> Group?` with `.name`, `.memberContactIds (List<Uuid>)`. Actor: `Actor.fromCache(ActorId)`, `.name`, `.email`, `.nameOrEmail`. Plot logo: `SvgPicture.asset('assets/plot-icon.svg', width:, height:)`. Forui tooltip pattern: `FTooltip` (see existing `_withRecipientTooltip` in `target_picker_list.dart` for the established pattern — copy its structure).

- [ ] **Step 1: Define the sealed data model**

```dart
// apps/plot/lib/widget/compose/compose_pill.dart  (top of file)
import 'package:flutter/widgets.dart';
import 'package:plot/store/actor.dart';
import 'package:plot/store/group.dart';
import 'package:plot/store/priority.dart';
import 'package:plot/widget/compose/compose_target.dart';

/// What a [ComposePill] renders. Sealed so the widget switches exhaustively.
sealed class ComposePillData {
  const ComposePillData();
}

/// A single person: avatar + name + email.
class ContactPillData extends ComposePillData {
  const ContactPillData(this.actor);
  final Actor actor;
}

/// A formal group: count badge + name + truncated member emails. Tooltip lists
/// all member names + addresses.
class GroupPillData extends ComposePillData {
  const GroupPillData(this.group, this.members);
  final Group group;
  final List<Actor> members;
}

/// A recent ad-hoc combo of multiple contacts (no formal group): count badge +
/// truncated member names. Tooltip lists all names + addresses.
class AdHocGroupPillData extends ComposePillData {
  const AdHocGroupPillData(this.actors, {this.inviteEmails = const []});
  final List<Actor> actors;
  final List<String> inviteEmails;
}

/// A non-connection twist (assistant): logo + name. Muted (reads as secondary
/// to people in the same section).
class TwistPillData extends ComposePillData {
  const TwistPillData(this.target);
  final ComposeTarget target; // kind == twist
}

/// A non-person connector destination: logo + connection name + channel.
class ChannelPillData extends ComposePillData {
  const ChannelPillData(this.target);
  final ComposeTarget target; // kind == connector, channel != null
}

/// A focus (private note): focus icon + name in focus colour.
class FocusPillData extends ComposePillData {
  const FocusPillData(this.priority);
  final Priority priority;
}

/// A step-2 connection option: logo + connection name + reach detail.
class ConnectionPillData extends ComposePillData {
  const ConnectionPillData(this.target, {this.label, this.detail});
  final ComposeTarget target; // chat (Plot) or connector DM
  final String? label;
  final String? detail;
}
```

- [ ] **Step 2: Implement the `ComposePill` widget**

Build a `StatelessWidget` with params `({required ComposePillData data, required bool focused, required VoidCallback onTap, VoidCallback? onRemove})`. Layout: a rounded `Container` (fully rounded radius) with:
- border: `Border.all(color: focused ? context.colour.colours.fromTheme(headerColorOrAccent) : context.theme.colors.border)` — hairline at rest; **fill** `focused ? context.colour.editableBackground : Colors.transparent`.
- padding ≈ `EdgeInsets.fromLTRB(7, 6, 13, 6)` (tighter left for the avatar/logo).
- leading: per variant — `Avatar(size: 24)` (contact), a count badge `Container` (group/ad-hoc: 24px circle, muted bg, member count text), `LogoImage(size: 22)` (channel/twist/connection), focus dot via `FocusLabel`’s icon, or Plot svg for the Plot connection option.
- text: name (medium weight) + muted meta (email / `#channel` / truncated member list). Truncate group member emails / ad-hoc names with `TextOverflow.ellipsis` and a max width (`ConstrainedBox(maxWidth: 220)`).
- trailing `onRemove != null ? GestureDetector(onTap: onRemove, child: Icon(close))` rendering the ✕.
- wrap the whole pill in `GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: ...)`.
- For `GroupPillData` / `AdHocGroupPillData`, wrap in an `FTooltip` whose content is the full newline-joined `name <email>` list (mirror `target_picker_list.dart`’s `_withRecipientTooltip`).

For `FocusPillData`, render `FocusLabel(priority: data.priority)` as the body (icon + name already in focus colour) — no avatar; keep the same border/fill container.

For `TwistPillData`, render the muted-name treatment: `LogoImage` + `Text(target.label, style: typography.md.copyWith(color: colors.mutedForeground))`.

- [ ] **Step 3: Verify it analyzes**

Run: `cd apps/plot && flutter analyze lib/widget/compose/compose_pill.dart`
Expected: `No issues found!` (or only the global pre-existing info — none in this file).

- [ ] **Step 4: Commit**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/new-thread-sections
git add apps/plot/lib/widget/compose/compose_pill.dart
git commit -m "Add ComposePill + ComposePillData (contact/group/adhoc/twist/channel/focus/connection)"
```

---

## Task 3: `ComposeSearchField` — extract the borderless fading-underline input

Move the search input + `_FadingUnderline` out of `target_picker_list.dart` into a reusable widget that supports a **leading widget slot** (search icon *or* a recipient chip) and exposes navigation callbacks. Used by both step 1 and step 2.

**Files:**
- Create: `apps/plot/lib/widget/compose/compose_search_field.dart`

- [ ] **Step 1: Implement `ComposeSearchField`**

Copy the `FTextField` configuration verbatim from `target_picker_list.dart:455–561` (the transparent-fill-in-every-state delta, borderless `OutlineInputBorder`, roomy padding, always-laid-out clear button) and the `_FadingUnderline` widget (`target_picker_list.dart:925–963`). Constructor:

```dart
const ComposeSearchField({
  super.key,
  required this.controller,
  required this.focusNode,
  required this.hint,
  this.leading,            // search icon OR a ComposePill chip (step 2)
  this.autofocus = true,
  this.onChanged,
  this.onSubmit,           // Enter
  this.onArrowDown,        // ↓ into the grid
  this.onEscape,           // Esc (return KeyEventResult via Focus onKeyEvent)
});
```

Render `Row(children: [if (leading != null) leading!, Expanded(child: <FTextField>)])` above the `_FadingUnderline`. Wire `onSubmit: (_) => onSubmit?.call()`. Handle `ArrowDown` and `Escape` via a `Focus(onKeyEvent:)` wrapper around the field: ArrowDown → `onArrowDown?.call(); return handled`; Escape → if controller has text, the parent decides (call `onEscape` and let it return whether handled). Keep the existing `onTapOutside: (_) {}` so empty-space clicks don’t blur. Preserve `autofocus` gating semantics (caller passes `autofocus: hasPhysicalKeyboard()` if needed; the page already owns focus restoration).

- [ ] **Step 2: Verify it analyzes**

Run: `cd apps/plot && flutter analyze lib/widget/compose/compose_search_field.dart`
Expected: `No issues found!`

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/widget/compose/compose_search_field.dart
git commit -m "Add ComposeSearchField: reusable borderless fading-underline search input with leading slot"
```

---

## Task 4: `PillGrid` widget — sections of pills + geometry-aware arrow nav

Renders an ordered set of sections (header + `Wrap` of `ComposePill`s), measures pill rects post-frame, and resolves arrow keys via `PillGridGeometry`. Owns the focused index; hover sets focus; tap/Enter activates.

**Files:**
- Create: `apps/plot/lib/widget/compose/pill_grid.dart`

- [ ] **Step 1: Define the section/item model and widget API**

```dart
// apps/plot/lib/widget/compose/pill_grid.dart
class PillGridItem {
  PillGridItem({required this.data, required this.onActivate, this.onRemove});
  final ComposePillData data;
  final VoidCallback onActivate;
  final VoidCallback? onRemove;
}

class PillGridSection {
  PillGridSection({required this.header, required this.items});
  final Widget header;              // e.g. "Channels" or the People&twists header
  final List<PillGridItem> items;   // may be empty -> section hidden by caller
}

class PillGrid extends StatefulWidget {
  const PillGrid({
    super.key,
    required this.sections,
    required this.scrollController,
    required this.gridFocusNode,
    required this.onMoveToSearch,   // ↑ past the top row
  });
  final List<PillGridSection> sections;
  final ScrollController scrollController;
  final FocusNode gridFocusNode;
  final VoidCallback onMoveToSearch;
}
```

- [ ] **Step 2: Implement layout + navigation**

- Flatten `sections` into an ordered `List<PillGridItem>` (`_flat`) and remember each item’s `GlobalKey` (`_keys[i]`). Reading order == section order then item order.
- `build`: a single scrollable `Column` (`SingleChildScrollView(controller:)`), with, per non-empty section, the `header` then a `Wrap(spacing:, runSpacing:, children: [for each item: KeyedSubtree(key:_keys[i], child: MouseRegion(onEnter: ()=>_setFocus(i)) + ComposePill(data:, focused: i==_focused, onTap: item.onActivate, onRemove: item.onRemove))])`.
- Wrap the whole thing in `Focus(focusNode: widget.gridFocusNode, onKeyEvent: _onKey)`.
- `_measure()` (post-frame, after build and on metrics change): for each `_keys[i]`, read `RenderBox` via `key.currentContext?.findRenderObject()`, convert to the grid’s content-space (`localToGlobal` minus the scroll-content origin), store `_rects[i]`. Cache; rebuild rects when `sections` change or on `LayoutBuilder` size change.
- `_onKey`: on Arrow keys (KeyDown), compute via `PillGridGeometry(_rects)`:
  - Left/Right → `g.horizontal(_focused, ∓1/±1)`; setState + `_scrollIntoView`.
  - Down → `g.vertical(_focused, 1)`.
  - Up → `final n = g.vertical(_focused, -1); if (n == PillGridGeometry.toSearchBar) { widget.onMoveToSearch(); } else setState…`.
  - Enter → `_flat[_focused].onActivate()`.
  - return `KeyEventResult.handled` for handled keys, else `ignored`.
- `_scrollIntoView(i)`: ensure `_rects[i]` is visible in `scrollController` viewport; animate (200ms easeOut), clamped to `maxScrollExtent`. (Adapt `target_picker_list.dart:249–283` but use the real measured rect instead of `_estimatedItemHeight`.)
- Expose `focusFirst()` (set `_focused = 0`, request `gridFocusNode`) for the search field’s ↓ handler. Implement as a `GlobalKey<PillGridState>` the parent holds, or via a passed-in controller. Use a `GlobalKey<_PillGridState>` in the parent view.
- Clamp `_focused` into range whenever `sections` change (filtering may shrink the list).

- [ ] **Step 3: Verify it analyzes**

Run: `cd apps/plot && flutter analyze lib/widget/compose/pill_grid.dart`
Expected: `No issues found!`

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/widget/compose/pill_grid.dart
git commit -m "Add PillGrid: sectioned pill layout with geometry-aware 2D arrow nav"
```

---

## Task 5: Bloc data shaping — sections, search, connections-for-roster (+ TDD for the pure helper)

Add the section/connection producers to `ComposeTargetsBloc`, reusing the existing scan (`_searchContextFor`/`_materializeBaseList` internals), `ctx.createTargets`, focus order, twists, and `LocalPreferencesBloc` MRU. Extract one pure helper (`dedupePeopleByRoster`) and unit-test it.

**Files:**
- Modify: `apps/plot/lib/state/compose_targets.dart`
- Test: `apps/plot/test/state/compose_sections_test.dart`

- [ ] **Step 1: Define result types (top of `compose_targets.dart`, after imports)**

```dart
/// One recipient option in section 1 "People & twists": a roster whose
/// connection is chosen later (step 2). `display` drives the pill.
class ComposePeopleEntry extends Equatable {
  const ComposePeopleEntry({
    required this.contacts,
    required this.groups,
    required this.inviteEmails,
    required this.display,
  });
  final List<Uuid> contacts;
  final List<Uuid> groups;
  final List<String> inviteEmails;
  final ComposePillData display;

  bool get hasGroup => groups.isNotEmpty;

  @override
  List<Object?> get props => [contacts, groups, inviteEmails];
}

/// Sectioned step-1 data. Each list is already limited for the at-rest view;
/// [searchSections] returns the same shape filtered/expanded by query.
class ComposeSections extends Equatable {
  const ComposeSections({
    required this.people,   // contacts/groups/ad-hoc + twists are merged in `people`+`twists`
    required this.twists,
    required this.channels,
    required this.focuses,
  });
  final List<ComposePeopleEntry> people;
  final List<ComposeTarget> twists;
  final List<ComposeTarget> channels;   // kind connector, channel != null
  final List<ComposeTarget> focuses;    // kind note (focusNote)

  @override
  List<Object?> get props => [people, twists, channels, focuses];
}
```

- [ ] **Step 2: Write the failing test for `dedupePeopleByRoster`**

```dart
// apps/plot/test/state/compose_sections_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/compose_targets.dart';
import 'package:plot/widget/compose/compose_target.dart';
import 'package:plot/util/uuid.dart';

void main() {
  ComposeTarget chat(List<String> contactHex, {List<String> groups = const []}) =>
      ComposeTarget.chat(
        teamId: null,
        hasTeams: false,
        contacts: contactHex.map(Uuid.parse).toList(),
        groups: groups.map(Uuid.parse).toList(),
      );

  test('dedupes by roster ignoring scope, preserves first-seen order', () {
    final a = '00000000-0000-0000-0000-000000000001';
    final b = '00000000-0000-0000-0000-000000000002';
    final targets = [
      chat([a]),         // Greg
      chat([a]),         // Greg again (dup -> dropped)
      chat([a, b]),      // Greg+Dana (distinct ad-hoc)
      chat([b]),         // Dana
    ];
    final rosters = dedupePeopleByRoster(targets);
    expect(rosters.length, 3);
    expect(rosters[0].contacts.map((u) => u.toString()), [a]);
    expect(rosters[1].contacts.map((u) => u.toString())..sort(), [a, b]..sort());
    expect(rosters[2].contacts.map((u) => u.toString()), [b]);
  });

  test('empty rosters are skipped', () {
    expect(dedupePeopleByRoster([ComposeTarget.note(hasTeams: false)]), isEmpty);
  });
}
```

(`dedupePeopleByRoster` returns a `List<({List<Uuid> contacts, List<Uuid> groups, List<String> inviteEmails})>` — a thin roster record, not the full entry, so it’s pure and cache-free.)

- [ ] **Step 3: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/state/compose_sections_test.dart`
Expected: FAIL — `dedupePeopleByRoster` undefined.

- [ ] **Step 4: Implement `dedupePeopleByRoster` (top-level pure function in `compose_targets.dart`)**

```dart
typedef RosterKey = ({List<Uuid> contacts, List<Uuid> groups, List<String> inviteEmails});

/// Collapses chat/connector-DM targets to distinct rosters, ignoring team scope
/// and connection. First-seen order preserved (callers pass MRU-ordered input).
/// Targets with no roster are skipped.
List<RosterKey> dedupePeopleByRoster(List<ComposeTarget> targets) {
  final seen = <String>{};
  final out = <RosterKey>[];
  for (final t in targets) {
    if (t.contacts.isEmpty && t.groups.isEmpty && t.inviteEmails.isEmpty) {
      continue;
    }
    final c = t.contacts.map((u) => u.toString()).toList()..sort();
    final g = t.groups.map((u) => u.toString()).toList()..sort();
    final e = t.inviteEmails.toList()..sort();
    final key = 'c=${c.join(",")}|g=${g.join(",")}|e=${e.join(",")}';
    if (!seen.add(key)) continue;
    out.add((contacts: t.contacts, groups: t.groups, inviteEmails: t.inviteEmails));
  }
  return out;
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/state/compose_sections_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 6: Implement `loadSections`, `searchSections`, `connectionsForRoster`**

Add these methods to `ComposeTargetsBloc`. Reuse `_searchContextFor()` (gives `ctx` with `createTargets`, `connectionCount`, `focusNoteOrder`, `priorityById`, `teamNames`, `hasTeams`, `scan`) and `_materializeBaseList()`’s building blocks. Concretely:

```dart
/// Step-1 at-rest sections. People = MRU rosters (deduped) classified into
/// contact/group/ad-hoc pills; twists/channels/focuses reuse existing builders.
Future<ComposeSections> loadSections({int perSection = 8}) async {
  final ctx = await _searchContextFor();
  final scan = ctx.scan;

  // People: MRU-ranked chat/DM rosters -> distinct rosters -> pill data.
  final usedSignatures = buildUsedTargetSignatures(scan.threads);
  final rankedUsed = _prefs.rankSignaturesByMru(signatures: usedSignatures);
  final rosterTargets = <ComposeTarget>[];
  for (final sig in rankedUsed) {
    final st = scan.bySignature[sig];
    if (st == null) continue;
    final t = _composeTargetForScanThread(st,
        templateBySignature: ctx.templateBySignature,
        connectionCount: ctx.connectionCount,
        hasTeams: ctx.hasTeams, teamNames: ctx.teamNames);
    if (t != null) rosterTargets.add(t);
  }
  final people = <ComposePeopleEntry>[];
  for (final r in dedupePeopleByRoster(rosterTargets)) {
    final entry = _peopleEntryFor(r);          // classify -> ContactPillData / GroupPillData / AdHocGroupPillData
    if (entry != null) people.add(entry);
    if (people.length >= perSection) break;
  }

  // Twists (existing rule).
  final twists = await _twistTargets(ctx);     // factor out of _materializeBaseList lines 530-540

  // Channels = non-DM connector templates.
  final channels = [
    for (final t in ctx.createTargets)
      if (!t.isDmType)
        ComposeTarget.connector(t,
            connectionCount: ctx.connectionCount(t), channelDetail: t.channel?.title),
  ].take(perSection).toList();

  // Focuses (existing rule).
  final focuses = [
    for (final f in ctx.focusNoteOrder.take(perSection))
      ComposeTarget.focusNote(
          priorityId: f.priorityId, teamId: f.teamId,
          title: ctx.priorityById[f.priorityId]?.displayTitle ?? 'Note'),
  ];

  return ComposeSections(
      people: people, twists: twists.take(perSection).toList(),
      channels: channels, focuses: focuses);
}
```

`_peopleEntryFor(RosterKey r)` (new private helper): warm the actor cache (the bloc already warms it in `_buildSearchContext`); then:
- group present → `Group.fromCache(r.groups.first)`; members = `[for (id in group.memberContactIds) Actor.fromCache(ActorId.fromUuid(id))].whereNotNull()`; `display = GroupPillData(group, members)`.
- else single contact + no invite emails → `ContactPillData(Actor.fromCache(ActorId.fromUuid(r.contacts.single)))`.
- else (≥2 contacts, or invite emails) → `AdHocGroupPillData(actors, inviteEmails: r.inviteEmails)`.
Return null if no actors resolve.

`searchSections(String query)`: when query is empty, return `loadSections()`. Otherwise filter each list:
- people: union of (a) at-rest people whose any member name/email contains the query, and (b) `_searchByName`-style contact matches synthesized into single-contact `ComposePeopleEntry`s (reuse `_searchByName`’s actor matching, but emit *recipients*, not per-connection targets). Cap at `perSection`.
- twists/channels/focuses: filter by `label`/`header`/title `.contains(lower)`; for focuses also match all priorities by title (so any focus is searchable).

```dart
/// Connections that can reach [contacts]/[groups]/[inviteEmails], MRU-first.
/// Plot per applicable scope + DM-type connectors (only when no formal group).
Future<List<ComposeTarget>> connectionsForRoster({
  required List<Uuid> contacts,
  required List<Uuid> groups,
  required List<String> inviteEmails,
}) async {
  final ctx = await _searchContextFor();
  final options = <ComposeTarget>[];
  // Plot (personal) — always. Add team scopes the user belongs to.
  for (final teamId in <BigInt?>{null, ...ctx.teamNames.keys}) {
    options.add(ComposeTarget.chat(
      teamId: teamId, hasTeams: ctx.hasTeams,
      teamName: teamId == null ? null : ctx.teamNames[teamId],
      contacts: contacts, groups: groups, inviteEmails: inviteEmails,
    ));
  }
  // Connector DMs — only when the roster has no formal group.
  if (groups.isEmpty) {
    for (final t in ctx.createTargets.where((t) => t.isDmType)) {
      options.add(ComposeTarget.connector(t,
          connectionCount: ctx.connectionCount(t), contacts: contacts));
    }
  }
  final ranked = _prefs.rankSignaturesByMru(
      signatures: options.map((o) => o.signature).toList());
  final bySig = {for (final o in options) o.signature: o};
  return [for (final s in ranked) if (bySig[s] != null) bySig[s]!];
}
```

Factor the twist-template loop (`_materializeBaseList` lines 530–540) into a private `Future<List<ComposeTarget>> _twistTargets(_SearchContext ctx)` and call it from both `_materializeBaseList` and `loadSections` (DRY).

- [ ] **Step 7: Verify analyze + the pure test still passes**

Run: `cd apps/plot && flutter test test/state/compose_sections_test.dart && flutter analyze lib/state/compose_targets.dart`
Expected: tests PASS; analyze `No issues found!`.

- [ ] **Step 8: Commit**

```bash
git add apps/plot/lib/state/compose_targets.dart apps/plot/test/state/compose_sections_test.dart
git commit -m "Add sectioned + connection-for-roster producers to ComposeTargetsBloc"
```

---

## Task 6: `ComposeSectionsView` — step 1 view

Assembles `ComposeSearchField` (leading search icon) + `PillGrid` with three sections from `loadSections`/`searchSections`, debounced search (180ms, matching the old picker). Emits two callbacks.

**Files:**
- Create: `apps/plot/lib/widget/compose/compose_sections_view.dart`

- [ ] **Step 1: Implement the view**

Constructor:
```dart
const ComposeSectionsView({
  super.key,
  required this.scrollController,
  required this.searchController,   // page-owned (survives step round-trips)
  required this.searchFocusNode,    // page-owned
  required this.onPickRecipient,    // (ComposePeopleEntry) -> step 2
  required this.onPickTarget,       // (ComposeTarget) -> compose (twist/channel/focus)
  this.autofocusSearch = true,
});
```

State:
- `_sections` (`ComposeSections?`), `_debounce` (`Timer?`, 180ms), `_gridKey = GlobalKey<PillGridState>()`, `_gridFocusNode`.
- `initState`: `_loadInitial()` (calls `loadSections`); if `searchController.text` is non-empty, run a search instead (mirrors `target_picker_list.dart:127–141`).
- `_onSearchChanged`: debounce → `searchSections(text)` (empty → `loadSections`); `setState`. (Mirror `_onSearchChanged`/`_runSearch` at `target_picker_list.dart:180–212`.)
- Build the People-&-twists header as `RichText`: "People and " (muted-strong) + "twists" (more muted) — both via `context.theme.typography.xs` uppercase letter-spacing label style used by the old `nt-head` (match `target_picker_list.dart` header style). Channels / Private notes headers are plain labels.
- Compose `List<PillGridSection>`: build People&twists items = `[...people -> ComposePeopleEntry pill (onActivate: onPickRecipient), ...twists -> TwistPillData (onActivate: onPickTarget)]`; Channels = channels → `ChannelPillData` (onActivate: onPickTarget); Private notes = focuses → `FocusPillData` from `target.priorityId`’s `Priority` (onActivate: onPickTarget). **Drop empty sections** (don’t add a `PillGridSection` whose items are empty). Append a quiet "＋ Add connection" item to Channels (a `ConnectionPillData`-like affordance, or a dedicated minimal pill) whose `onActivate` runs `ManageConnections()` — reuse `_runManageConnections` logic from the old picker.
- Wire `ComposeSearchField(hint: 'Start a thread', leading: search icon, onArrowDown: () => _gridKey.currentState?.focusFirst(), onEnter: _activateFirst, onChanged: _onSearchChanged)`.
- `PillGrid(sections:, scrollController:, gridFocusNode: _gridFocusNode, onMoveToSearch: () => searchFocusNode.requestFocus())`.

- [ ] **Step 2: Analyze**

Run: `cd apps/plot && flutter analyze lib/widget/compose/compose_sections_view.dart`
Expected: `No issues found!`

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/widget/compose/compose_sections_view.dart
git commit -m "Add ComposeSectionsView (step 1): sectioned pill picker with global search"
```

---

## Task 7: `ConnectionPickerView` — step 2 view

`ComposeSearchField` with a **leading recipient chip** (the same `ComposePill` as step 1, with ✕ → `onBack`) + a single "Connections" section of connection pills from `connectionsForRoster`, MRU-first; typing filters them.

**Files:**
- Create: `apps/plot/lib/widget/compose/connection_picker_view.dart`

- [ ] **Step 1: Implement the view**

Constructor:
```dart
const ConnectionPickerView({
  super.key,
  required this.recipient,          // ComposePeopleEntry (drives the leading chip)
  required this.scrollController,
  required this.searchController,    // page-owned (cleared on entry)
  required this.searchFocusNode,     // page-owned
  required this.onPickConnection,    // (ComposeTarget) -> compose
  required this.onBack,              // ✕ / Esc -> step 1 (restore query)
});
```

State: load `connectionsForRoster(contacts: recipient.contacts, groups: recipient.groups, inviteEmails: recipient.inviteEmails)` in `initState`; store `_connections` and a filtered view `_filtered` (by `controller.text` against label/detail). Build one `PillGridSection(header: 'Connections', items: _filtered -> ConnectionPillData(target, label: <connector/Plot name>, detail: <account / "#channel" / "direct message">) with onActivate: onPickConnection)`.

Leading chip: `ComposePill(data: recipient.display, focused: false, onTap: onBack, onRemove: onBack)`.

`ComposeSearchField(hint: 'Select a connection', leading: <the chip>, onArrowDown: focusFirst, onEnter: activateFirst, onEscape: () { onBack(); return true; }, onChanged: _filter)`.

- [ ] **Step 2: Analyze**

Run: `cd apps/plot && flutter analyze lib/widget/compose/connection_picker_view.dart`
Expected: `No issues found!`

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/widget/compose/connection_picker_view.dart
git commit -m "Add ConnectionPickerView (step 2): recipient chip + MRU connection pills"
```

---

## Task 8: Wire the state machine in `new_thread.dart`

Grow `_ComposeStep` to `{sections, connection, compose}`; replace the step-1 builder; add a step-2 builder; add roster state + back-nav; adjust compose Esc / connection-field-tap per path.

**Files:**
- Modify: `apps/plot/lib/page/new_thread.dart`

- [ ] **Step 1: Rename the enum and add the connection step**

Replace (`new_thread.dart:79`):
```dart
enum _ComposeStep { target, compose }
```
with:
```dart
enum _ComposeStep { sections, connection, compose }
```
Then replace every `_ComposeStep.target` with `_ComposeStep.sections` (in `_step` initializer line ~118, `isOnStep1` line ~120, `focusFilter` lines ~107/110, `_returnToTargetStep`, `_resetToFreshStart`, `build` switch line ~1496, `_handleEditorKeys`/`_buildThreadShortcuts`). `_step` initializer becomes `_ComposeStep _step = _ComposeStep.sections;`.

- [ ] **Step 2: Add roster state + stashed query fields**

After `_selectedTarget` (`new_thread.dart:~140`), add:
```dart
/// The recipient chosen in step 1 (people pill), retained to drive the step-2
/// connection picker and the compose-step back-nav. Null on twist/channel/
/// private-note paths (which skip step 2).
ComposePeopleEntry? _selectedRecipient;

/// The step-1 filter text stashed when advancing to step 2 (which clears the
/// shared field for "Select a connection"); restored on back. See
/// [_returnToSectionsStep].
String _stashedSectionsQuery = '';
```

- [ ] **Step 3: Add the step-1/step-2 builders and transitions**

Replace `_buildTargetPickerStep` (`new_thread.dart:1369–1401`) body to render `ComposeSectionsView` instead of `TargetPickerList`:
```dart
final picker = ComposeSectionsView(
  key: const ValueKey('new-thread-sections'),
  scrollController: _pickerScrollController,
  searchController: _pickerSearchController,
  searchFocusNode: _pickerSearchFocusNode,
  onPickRecipient: _pickRecipient,
  onPickTarget: (t) => unawaited(_applyDirectTarget(t)),
);
```
(keep the multiPanel padding wrapper as-is.)

Add a `_buildConnectionStep(context, {required bool multiPanel})` mirroring the padding wrapper, rendering:
```dart
final view = ConnectionPickerView(
  key: const ValueKey('new-thread-connection'),
  recipient: _selectedRecipient!,
  scrollController: _pickerScrollController,
  searchController: _pickerSearchController,
  searchFocusNode: _pickerSearchFocusNode,
  onPickConnection: (t) => unawaited(_applyTarget(t)),
  onBack: _returnToSectionsStep,
);
```

Add transitions:
```dart
/// Step 1 people pill -> step 2. Stash the step-1 query, clear the shared field
/// for "Select a connection", remember the recipient.
void _pickRecipient(ComposePeopleEntry entry) {
  _stashedSectionsQuery = _pickerSearchController.text;
  _pickerSearchController.clear();
  setState(() {
    _selectedRecipient = entry;
    _step = _ComposeStep.connection;
  });
  if (hasPhysicalKeyboard()) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _step == _ComposeStep.connection) {
        _pickerSearchFocusNode.requestFocus();
      }
    });
  }
}

/// Step 1 twist/channel/private-note pill -> compose (skip step 2). Clears the
/// recipient so compose-step Esc returns to step 1.
Future<void> _applyDirectTarget(ComposeTarget target) async {
  setState(() => _selectedRecipient = null);
  await _applyTarget(target);
}

/// Step 2 ✕/Esc -> step 1, restoring the stashed filter text.
void _returnToSectionsStep() {
  _pickerSearchController.text = _stashedSectionsQuery;
  setState(() => _step = _ComposeStep.sections);
  if (hasPhysicalKeyboard()) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _step != _ComposeStep.sections) return;
      final text = _pickerSearchController.text;
      if (text.isNotEmpty) {
        _pickerSearchController.selection =
            TextSelection(baseOffset: 0, extentOffset: text.length);
      }
      _pickerSearchFocusNode.requestFocus();
    });
  }
}
```

(`_applyTarget` is unchanged: step-2’s `onPickConnection` passes the full chat/connector target, which already advances `_step = compose` and focuses the editor.)

- [ ] **Step 4: Update the build switch**

In `build` (`new_thread.dart:1493–1502`), replace the single `if (_step == _ComposeStep.target)` branch with:
```dart
if (_step == _ComposeStep.sections) {
  return _buildTargetPickerStep(context, multiPanel: layoutState.multiPanel);
}
if (_step == _ComposeStep.connection) {
  return _buildConnectionStep(context, multiPanel: layoutState.multiPanel);
}
```
(The remaining body is the compose surface, unchanged.)

- [ ] **Step 5: Per-path back-nav from compose**

Add:
```dart
/// Compose-step "go back": to step 2 when a recipient is chosen, else step 1.
void _backFromCompose() {
  if (_selectedRecipient != null) {
    setState(() => _step = _ComposeStep.connection);
    if (hasPhysicalKeyboard()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _step == _ComposeStep.connection) {
          _pickerSearchFocusNode.requestFocus();
        }
      });
    }
  } else {
    _returnToSectionsStep();
  }
}
```
- In `_buildComposeSurface` (`new_thread.dart:1418`), change the connection field’s `openModal: () async => _returnToTargetStep()` → `openModal: () async => _backFromCompose()`.
- In `_handleEditorKeys` (`new_thread.dart:1659`), change `_returnToTargetStep()` → `_backFromCompose()`.
- In `_buildThreadShortcuts` (`new_thread.dart:1689`), change the `_step == _ComposeStep.compose` Escape binding from `_returnToTargetStep` → `_backFromCompose`.
- Delete the now-unused `_returnToTargetStep` **only if** nothing else references it; otherwise keep it. (Its refresh-on-return logic is folded into `_returnToSectionsStep` already; prefer deleting.)

- [ ] **Step 6: Reset path**

In `_resetToFreshStart` (`new_thread.dart:246+`), also clear the new state: add `_selectedRecipient = null; _stashedSectionsQuery = '';` inside the `setState`, and set `_step = _ComposeStep.sections`.

- [ ] **Step 7: Imports**

Add imports for `ComposeSectionsView`, `ConnectionPickerView`, `ComposePeopleEntry` (from `compose_targets.dart`); remove the `TargetPickerList` import (after Task 9). Keep `ComposeTarget` import.

- [ ] **Step 8: Analyze the whole page + dependents**

Run: `cd apps/plot && flutter analyze lib/page/new_thread.dart lib/widget/compose lib/state/compose_targets.dart`
Expected: only the pre-existing info at `new_thread.dart:1078`; **no errors**.

- [ ] **Step 9: Commit**

```bash
git add apps/plot/lib/page/new_thread.dart
git commit -m "Wire three-step new-thread state machine (sections -> connection -> compose)"
```

---

## Task 9: Retire `target_picker_list.dart`

**Files:**
- Delete: `apps/plot/lib/widget/compose/target_picker_list.dart`

- [ ] **Step 1: Confirm no remaining references**

Run: `cd apps/plot && rg -n "TargetPickerList|target_picker_list" lib test`
Expected: no hits outside the file itself (the page now uses `ComposeSectionsView`). If `_FadingUnderline` or the search-field code is still referenced, ensure it was moved to `compose_search_field.dart` first.

- [ ] **Step 2: Delete and analyze**

```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/new-thread-sections
git rm apps/plot/lib/widget/compose/target_picker_list.dart
cd apps/plot && flutter analyze lib
```
Expected: only the pre-existing info; no errors about missing `TargetPickerList`.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "Remove obsolete TargetPickerList (replaced by sectioned picker)"
```

---

## Task 10: Full verification + docs

- [ ] **Step 1: Full analyze**

Run: `cd apps/plot && flutter analyze --no-fatal-infos lib test`
Expected: exits 0 (infos allowed; the pre-existing `new_thread.dart:1078` info remains). No errors.

- [ ] **Step 2: Run the pure tests**

Run: `cd apps/plot && flutter test test/widget/compose/pill_grid_geometry_test.dart test/state/compose_sections_test.dart`
Expected: all PASS.

- [ ] **Step 3: Run-app walkthrough (use the run-app skill)**

Verify each behaviour and capture a screenshot of step 1:
1. Step 1 shows three sections (People & twists with "twists" muted, Channels, Private notes), Option-A pills, generous spacing, "Start a thread" search w/ search icon.
2. Hovering a group/ad-hoc pill shows a tooltip of all names + addresses.
3. Typing filters all sections live and surfaces contacts beyond the at-rest set; empty sections hide.
4. Arrow keys: ←/→ within a section wrapping across rows; ↑/↓ across rows and section boundaries; ↑ from top row returns to the search bar; Enter activates.
5. Pick a contact → step 2: filter bar stays put, clears, placeholder "Select a connection", leading recipient chip shown; connection pills MRU-first.
6. ✕ on the chip and Esc both return to step 1 with the prior filter text restored.
7. Pick a connection → compose; contacts field shows the recipient; Esc/connection-field-tap returns to step 2.
8. From step 1, a twist / channel / private-note pill goes straight to compose with **no contacts field**; for a channel, the channel is visible on the connection field (e.g. `#general`); Esc from compose returns to step 1.

- [ ] **Step 4: Docs**

Add a bullet to the top section of `docs/updates.md` (plain language), e.g.:
> - Starting a new thread is now organized into clear sections — people & assistants, channels, and private notes — with a quick search to find any of them. Pick someone, then choose how to reach them.

(Skip `docs/features.md` unless the section model is a headline feature; this is a UX refinement of an existing feature.)

- [ ] **Step 5: Commit**

```bash
git add docs/updates.md
git commit -m "Document new-thread sectioned picker in updates"
```

- [ ] **Step 6: Finalize**

Run the `/finalize` checklist (lint, backwards-compat, error capture, docs, submodule). No backend/schema/submodule changes expected. Then use `superpowers:finishing-a-development-branch` to decide merge/PR.

---

## Self-review

**Spec coverage:**
- Three sections + "People and twists" muted header + twists in section 1 → Tasks 5,6 (✓). Channels non-person → Task 5 (`!t.isDmType`) (✓). Private notes focuses in colour → Tasks 2 (`FocusPillData`/`FocusLabel`),6 (✓).
- Option-A pill style, hover, group tooltip → Task 2 (✓).
- ~6–8 pills/section + global search + hide empty → Tasks 5 (`perSection`, `searchSections`),6 (drop empty) (✓).
- Search bar "Start a thread" + search icon; typing filters → Tasks 3,6 (✓).
- Step 2: pinned bar, clear, "Select a connection", leading reused-pill chip with ✕, MRU connections, Esc/✕ back restoring filter → Tasks 5 (`connectionsForRoster`),7,8 (`_pickRecipient`/`_returnToSectionsStep`) (✓).
- Step 2 always shown for a recipient (even Plot-only) → `connectionsForRoster` always returns ≥1 Plot option; `_pickRecipient` always enters the step (✓).
- Compose: contacts hidden for channel/private-note/twist (existing `_shouldShowContacts`), channel on connection field (existing `connectionTargetSubtitle` shows `#channel`), Esc → step 2 when recipient else step 1 → Task 8 (`_backFromCompose`) (✓).
- 2D-grid nav + geometry requirement → Tasks 1,3 (✓).

**Placeholder scan:** No TBD/TODO; pure-logic tasks carry full code; UI tasks carry real-API skeletons + exact integration diffs verified against verbatim current code. (UI pixel polish is explicitly verified via analyze + run-app per project norms — not a placeholder.)

**Type consistency:** `ComposePeopleEntry` (Task 5) is consumed by `ComposeSectionsView.onPickRecipient` and `ConnectionPickerView.recipient` (Tasks 6,7) and stored as `_selectedRecipient` (Task 8) — consistent. `ComposePillData` variants (Task 2) are produced by `_peopleEntryFor`/section builders (Tasks 5,6,7) and consumed by `ComposePill`/`PillGrid` (Tasks 2,4) — consistent. `PillGridGeometry.toSearchBar` sentinel (Task 1) consumed by `PillGrid._onKey` (Task 4) — consistent. `_applyTarget` signature unchanged; step-2 passes a full `ComposeTarget` as before.
