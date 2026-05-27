import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/state/theme.dart' show ThemeBloc;
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/util/platform.dart';
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
      onPress: () {
        widget.onTap().catchError((Object e, StackTrace s) {
          Tracker.captureException(e, s);
        });
      },
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

    final hoverable = widget.selected
        ? button
        : MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: button,
          );

    // Show a tooltip with the full subtitle when there's extra context:
    // account name for channel-type targets, or the connection display name
    // for DM-type targets.
    if (widget.target.accountName == null && !widget.target.isDmType) {
      return hoverable;
    }
    return FTooltip(
      tipBuilder: (context, controller) => Text(widget.target.subtitle),
      child: hoverable,
    );
  }
}

/// Modal listing every create-target plus the synthetic "Plot thread"
/// row. Returns the picked ConnectionChoice or null on dismiss.
class ConnectionPickerModal {
  ConnectionPickerModal._();

  static Future<ConnectionChoice?> open(BuildContext context) async {
    final targets = await loadCreateTargets();
    if (!context.mounted) return null;

    final choices = <ConnectionChoice>[
      ConnectionChoice.plotThread,
      ...targets.map(ConnectionChoice.target),
    ];

    final result = await SelectModal.open<ConnectionChoice>(
      context,
      items: (search) async {
        final text = search?.trim().toLowerCase() ?? '';
        final filtered = text.isEmpty
            ? choices
            : choices.where((c) => c.searchText.contains(text)).toList();
        return [SelectGroup(title: null, items: filtered)];
      },
      itemBuilder: (choice, _) => switch (choice) {
        PlotThreadChoice() => ListTile(
            leadingBuilder: (_, _) => Builder(
              builder: (context) => Padding(
                padding: EdgeInsets.only(
                  left: context.theme.spacing.lg,
                  right: 8,
                ),
                child: SvgPicture.asset(
                  'assets/plot-icon.svg',
                  width: 16,
                  height: 16,
                ),
              ),
            ),
            title: 'Plot thread',
          ),
        TargetConnectionChoice(:final target) =>
          connectionTargetTile(context, target),
      },
      prompt: 'Pick a connection',
      emptyMessage: 'No connections available',
      showFilter: true,
    );
    if (!result.present) return null;
    return result.value;
  }
}
