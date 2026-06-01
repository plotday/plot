# Thread Assignment in the AvatarGroup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** For threads sourced from a connector with channel-level sharing AND assignment (Linear, Attio, …), show and manage the primary link's assignee in the avatar slot of `SharedCommandButton` — replacing the current channel-title label on the thread row and unified header.

**Architecture:** Extend the existing `SharedCommandButton` with one new branch (highest priority) that activates when the primary link's `LinkTypeConfig` has `sharingModel == channel` AND `supportsAssignee == true`. The branch shows the assignee in an `AvatarGroup` (or a labeled "Assign" button when unassigned) and opens the existing assignee picker on tap. The picker — currently private to `_LinkAssigneeBadge` — is extracted into a shared top-level function so both callers reuse one implementation.

**Tech Stack:** Flutter / forui (`FButton`, `FTooltip`), `flutter_hooks` (`useStream`, `useFuture`, `useState`), Drift store layer, existing `Link.updateAssignee` write path.

**Spec:** `docs/superpowers/specs/2026-05-31-thread-assignment-avatar-group-design.md`

**Testing note:** The Plot Flutter app does not unit-test helpers that depend on `Link.getTypeConfig()` (which reads the in-memory `TwistInstance` cache — no fixture infrastructure exists). The existing `Thread.resolveSharingModel` follows this pattern, and the new helper does too. Per the project's CLAUDE.md, verification is `flutter analyze` per task + a final `run-app` smoke. No new widget or unit tests are required by this plan.

---

### Task 1: Extract the assignee picker into a shared top-level function

Move the picker out of `_LinkAssigneeBadge` (private to `page/thread.dart`) so the new branch in `SharedCommandButton` can call the same code path. No behavior change to the existing `_LinkAssigneeBadge` — it just delegates.

**Files:**
- Create: `apps/plot/lib/widget/link_assignee_picker.dart`
- Modify: `apps/plot/lib/page/thread.dart` (lines around 960–1090)

- [ ] **Step 1: Create the new file with the extracted picker**

Create `apps/plot/lib/widget/link_assignee_picker.dart` with the body lifted verbatim from `_LinkAssigneeBadge._showAssigneePicker` (currently `apps/plot/lib/page/thread.dart:1011–1072`) plus the moved option class.

```dart
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/select_modal.dart';

/// Selection option for the assignee picker — equality based on actor id.
class LinkAssigneeOption {
  const LinkAssigneeOption(this.id, this.name, this.email);

  final Uuid? id;
  final String name;
  final String? email;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LinkAssigneeOption && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Opens the assignee picker for [link] and writes the selected assignee
/// via [Link.updateAssignee]. No-op when the user cancels or selects the
/// current assignee.
Future<void> pickLinkAssignee(BuildContext context, Link link) async {
  final result = await SelectModal.open<LinkAssigneeOption>(
    context,
    items: (search) async {
      final actors = await Actor.get(
        search: search,
        types: [ActorType.user, ActorType.contact],
        limit: 50,
        inviteable: true,
        primary: true,
      );
      actors.sort((a, b) {
        if (a.self != b.self) return a.self ? -1 : 1;
        return 0;
      });
      return [
        SelectGroup(
          items: [
            const LinkAssigneeOption(null, 'Unassigned', null),
            ...actors.map(
              (a) => LinkAssigneeOption(a.id, a.nameOrEmail, a.email),
            ),
          ],
        ),
      ];
    },
    itemBuilder: (option, _) {
      final isSelected = option.id == link.assigneeId;
      return ListTile(
        title: option.name,
        subtitle: (option.id != null &&
                option.email != null &&
                option.email != option.name)
            ? option.email
            : null,
        leadingBuilder: (isHovered, hasFocus) => Padding(
          padding: const EdgeInsets.only(left: 16, right: 8),
          child: isSelected
              ? Icon(
                  PlotIcon.done,
                  size: 14,
                  color: context.theme.colors.primary,
                )
              : const SizedBox(width: 14),
        ),
        disableInternalHover: true,
      );
    },
    selectedValue: link.assigneeId != null
        ? LinkAssigneeOption(link.assigneeId!, '', null)
        : const LinkAssigneeOption(null, 'Unassigned', null),
    prompt: 'Assign to',
  );

  if (!result.present || !context.mounted) return;
  final newId = result.value.id;
  if (newId != link.assigneeId) {
    await Link.updateAssignee(link, newId);
  }
}
```

