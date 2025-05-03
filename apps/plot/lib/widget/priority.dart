import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';

class PriorityLabel extends StatelessWidget {
  const PriorityLabel({required this.priority, super.key});

  final Priority? priority;

  @override
  Widget build(BuildContext context) {
    if (priority == null) {
      return const Text('All Priorities');
    }
    final ancestors = priority!.ancestors;
    return Row(
      children: [
        Text(priority!.label),
        if (ancestors.isNotEmpty)
          DefaultTextStyle(
            style: DefaultTextStyle.of(
              context,
            ).style.copyWith(color: context.theme.colorScheme.mutedForeground),
            child: Text('  ${priority!.parent!.pathLabel}'),
          ),
      ],
    );
  }
}

class PriorityBalance extends StatelessWidget {
  const PriorityBalance({required this.balances, this.max, super.key});

  final BalanceByType balances;
  final Duration? max;

  Duration get past =>
      (balances[BalanceType.accepted]?.pastTime ?? Duration.zero) +
      (balances[BalanceType.session]?.pastTime ?? Duration.zero);
  Duration get future =>
      (balances[BalanceType.accepted]?.futureTime ?? Duration.zero) +
      (balances[BalanceType.tentative]?.futureTime ?? Duration.zero) +
      (balances[BalanceType.session]?.futureTime ?? Duration.zero);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          spacing: 8,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.ideographic,
          children: [
            (past >= const Duration(minutes: 1))
                ? DurationText(duration: past)
                : Container(),
            (future >= const Duration(minutes: 1))
                ? DurationText(duration: future)
                : Container(),
          ],
        ),
        SegmentedLine(
          lengths: [past.inMinutes.toDouble(), future.inMinutes.toDouble()],
          colors: [
            context.theme.colorScheme.primary,
            context.theme.colorScheme.mutedForeground,
          ],
          total: max?.inMinutes.toDouble(),
        ),
      ],
    );
  }
}

class PriorityWidget extends StatelessWidget {
  const PriorityWidget({
    required this.priority,
    this.isParent = false,
    super.key,
  });

  /// If true, show as a parent note with some functionality (such as navigating to it) disabled.
  final Priority priority;
  final bool isParent;

  @override
  Widget build(BuildContext context) {
    if (isParent) {
      return ListTile(
        body: Viewer(markdown: priority.note!),
        // TODO: support pinning and reordering
        // trailingCommands: [if (!priority.pinned) PinPriority(priority)],
      );
    }
    return ListTile(
      command: ChangeCurrentPriority(priority),
      trailingCommands: [
        if (!priority.pinned) PinPriority(priority),
        priorityCommand(priority),
      ],
      body:
          priority.note?.isNotEmpty == true &&
                  !priority.doNow &&
                  !priority.done &&
                  !priority.pinned
              ? Viewer(markdown: priority.note!)
              : null,
    );
  }
}
