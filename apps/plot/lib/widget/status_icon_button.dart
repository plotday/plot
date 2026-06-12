import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/analytics/conventions.dart';
import 'package:plot/command/command.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/widget/button.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/list_tile.dart';
import 'package:plot/widget/select_modal.dart';

/// Resolves the [StatusIcon] for a raw status string within [cfg], or null when
/// the config, status, or the status's `icon` is absent.
StatusIcon? statusIconFor(LinkTypeConfig? cfg, String? status) {
  if (cfg == null || status == null) return null;
  return cfg.statuses
      ?.where((s) => s.status == status)
      .firstOrNull
      ?.icon;
}

/// Renders [link]'s status as a single glyph. Tapping opens the status picker
/// when the link type declares more than one status. Returns an empty box when
/// the link has no resolvable status icon.
///
/// [showWhenHiddenDefault] controls whether a status flagged `hiddenDefault`
/// renders: true in the page header (always show), false on the feed row
/// (suppress resting defaults like calendar "Confirmed").
///
/// [buttonStyle] makes the icon render with the same footprint, size,
/// muted/hover colours and circular hover background as the other trailing
/// icon buttons (e.g. Mute) — used in the thread-feed row so the status icon
/// sits flush in the always-on trailing cluster. The default (false) keeps the
/// compact 14px glyph used in the thread page header.
class StatusIconButton extends StatelessWidget {
  const StatusIconButton({
    required this.link,
    this.showWhenHiddenDefault = false,
    this.buttonStyle = false,
    super.key,
  });

  final Link link;
  final bool showWhenHiddenDefault;
  final bool buttonStyle;

  @override
  Widget build(BuildContext context) {
    final cfg = link.getTypeConfig();
    final statuses = cfg?.statuses;
    final current =
        statuses?.where((s) => s.status == link.status).firstOrNull;
    final icon = current?.icon;
    if (icon == null) return const SizedBox.shrink();
    if (current!.hiddenDefault && !showWhenHiddenDefault) {
      return const SizedBox.shrink();
    }

    final canChange = statuses != null && statuses.length > 1;

    if (buttonStyle) {
      // Feed row: match the other always-on trailing icon buttons exactly.
      if (canChange) {
        // Routed through [Button.icon] for a pixel-identical match with Mute.
        return Button.icon(_ChangeLinkStatus(link, statuses, current));
      }
      // Single, non-interactive status: same footprint (so it aligns in the
      // row) but no tap target or hover background.
      final iconSize = context.theme.iconSizes.base;
      final pad = context
          .theme
          .buttonStyles
          .ghost
          .md
          .iconContentStyle
          .padding
          .resolve(TextDirection.ltr);
      return Padding(
        padding: EdgeInsets.symmetric(vertical: pad.top),
        child: SizedBox(
          width: iconSize + pad.horizontal,
          height: iconSize,
          child: Center(
            child: Icon(
              icon.glyph,
              size: iconSize,
              color: context.theme.colors.mutedForeground,
            ),
          ),
        ),
      );
    }

    // Header / compact rendering: small 14px glyph.
    final glyph = Icon(
      icon.glyph,
      size: 14,
      color: context.theme.colors.mutedForeground,
    );

    if (!canChange) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: glyph,
      );
    }
    return FTooltip(
      tipBuilder: (context, controller) => Text(current.label),
      child: GestureDetector(
        onTap: () => _showStatusPicker(context, link, statuses),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: glyph,
        ),
      ),
    );
  }

  static Future<void> _showStatusPicker(
    BuildContext context,
    Link link,
    List<LinkStatus> statuses,
  ) async {
    final result = await SelectModal.open<String>(
      context,
      items: (search) async => [
        SelectGroup(items: statuses.map((s) => s.status).toList()),
      ],
      itemBuilder: (status, _) {
        final s = statuses.firstWhere((ls) => ls.status == status);
        return ListTile(
          title: s.label,
          leadingBuilder: (isHovered, hasFocus) => Padding(
            padding: const EdgeInsets.only(left: 16, right: 8),
            child: s.icon != null
                ? Icon(
                    s.icon!.glyph,
                    size: 14,
                    color: s.status == link.status
                        ? context.theme.colors.primary
                        : context.theme.colors.mutedForeground,
                  )
                : s.status == link.status
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
      selectedValue: link.status,
      prompt: 'Set status',
    );

    if (!result.present || !context.mounted) return;
    final selected = result.value;
    if (selected != link.status) {
      await Link.updateStatus(link, selected);
    }
  }
}

/// Opens the status picker for [_link]. Carries the current status' glyph and
/// label as its icon/title so [Button.icon] renders it identically to the
/// other trailing icon commands (e.g. Mute) on the feed row.
class _ChangeLinkStatus extends Command {
  _ChangeLinkStatus(this._link, this._statuses, LinkStatus current)
    : super(
        title: current.label,
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
        icon: current.icon!.glyph,
      );

  final Link _link;
  final List<LinkStatus> _statuses;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await StatusIconButton._showStatusPicker(context, _link, _statuses);
    return const CommandDone();
  }
}