If any import path above is off (e.g. `store/store.dart` vs `store/link.dart`, or `widget/select_modal.dart` lives elsewhere), match the existing imports at the top of `apps/plot/lib/page/thread.dart` exactly.

- [ ] **Step 2: Delete the old picker code and rewire `_LinkAssigneeBadge`**

In `apps/plot/lib/page/thread.dart`:

1. Add the new import near the other `package:plot/widget/...` imports at the top:

```dart
import 'package:plot/widget/link_assignee_picker.dart';
```

2. Delete the private `_AssigneeOption` class (currently around lines 1074–1090 — the class declaration ending after `int get hashCode => id.hashCode;`).

3. Replace `_LinkAssigneeBadge._showAssigneePicker` (currently `apps/plot/lib/page/thread.dart:1010–1072`) with a one-line delegation:

```dart
  Future<void> _showAssigneePicker(BuildContext context) =>
      pickLinkAssignee(context, link);
```

- [ ] **Step 3: Verify analyze passes**

Run: `cd apps/plot && flutter analyze lib/page/thread.dart lib/widget/link_assignee_picker.dart`
Expected: `No issues found!` (or only pre-existing issues unrelated to the move).

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/widget/link_assignee_picker.dart apps/plot/lib/page/thread.dart
git commit -m "$(cat <<'EOF'
refactor: extract link assignee picker to shared file

Lift _LinkAssigneeBadge._showAssigneePicker into a top-level
pickLinkAssignee(context, link) so SharedCommandButton can reuse it
for channel-sharing+assignment connectors. No behavior change.
EOF
)"
```

---

### Task 2: Add `Thread.resolvePrimaryAssignmentLink` helper

Pure function next to `Thread.resolveSharingModel`. Returns the earliest qualifying `Link` (channel-sharing + assignment) or null. Mirrors the existing helper's signature and lack of unit test (no fixture infra for `link.getTypeConfig()`).

**Files:**
- Modify: `apps/plot/lib/store/thread.dart` (insert immediately after `resolveSharingModel`, currently line 4737)

- [ ] **Step 1: Add the helper**

In `apps/plot/lib/store/thread.dart`, insert after the closing brace of `resolveSharingModel` (currently line 4744, right after `return cfg?.sharingModel ?? SharingModel.thread; }`):

```dart
  /// Returns the link whose assignee should be shown in the thread row /
  /// unified header avatar slot, or null when the thread is not in
  /// "assignment mode".
  ///
  /// A thread is in assignment mode when its primary (earliest-created)
  /// link's [LinkTypeConfig] has BOTH `sharingModel == channel` AND
  /// `supportsAssignee == true`. Only the primary link participates; other
  /// qualifying links remain visible inside the thread page via the
  /// per-link assignee badge.
  static Link? resolvePrimaryAssignmentLink(List<Link> links) {
    if (links.isEmpty) return null;
    final primary = [...links]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final candidate = primary.first;
    final cfg = candidate.getTypeConfig();
    if (cfg?.sharingModel == SharingModel.channel &&
        cfg?.supportsAssignee == true) {
      return candidate;
    }
    return null;
  }
```

Notes for the implementer:
- `SharingModel.channel` and the `LinkTypeConfig.supportsAssignee` bool already exist — see `apps/plot/lib/page/thread.dart:896` for the same `supportsAssignee` read pattern.
- The "primary = earliest by `createdAt`" rule must match `resolveSharingModel` exactly so the new branch and the existing channel-title branch agree on which link they're talking about.

- [ ] **Step 2: Verify analyze passes**

Run: `cd apps/plot && flutter analyze lib/store/thread.dart`
Expected: `No issues found!`

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/store/thread.dart
git commit -m "$(cat <<'EOF'
feat: add Thread.resolvePrimaryAssignmentLink helper

Returns the earliest-created link when its LinkTypeConfig has both
sharingModel=channel and supportsAssignee=true. Used by the row /
unified header avatar slot to decide whether to show assignment in
place of the channel-title label.
EOF
)"
```

