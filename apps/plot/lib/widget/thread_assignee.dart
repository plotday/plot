import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/store/store.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/hooks.dart';
import 'package:plot/widget/widget.dart' hide Link;

/// Reusable thread-level assignee control. Reads `thread.assigneeId`.
/// - Assigned: clickable single-avatar group (hover-highlight border).
/// - Unassigned: an "Assign" icon (only when [showWhenUnassigned]).
/// Display-only (no tap) when the thread is read-only.
class ThreadAssignee extends HookWidget {
  const ThreadAssignee({
    required this.thread,
    this.showWhenUnassigned = false,
    this.tooltipBelow = false,
    super.key,
  });

  final Thread thread;
  final bool showWhenUnassigned;
  final bool tooltipBelow;

  @override
  Widget build(BuildContext context) {
    final assigneeId = thread.assigneeId;
    final readOnly = thread.isReadOnly;

    // Resolve the assignee Actor for the AvatarGroup. useFuture rebuilds when
    // assigneeId changes; null assigneeId is the "unassigned" state.
    final assigneeSnapshot = useFuture(
      useMemoized(() async {
        if (assigneeId == null) return null;
        try {
          return await Actor.getOne(assigneeId);
        } catch (_) {
          return null;
        }
      }, [assigneeId?.toString(), thread.id]),
    );
    // Synchronous cache fallback avoids a first-frame "Assign" flicker on warm
    // cache hits.
    final assignee = assigneeSnapshot.data ??
        (assigneeId != null ? Actor.fromCache(assigneeId) : null);

    // Expand the avatar circle into the button's icon padding so the initials
    // are legible while overall height matches neighbouring icon buttons —
    // same sizing approach as the sharing button.
    final iconContentStyle =
        context.theme.buttonStyles.ghost.md.iconContentStyle;
    final iconPadding = iconContentStyle.padding.resolve(TextDirection.ltr);
    final iconSize = context.theme.iconSizes.base;
    final avatarSize = iconSize + iconPadding.top + iconPadding.bottom;

    // Track hover so the unassigned icon matches sibling `Button.icon`s:
    // resting `muted`, hover lifts to `hover`.
    final isHovered = useState(false);
    final iconColor =
        isHovered.value ? context.colour.hover : context.colour.muted;

    if (assignee == null && !showWhenUnassigned) {
      return const SizedBox.shrink();
    }

    final Widget child;
    if (assignee != null) {
      // Assigned: single-avatar group, same sizing/styling as the sharing
      // variant so visual swap is seamless.
      child = AvatarGroup(
        actors: [assignee],
        totalCount: 1,
        size: avatarSize,
        scheduleContacts: null,
        tooltipBelow: tooltipBelow,
        clickable: !readOnly,
      );
    } else {
      // Unassigned: matches the unshared icon button's geometry.
      child = SizedBox(
        width: iconSize,
        height: iconSize,
        child: Center(
          child: FaIcon(PlotIcon.assignAdd, size: iconSize, color: iconColor),
        ),
      );
    }

    // Read-only: show the avatar but never allow changing it.
    if (readOnly) {
      return assignee != null ? child : const SizedBox.shrink();
    }

    final button = FButton.icon(
      style: FButtonStyleDelta.delta(
        decoration: FVariantsDelta.delta([
          FVariantOperation.all(
            DecorationDelta.boxDelta(borderRadius: BorderRadius.circular(999)),
          ),
        ]),
        iconContentStyle: FButtonIconContentStyleDelta.delta(
          // Keep horizontal padding so this button hugs the row edge the same
          // way as sibling icon buttons; drop the default minWidth so the
          // button hugs the avatar's natural width. Keep minHeight for vertical
          // alignment with sibling icon buttons.
          padding: EdgeInsetsGeometryDelta.value(
            EdgeInsets.symmetric(horizontal: iconPadding.left),
          ),
          constraints: BoxConstraints(
            minHeight: iconContentStyle.constraints.minHeight,
          ),
        ),
      ),
      variant: FButtonVariant.ghost,
      onPress: () => pickThreadAssignee(context, thread),
      child: child,
    );

    // Assigned avatar carries its own name tooltip — no wrap needed.
    if (assignee != null) return button;

    return MouseRegion(
      onEnter: (_) => isHovered.value = true,
      onExit: (_) => isHovered.value = false,
      child: FTooltip(
        tipAnchor: tooltipBelow ? Alignment.topCenter : Alignment.bottomCenter,
        childAnchor:
            tooltipBelow ? Alignment.bottomCenter : Alignment.topCenter,
        tipBuilder: (context, controller) => const Text('Assign'),
        child: button,
      ),
    );
  }
}

/// Selection option for the assignee picker — equality by actor id.
class _AssigneeOption {
  const _AssigneeOption(this.id, this.name, this.email);
  final ActorId? id;
  final String name;
  final String? email;
  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is _AssigneeOption && id == other.id;
  @override
  int get hashCode => id.hashCode;
}

