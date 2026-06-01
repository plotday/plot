# Thread Assignment in the AvatarGroup (channel-sharing + assignment connectors)

Date: 2026-05-31
Status: Approved — ready for implementation plan

## Problem

For threads sourced from a connector whose link type uses **channel-level sharing** (visibility is the external channel's membership, not per-thread contacts), the thread row and header today show a non-tappable muted channel-title label in place of the avatar group. Sharing isn't editable at the thread level because the channel governs it.

Several of these same connectors *also* support **assignment** (Linear, Attio, and others that will follow). Assignment is currently exposed only deep inside the thread page as a small `_LinkAssigneeBadge`. The high-traffic affordance — the avatar slot on the thread row and the unified header — does nothing for these threads.

The rule:

> For connectors with channel-level sharing AND assignment, show and manage assignment in the AvatarGroup on the ThreadWidget and in the header. In that case, don't show sharing; show assignment.

## Trigger condition

A thread enters **assignment mode** when it has at least one `Link` whose resolved `LinkTypeConfig` declares **both**:

- `sharingModel === "channel"`
- `supportsAssignee === true`

Among all qualifying links, the **primary assignment link** is the one with the smallest `createdAt` (deterministic; matches existing link ordering on the thread page). The primary link's `assigneeId` is what the row/header render. Other qualifying links' assignees are ignored at this level (they remain visible inside the thread page via `_LinkAssigneeBadge`).

Outside of assignment mode (no qualifying link, or only channel-sharing without assignment, or only thread/message-sharing), the existing `SharedCommandButton` rendering is unchanged.

## Component design

Three current callsites render the avatar/share affordance and all use `SharedCommandButton`:

- `apps/plot/lib/widget/thread.dart:816` (thread row)
- `apps/plot/lib/widget/unified_header.dart:456` (single-panel header)
- `apps/plot/lib/page/thread.dart:1464` (thread page header)

Introduce a thin dispatcher and one new sibling button:

### `SharedOrAssigneeButton` (dispatcher)

New widget that replaces every `SharedCommandButton` callsite. Given a `Thread`, it:

1. Computes `Thread.primaryAssignmentLink` (see Helper below).
2. If non-null, renders `AssigneeCommandButton(link: primary, ...)`.
3. Otherwise, renders the existing `SharedCommandButton(thread: thread, ...)` unchanged.

The dispatcher carries through the existing parameters (`tooltipBelow`, etc.) so the three callsites change only in widget name.

### `AssigneeCommandButton` (new)

Lives next to `SharedCommandButton` in `apps/plot/lib/widget/thread.dart`. Two visual states:

- **Assigned** (`link.assigneeId != null`):
  - Single-avatar `AvatarGroup(actors: [assigneeActor])` — same widget as the sharing variant, so sizing/overflow/initials behavior is identical and the visual swap is seamless.
  - Tooltip: `"Assigned to <name>"`.
  - Tap → `pickLinkAssignee(context, link)`.

- **Unassigned** (`link.assigneeId == null`):
  - `Button.icon` styled identically to the existing "Share" icon button.
  - Icon: `Icons.share` (which is already `FontAwesomeIcons.userPlus` per `apps/plot/lib/widget/icon.dart:177`) — the same person-plus glyph the user sees for "Share". Mutually exclusive with sharing mode, so reusing the glyph is unambiguous.
  - Label / tooltip: `"Assign"`.
  - Tap → `pickLinkAssignee(context, link)`.

### Shared picker: `pickLinkAssignee(context, link)`

Extract the body of `_LinkAssigneeBadge._showAssigneePicker` (`apps/plot/lib/page/thread.dart:1011+`) into a top-level function (or static on a small `LinkAssignee` namespace) so both `_LinkAssigneeBadge` and `AssigneeCommandButton` call one implementation. The function:

- Opens `SelectModal.open<_AssigneeOption>` with the same `Actor.get(types: [user, contact], inviteable: true, primary: true, limit: 50)` pool and `null → "Unassigned"` sentinel.
- On a different selection, writes `link.assigneeId = newId` via the existing `Link.save` path, which already triggers the connector's `onLinkUpdated` push.

`_AssigneeOption` moves with it (also private today; can become file-private to the picker module).

### Helper: `Thread.primaryAssignmentLink`

Pure synchronous function (extension method on `Thread`, or static on `Link`) returning the qualifying `Link?`:

```dart
Link? primaryAssignmentLink(Thread thread, List<Link> links) {
  final qualifying = links
      .where((l) {
        final cfg = l.getTypeConfig();
        return cfg?.sharingModel == "channel" && cfg?.supportsAssignee == true;
      })
      .toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  return qualifying.firstOrNull;
}
```

`Link.getTypeConfig()` is synchronous (`apps/plot/lib/store/link.dart:361–383`), so the dispatcher can call this in `build()` without futures. Links are already loaded reactively with the thread.

## Data flow

- **Read**: `Thread → links → primaryAssignmentLink → Link.assigneeId → Actor` — all Drift-reactive. No new streams, no async layers in the row.
- **Write**: picker writes `Link.assigneeId` on the primary link. Existing `onLinkUpdated` path in the twist runtime pushes to the external system (Linear, Attio). No new write infrastructure.

## Edge cases

- **Archived / unknown assignee contact**: `AvatarGroup` already handles missing actors with greyed initials. Tooltip falls back to `"Assigned to Unknown"`.
- **Qualifying link disappears** (unlinked, archived, type config changes): dispatcher's next build returns `null`, falling back to `SharedCommandButton`, which restores the muted channel-title label automatically.
- **Multi-link threads** with two qualifying links and different assignees: only the primary (oldest) is shown at row/header. The other remains editable via `_LinkAssigneeBadge` inside the thread page.
- **Thread also manually shared with extra Plot contacts**: per the rule, assignment wins — extra sharers are not rendered at the row/header. They're still visible inside the thread page sharing UI.
- **No assignment-capable connectors in a workspace**: dispatcher's `primaryAssignmentLink` always returns `null` → zero behavior change.
- **Read-only threads**: row/header already gate `SharedCommandButton` behind `!readOnly` (e.g. `page/thread.dart:1464`). `AssigneeCommandButton` inherits this — the dispatcher is only rendered when the existing share affordance would have been.
- **Row-callsite `isShared` gate**: `apps/plot/lib/widget/thread.dart:816` renders `SharedCommandButton` only when `isShared` is true. Channel-sharing connectors populate `thread.contacts` at sync time, so qualifying threads are already `isShared = true` and the dispatcher renders normally. Do **not** widen this gate to include assignment mode independently — a thread without any contacts/groups/invites isn't from a channel-sharing connector and there is no link to assign against.

## Out of scope (YAGNI)

- **Multi-assignee** — `Link.assigneeId` is single-nullable today; not changing the schema or picker semantics.
- **Showing channel members AND assignee together** — explicitly excluded by the rule.
- **Cross-link assignee unification** when multiple qualifying links exist — primary-only.
- **A new icon asset for "Assign"** — `Icons.share` is already the person-plus glyph; no new asset needed. If we later want differentiation, that's a separate visual-design pass.
- **Assignee-side filtering of the contact picker** to channel members only — the existing picker pool is reused as-is.

## Files touched (preview, not exhaustive)

- `apps/plot/lib/widget/thread.dart` — add `SharedOrAssigneeButton` dispatcher, `AssigneeCommandButton`. Leave `SharedCommandButton` unchanged.
- `apps/plot/lib/widget/unified_header.dart` — swap `SharedCommandButton` → `SharedOrAssigneeButton`.
- `apps/plot/lib/page/thread.dart` — swap `SharedCommandButton` → `SharedOrAssigneeButton`; extract `_LinkAssigneeBadge._showAssigneePicker` body into a shared `pickLinkAssignee(context, link)` function; make `_LinkAssigneeBadge` call it.
- `apps/plot/lib/store/link.dart` — possibly add or expose a `primaryAssignmentLink` helper (or keep it as a private function in `thread.dart`).

No schema changes. No worker changes. No connector code changes — `supportsAssignee` and `sharingModel` are already declared on the link types we care about (Linear confirmed; Attio confirmed for `supportsAssignee`).

## Verification

- Unit-test `primaryAssignmentLink` directly: cases for empty links, single qualifying link, multiple qualifying links of different `createdAt`, qualifying + non-qualifying mix, link type config absent.
- Widget-test `SharedOrAssigneeButton`: renders `AssigneeCommandButton` when given a thread with a qualifying link; renders `SharedCommandButton` otherwise.
- Widget-test `AssigneeCommandButton`: assigned state shows correct avatar; unassigned state shows "Assign" label; both states open the picker on tap.
- Integration smoke (driven by the `run-app` skill): a Linear-sourced thread row shows the assignee avatar where the channel title used to be, and tapping opens the picker; an unassigned Linear thread shows the "Assign" button; the same swap is visible in the unified header.