---

### Task 3: Wire the assignment branch into `SharedCommandButton`

Add a new branch — highest priority, ahead of the existing channel-title and AvatarGroup branches — that renders the assignee (or "Assign" affordance) and routes taps to `pickLinkAssignee`.

**Files:**
- Modify: `apps/plot/lib/widget/thread.dart` (inside `SharedCommandButton.build`, currently 849–1058)

- [ ] **Step 1: Add the import**

At the top of `apps/plot/lib/widget/thread.dart`, near the other `package:plot/widget/...` imports:

```dart
import 'package:plot/widget/link_assignee_picker.dart';
```

- [ ] **Step 2: Resolve the assignment link and load the assignee actor**

In `SharedCommandButton.build`, immediately after the existing `final sharingModel = Thread.resolveSharingModel(links);` line (currently `apps/plot/lib/widget/thread.dart:876`), insert:

```dart
    // Assignment mode: primary link is from a connector with channel
    // sharing AND assignment. The avatar slot shows/edits the assignee
    // instead of the channel title.
    final assignmentLink = Thread.resolvePrimaryAssignmentLink(links);

    // Resolve the assignee Actor for the AvatarGroup. useFuture rebuilds
    // when assignmentLink.assigneeId changes; null assigneeId is the
    // "unassigned" state.
    final assigneeId = assignmentLink?.assigneeId;
    final assigneeSnapshot = useFuture(
      useMemoized(
        () => assigneeId != null
            ? Actor.getOne(assigneeId)
            : Future<Actor?>.value(null),
        [assigneeId?.toString()],
      ),
    );
    final assignee = assigneeSnapshot.data;
```

If `Actor.getOne` returns a non-nullable `Actor` and throws on missing, wrap it: `() async { try { return await Actor.getOne(assigneeId); } catch (_) { return null; } }`. Inspect the existing usage in `_LinkAssigneeBadge._resolveAssigneeName` (`apps/plot/lib/page/thread.dart:1000–1007`) — it catches and returns 'Unassigned', so use the same `try { return await Actor.getOne(...); } catch (_) { return null; }` shape here.

- [ ] **Step 3: Add the assignment branch as the first case in the `final Widget child;` block**

In `apps/plot/lib/widget/thread.dart`, the existing `final Widget child;` block starts around line 965 with `if (sharingModel == SharingModel.channel && channelTitle != null)`. Change the leading `if` into `else if`, and prepend the new branch:

```dart
    final Widget child;
    if (assignmentLink != null) {
      if (assignee != null) {
        // Assigned: single-avatar group, same sizing/styling as the
        // shared variant so visual swap is seamless.
        child = AvatarGroup(
          actors: [assignee],
          totalCount: 1,
          size: avatarSize,
          scheduleContacts: null,
          tooltipBelow: tooltipBelow,
          clickable: true,
        );
      } else {
        // Unassigned: matches the unshared icon button's geometry.
        child = SizedBox(
          width: iconSize,
          height: iconSize,
          child: Center(
            child: FaIcon(
              PlotIcon.shareAdd, // userPlus glyph — see widget/icon.dart:202
              size: iconSize,
              color: iconColor,
            ),
          ),
        );
      }
    } else if (sharingModel == SharingModel.channel && channelTitle != null) {
      // ... existing channel-title branch unchanged ...
```

Leave the existing channel-title, AvatarGroup-shared, and unshared-icon branches as-is — they keep working when `assignmentLink == null`.

- [ ] **Step 4: Route taps through `pickLinkAssignee` when in assignment mode**

In the same file, find the `FButton.icon` construction (currently around `apps/plot/lib/widget/thread.dart:1007`) and update `onPress`. The current line reads:

```dart
      onPress: (sharingModel == SharingModel.channel && channelTitle != null)
          ? null
          : () => context.run(command),
```

Replace with:

```dart
      onPress: assignmentLink != null
          ? () => pickLinkAssignee(context, assignmentLink)
          : (sharingModel == SharingModel.channel && channelTitle != null)
              ? null
              : () => context.run(command),
```

- [ ] **Step 5: Update the tooltip wrap so the unassigned "Assign" state gets a tooltip**

In the same file, find the tooltip branch (currently `apps/plot/lib/widget/thread.dart:1045–1058`):

