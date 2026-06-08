import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/command/command.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/hooks.dart';
import 'package:plot/widget/widget.dart' hide Link;

/// Compact thread sharing control for the thread-page header.
/// - Not shared: `userPlus` icon. - Shared: `users` icon + recipient count.
/// Tap → editable share modal (thread model) or read-only participants
/// (message). Hidden entirely for the `none` and `channel` sharing models
/// (channel-sharing threads, e.g. Slack links or Linear issues, manage
/// membership in their source system, not in Plot).
class ThreadSharing extends HookWidget {
  const ThreadSharing(
      {required this.thread, this.tooltipBelow = false, super.key});

  final Thread thread;
  final bool tooltipBelow;

  @override
  Widget build(BuildContext context) {
    final linksSnapshot = useStream<List<Link>>(
      useMemoized(() => Link.watchForThread(thread.id), [thread.id]),
    );
    final links = linksSnapshot.data ?? const <Link>[];
    final sharingModel = Thread.resolveSharingModel(links);
    if (sharingModel == SharingModel.none ||
        sharingModel == SharingModel.channel) {
      return const SizedBox.shrink();
    }

    final command = PickThreadShared(thread);
    final count = command.sharedTotalCount;
    final shared = count > 0;

    final isHovered = useState(false);
    final iconColor =
        isHovered.value ? context.colour.hover : context.colour.muted;
    final iconSize = context.theme.iconSizes.base;

    // Shared: a small avatar-style count badge wearing the same AvatarGroup
    // outline that brightens on hover. Kept close to the sibling icon glyphs
    // (just enough to seat a two-digit count) so it doesn't overpower the row;
    // the button's minHeight (not the badge) governs the header height, so the
    // smaller circle sits centred without shrinking the row — see
    // ThreadAssignee for the button-padding approach.
    final iconContentStyle =
        context.theme.buttonStyles.ghost.md.iconContentStyle;
    final iconPadding = iconContentStyle.padding.resolve(TextDirection.ltr);
    final badgeSize = iconSize + 4;

    final Widget child = shared
        ? CountAvatar(count: count, size: badgeSize, clickable: true)
        : FaIcon(PlotIcon.share, size: iconSize, color: iconColor);

    void open() {
      if (sharingModel == SharingModel.thread) {
        context.run(command);
      } else {
        context.run(PickThreadParticipants(thread));
      }
    }

    return MouseRegion(
      onEnter: (_) => isHovered.value = true,
      onExit: (_) => isHovered.value = false,
      child: FTooltip(
        tipAnchor: tooltipBelow ? Alignment.topCenter : Alignment.bottomCenter,
        childAnchor:
            tooltipBelow ? Alignment.bottomCenter : Alignment.topCenter,
        tipBuilder: (context, controller) =>
            Text(shared ? 'People on this thread' : 'Share'),
        child: FButton.icon(
          // Match ThreadAssignee's button: drop the default vertical padding so
          // the avatar-sized badge fills the button without stretching the
          // header taller than the sibling 16px icon buttons; keep horizontal
          // padding + minHeight for edge-hug and vertical alignment.
          style: FButtonStyleDelta.delta(
            decoration: FVariantsDelta.delta([
              FVariantOperation.all(
                DecorationDelta.boxDelta(
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ]),
            iconContentStyle: FButtonIconContentStyleDelta.delta(
              padding: EdgeInsetsGeometryDelta.value(
                EdgeInsets.symmetric(horizontal: iconPadding.left),
              ),
              constraints: BoxConstraints(
                minHeight: iconContentStyle.constraints.minHeight,
              ),
            ),
          ),
          variant: FButtonVariant.ghost,
          onPress: open,
          child: child,
        ),
      ),
    );
  }
}
