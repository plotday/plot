import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/store/store.dart';
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
class StatusIconButton extends StatelessWidget {
  const StatusIconButton({
    required this.link,
    this.showWhenHiddenDefault = false,
    super.key,
  });

  final Link link;
  final bool showWhenHiddenDefault;

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