```dart
    if (shared ||
        (sharingModel == SharingModel.channel && channelTitle != null)) {
      return button;
    }
    return MouseRegion(
      onEnter: (_) => isHovered.value = true,
      onExit: (_) => isHovered.value = false,
      child: FTooltip(
        tipAnchor: tooltipBelow ? Alignment.topCenter : Alignment.bottomCenter,
        childAnchor: tooltipBelow
            ? Alignment.bottomCenter
            : Alignment.topCenter,
        tipBuilder: (context, controller) => Text(command.title),
        child: button,
      ),
    );
```

Replace with:

```dart
    // No tooltip wrap when the visible child already conveys context:
    // - Assigned avatar (assignee name is in the AvatarGroup's own tooltip)
    // - Channel-mode title (visible label)
    // - Shared AvatarGroup (unified contact tooltip)
    if ((assignmentLink != null && assignee != null) ||
        shared ||
        (sharingModel == SharingModel.channel && channelTitle != null)) {
      return button;
    }

    // Unassigned (assignment mode) → "Assign". Unshared → command.title ("Share").
    final tooltipText = (assignmentLink != null && assignee == null)
        ? 'Assign'
        : command.title;

    return MouseRegion(
      onEnter: (_) => isHovered.value = true,
      onExit: (_) => isHovered.value = false,
      child: FTooltip(
        tipAnchor: tooltipBelow ? Alignment.topCenter : Alignment.bottomCenter,
        childAnchor: tooltipBelow
            ? Alignment.bottomCenter
            : Alignment.topCenter,
        tipBuilder: (context, controller) => Text(tooltipText),
        child: button,
      ),
    );
```

- [ ] **Step 6: Verify analyze passes**

Run: `cd apps/plot && flutter analyze lib/widget/thread.dart`
Expected: `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add apps/plot/lib/widget/thread.dart
git commit -m "$(cat <<'EOF'
feat: assignment AvatarGroup on channel-sharing+assignment connectors

When the primary link's LinkTypeConfig has sharingModel=channel and
supportsAssignee=true, the thread row and unified header avatar slot
show the assignee (AvatarGroup) or an "Assign" affordance instead of
the channel-title label. Taps open the existing assignee picker.

Spec: docs/superpowers/specs/2026-05-31-thread-assignment-avatar-group-design.md
EOF
)"
```

---

### Task 4: Run-app smoke test

The spec's verification step. Confirm the swap actually renders end-to-end on a Linear-sourced thread. No commit — verification only.

**Files:** none modified.

- [ ] **Step 1: Launch the app via the run-app skill**

Use the `run-app` skill (defined in this project) to launch Plot.app in the agent profile and connect dart-mcp.

- [ ] **Step 2: Verify assigned state on the thread row**

1. Navigate to a priority that contains Linear-sourced threads (your own Linear workspace if signed in to the agent profile; otherwise seed one).
2. Find a Linear thread whose issue has an assignee.
3. Confirm the row's trailing slot shows a single-avatar `AvatarGroup` with the assignee's initials / image — NOT the channel-title text label.

Take a screenshot via dart-mcp `flutter_driver_command` for the record.

- [ ] **Step 3: Verify unassigned state on the thread row**

1. Find (or unset on a) Linear thread with no assignee.
2. Confirm the row's trailing slot shows an icon button with the person-plus glyph.
3. Hover (where supported) and confirm the tooltip reads "Assign".

- [ ] **Step 4: Verify the picker opens and writes back**

1. Tap the avatar (or "Assign" icon) on the row.
2. Confirm the assignee picker modal opens with "Assign to" prompt and an "Unassigned" option followed by user/contact actors.
3. Select an actor, confirm modal closes, and confirm the row immediately reflects the new assignee.
4. Open the thread page and confirm `_LinkAssigneeBadge` next to the link title shows the same assignee — i.e. both surfaces share state.

- [ ] **Step 5: Verify the unified header (single-panel mode)**

1. Open the thread (so the thread page is mounted with its header).
2. Confirm the header's trailing affordance shows the same AvatarGroup / "Assign" icon as the row.
3. Tap it; confirm the same picker opens.

