import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/spinner.dart';

/// Footer shown below search results: a spinner while a remote search is in
/// flight, an archived-matches hint button, or an offline note. Shared between
/// the activity feed ([PriorityPage]) and the global Search tab. Requires an
/// ancestor [PriorityBloc] for [PriorityBloc.toggleShowArchived].
class SearchFooter extends StatelessWidget {
  const SearchFooter({required this.state, super.key});

  final PriorityState state;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.plotColors;
    final padding = EdgeInsets.symmetric(
      horizontal: context.contentPaddingH,
      vertical: context.theme.spacing.md,
    );

    if (state.remoteSearchInProgress) {
      return Padding(
        padding: padding,
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [Spinner()],
        ),
      );
    }

    if (state.hasArchivedMatches && !state.showArchived) {
      return Padding(
        padding: padding,
        child: Align(
          alignment: Alignment.center,
          child: FButton(
            variant: FButtonVariant.ghost,
            onPress: () => context.read<PriorityBloc>().toggleShowArchived(),
            child: const Text('View archived items matching this search'),
          ),
        ),
      );
    }

    if (state.remoteSearchOffline) {
      return Padding(
        padding: padding,
        child: Text(
          'Offline — showing local matches only',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: colors.veryMuted,
            fontSize: context.theme.typography.sm.fontSize,
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }
}
