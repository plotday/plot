import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:plot/state/theme.dart' show ThemeBloc;
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/widget/widget.dart';

/// Compose-surface connection field. Modal-only: tapping the row (or
/// pressing Enter when focused) opens [openModal]. The row shows the
/// connection logo followed by a "{Connector} {linktype}" title with the
/// account / channel name as the subtitle (e.g. "Gmail email" /
/// "kris@plot.day"). The synthetic Plot-thread choice shows the Plot
/// mark and "Plot thread".
class ConnectionComposeField extends StatelessWidget {
  const ConnectionComposeField({
    super.key,
    required this.activeChoice,
    required this.openModal,
  });

  /// Currently selected choice (always non-null — defaults to Plot thread).
  final ConnectionChoice activeChoice;

  /// Opens the connection picker modal.
  final Future<void> Function() openModal;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final isDark = context.read<ThemeBloc>().isDarkMode(context);

    final Widget logo;
    final String title;
    final String subtitle;
    switch (activeChoice) {
      case PlotThreadChoice():
        logo = SvgPicture.asset(
          'assets/plot-icon.svg',
          width: theme.iconSizes.sm,
          height: theme.iconSizes.sm,
        );
        title = 'Plot thread';
        subtitle = '';
      case TargetConnectionChoice(:final target):
        final url = isDark
            ? (target.linkType.logoDark ?? target.linkType.logo)
            : target.linkType.logo;
        logo = url != null
            ? LogoImage(
                url: url,
                size: theme.iconSizes.sm,
                fallback: const Icon(PlotIcon.link),
              )
            : const Icon(PlotIcon.link);
        title = connectionTargetTitle(target);
        subtitle = connectionTargetSubtitle(target);
    }

    return ComposeSelectField(
      tooltip: 'Connection',
      label: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.max,
        children: [
          logo,
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.typography.sm.copyWith(
                      color: theme.plotColors.veryMuted,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      onOpen: openModal,
    );
  }
}

/// "{Connector} {linktype}" with a leading "New " stripped from the link
/// type label and the rest lowercased. e.g. "Gmail email", "Linear issue".
/// Shared by the compose row and the picker modal.
String connectionTargetTitle(CreateTarget target) {
  final type = _normalizeLinkTypeLabel(target.linkType.label);
  return type.isEmpty
      ? target.connectorName
      : '${target.connectorName} $type';
}

/// The connection-identifying subtitle: account name for DM-style targets,
/// channel title (or account) for channel-style targets.
String connectionTargetSubtitle(CreateTarget target) {
  if (target.isDmType) return target.accountName ?? '';
  return target.channel?.title ?? target.accountName ?? '';
}

String _normalizeLinkTypeLabel(String label) {
  var s = label.trim();
  if (s.toLowerCase().startsWith('new ')) {
    s = s.substring(4).trim();
  }
  if (s.isEmpty) return s;
  return s[0].toLowerCase() + s.substring(1);
}
