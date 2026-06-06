import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/widget/widget.dart';

/// Compose-surface channel field. Shown in place of the contacts field for a
/// channel-sharing connection (e.g. Slack, Linear), where the audience is the
/// external channel's membership rather than a per-thread contact roster.
///
/// Modal-only: tapping the row (or pressing Enter when focused) opens the
/// channel picker. The row shows a folder icon followed by the
/// currently-targeted channel's title.
class ChannelComposeField extends StatelessWidget {
  const ChannelComposeField({
    super.key,
    required this.channelTitle,
    required this.openModal,
  });

  /// Title of the currently-targeted channel (e.g. "general"). Empty when no
  /// channel is resolved yet, in which case a "Select a channel" prompt shows.
  final String channelTitle;

  /// Opens the channel picker modal.
  final Future<void> Function() openModal;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return ComposeSelectField(
      tooltip: 'Channel',
      label: Row(
        mainAxisSize: MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ComposeLeadingIcon(
            child: Icon(
              FontAwesomeIcons.folder,
              size: theme.iconSizes.base,
            ),
          ),
          const SizedBox(width: composeIconGap),
          Expanded(
            child: Text(
              channelTitle.isEmpty ? 'Select a channel' : channelTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.typography.md.copyWith(
                color: theme.plotColors.muted,
              ),
            ),
          ),
        ],
      ),
      onOpen: openModal,
    );
  }
}