/// Opens the thread-level assignee picker. Writes the primary
/// assignment-capable link's assignee for connector threads (which the mirror
/// trigger reflects onto the thread); otherwise writes `thread.assigneeId`.
///
/// Single-select: applies on tap and closes immediately. Flat list (no section
/// headers): Unassign first (only when currently assigned), then the current
/// assignee, then everyone else. The current assignee is indicated by colour +
/// font weight, not a leading checkmark.
Future<void> pickThreadAssignee(BuildContext context, Thread thread) async {
  final links = await Link.getForThread(thread.id);
  final primaryLink = Thread.resolvePrimaryAssignmentLink(links);
  final currentId = primaryLink?.assigneeId ?? thread.assigneeId;
  final connectionId = primaryLink?.createdBy;

  // Connection-aware ranking: assignees on other links in this connection
  // first (rank 2), then link authors in this connection (rank 1), then
  // everyone else (rank 0). Plot-only threads (no connection) fall back to
  // thread participants (rank 1) then alphabetical.
  final rank = <String, int>{};
  if (connectionId != null) {
    final connLinks = await Link.getForConnection(connectionId);
    for (final l in connLinks) {
      final a = l.assigneeId?.toString();
      if (a != null) rank[a] = 2;
    }
    for (final l in connLinks) {
      final au = l.authorId?.toString();
      if (au != null) rank.putIfAbsent(au, () => 1);
    }
  } else {
    for (final c in thread.contacts) {
      rank.putIfAbsent(ActorId.fromUuid(c).toString(), () => 1);
    }
  }

  if (!context.mounted) return;

  final result = await SelectModal.open<_AssigneeOption>(
    context,
    items: (search) async {
      final actors = await Actor.get(
        search: search,
        types: [ActorType.user, ActorType.contact],
        limit: 50,
        inviteable: true,
        primary: true,
      );
      // If the current assignee isn't in the results (e.g. an externally-set
      // Linear assignee who isn't inviteable), resolve and prepend them so the
      // picker always shows them with the correct current-assignee highlight and
      // selectedValue points at an existing row.
      if (currentId != null && !actors.any((a) => a.id == currentId)) {
        try {
          final current =
              Actor.fromCache(currentId) ?? await Actor.getOne(currentId);
          actors.insert(0, current);
        } catch (_) {
          // If we can't resolve the current assignee, proceed without it.
        }
      }
      actors.sort((a, b) {
        // Current assignee first, then ranked, then self, then by name.
        final aCur = a.id == currentId ? 1 : 0;
        final bCur = b.id == currentId ? 1 : 0;
        if (aCur != bCur) return bCur - aCur;
        final ar = rank[a.id.toString()] ?? 0;
        final br = rank[b.id.toString()] ?? 0;
        if (ar != br) return br - ar;
        if (a.self != b.self) return a.self ? -1 : 1;
        return a.nameOrEmail
            .toLowerCase()
            .compareTo(b.nameOrEmail.toLowerCase());
      });
      return [
        SelectGroup(
          items: [
            if (currentId != null) const _AssigneeOption(null, 'Unassign', null),
            ...actors.map((a) => _AssigneeOption(a.id, a.nameOrEmail, a.email)),
          ],
        ),
      ];
    },
    itemBuilder: (option, _) {
      final isCurrent = option.id != null && option.id == currentId;
      return ListTile(
        title: option.name,
        // Current assignee shown by colour + weight, not a checkmark.
        textStyle: isCurrent
            ? context.theme.typography.md.copyWith(
                color: context.theme.colors.primary,
                fontWeight: FontWeight.w600,
              )
            : null,
        subtitle: (option.id != null &&
                option.email != null &&
                option.email != option.name)
            ? option.email
            : null,
        // Leading avatar, matching the share modal's rows. The 20/12 padding
        // and iconSizes.base size reproduce the spacing the command-based
        // share rows get from the leading slot + 12px icon gap.
        leadingBuilder: (isHovered, hasFocus) => Padding(
          padding: const EdgeInsets.only(left: 20, right: 12),
          child: option.id != null
              ? Avatar(
                  actorId: option.id,
                  size: context.theme.iconSizes.base,
                )
              : Icon(
                  PlotIcon.shareRemove,
                  size: context.theme.iconSizes.base,
                  color: context.theme.plotColors.muted,
                ),
        ),
        disableInternalHover: true,
      );
    },
    selectedValue:
        currentId != null ? _AssigneeOption(currentId, '', null) : null,
    prompt: 'Assign to',
  );

  if (!result.present || !context.mounted) return;
  final newId = result.value.id;
  if (newId == currentId) return;
  if (primaryLink != null) {
    await Link.updateAssignee(primaryLink, newId);
  } else {
    await Thread.updateAssignee(thread, newId);
  }
}