- [ ] **Step 6: Sanity check — non-assignment threads unchanged**

1. Open a thread that's NOT from a channel-sharing+assignment connector (e.g. a Plot-native thread, or a calendar event).
2. Confirm the existing sharing behavior is unchanged: shared AvatarGroup or share icon as before; no "Assign" tooltip; no assignee picker on tap.
3. Open a channel-sharing thread from a connector WITHOUT `supportsAssignee` (if any exist in the workspace) and confirm the muted channel-title label still renders as today.

- [ ] **Step 7: Report findings**

If everything passes, mark the smoke complete. If any state misrenders, file the discrepancy as a follow-up (do NOT silently retry — investigate root cause).

---

## Self-Review

**1. Spec coverage:**

| Spec section | Implemented in |
|---|---|
| Trigger condition (channel + supportsAssignee, earliest createdAt) | Task 2 (`Thread.resolvePrimaryAssignmentLink`) |
| `SharedOrAssigneeButton` dispatcher | Replaced with in-place branch in `SharedCommandButton` (Task 3) — equivalent outcome, avoids duplicate link-watching that a wrapper would introduce. Three callsites unchanged. |
| `AssigneeCommandButton` assigned/unassigned states | Task 3, Step 3 (the new `if (assignmentLink != null)` branch with `assignee != null` / `== null` sub-branches) |
| `pickLinkAssignee` shared picker | Task 1 |
| `Thread.primaryAssignmentLink` helper | Task 2 (named `resolvePrimaryAssignmentLink` to match sibling `resolveSharingModel`) |
| Read path Drift-reactive | Task 3, Step 2 (`useStream` for links already exists; `useFuture` for assignee Actor) |
| Write path via existing `Link.updateAssignee` | Task 1 (preserved in `pickLinkAssignee`) |
| Edge: archived/unknown assignee → greyed initials | Task 3, Step 2 (catch-and-null fallback; `AvatarGroup` renders nothing/greyed when actor list is empty) |
| Edge: qualifying link disappears | Task 2 returns null → falls through to existing branches; no extra code needed |
| Edge: multi-link → primary only | Task 2 (`primary.first` after sort) |
| Edge: thread also manually shared → assignment wins | Task 3 branch order (assignment branch is first) |
| Edge: no qualifying connectors → zero change | Task 2 returns null → no behavior change |
| Edge: read-only threads | Existing `!readOnly` gates on `SharedCommandButton` callsites are untouched |
| Edge: row `isShared` gate preserved | No callsite modification in this plan |
| Out of scope items (multi-assignee, new icon, etc.) | Explicitly not implemented |
| Verification: smoke via `run-app` | Task 4 |

**Dispatcher decision deviation:** The spec proposed a `SharedOrAssigneeButton` wrapper that would call either `SharedCommandButton` or a new `AssigneeCommandButton`. While re-reading `SharedCommandButton.build` for this plan, I noticed it already does its own `Link.watchForThread` + primary-link sort + branched render — so a wrapper would either re-subscribe to the same stream (wasted work) or pass pre-fetched links in (awkward API change for three callsites). Adding one branch in-place is cleaner, reuses the existing link stream and sizing logic, and keeps the three call sites byte-identical. The user-visible behavior matches the spec exactly. Calling this out explicitly so the executor doesn't get surprised.

**2. Placeholder scan:** Every step has full code blocks where code is changed. No "TBD", "implement later", or hand-waved error handling. The one optional pattern flagged (`try/catch` around `Actor.getOne` if it throws on missing) is grounded in a specific existing usage pattern (`page/thread.dart:1000–1007`) with the exact code shape supplied.

**3. Type consistency:**
- `LinkAssigneeOption` (renamed from `_AssigneeOption`) is consistently used in Task 1.
- `pickLinkAssignee(BuildContext, Link)` signature is consistent across Tasks 1 and 3.
- `Thread.resolvePrimaryAssignmentLink(List<Link>) → Link?` signature consistent across Tasks 2 and 3.
- `assignmentLink`, `assignee`, `assigneeId` variable names used uniformly inside Task 3.
- `SharingModel.channel` and `LinkTypeConfig.supportsAssignee` symbol references match the existing codebase (`store/thread.dart:4741`, `page/thread.dart:896`).
