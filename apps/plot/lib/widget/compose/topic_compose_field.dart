import 'package:flutter_svg/flutter_svg.dart';

import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/widget/widget.dart';

/// Compose-surface topic field. Shown in place of the contacts field when the
/// draft is posted into a Plot topic, where the audience is the topic's
/// membership rather than a per-thread contact roster.
///
/// Tapping the row (or pressing Enter when focused) goes back a step (re-opening
/// the target picker). The row shows a hashtag glyph followed by the topic name.
class TopicComposeField extends StatelessWidget {
  const TopicComposeField({
    super.key,
    required this.topicName,
    required this.openModal,
  });

  /// Name of the topic the thread is posted into.
  final String topicName;

  /// Re-opens the target picker (the topic field is the "connection" choice for
  /// a topic thread, so tapping it steps back).
  final Future<void> Function() openModal;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return ComposeSelectField(
      tooltip: 'Topic',
      label: Row(
        mainAxisSize: MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ComposeLeadingIcon(
            child: SvgPicture.asset(
              'assets/plot-icon.svg',
              width: theme.iconSizes.base,
              height: theme.iconSizes.base,
            ),
          ),
          const SizedBox(width: composeIconGap),
          Expanded(
            child: Text(
              topicName.isEmpty ? 'Topic' : topicName,
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
