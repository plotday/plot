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
    return Wrap(
      spacing: 8,
      children: [
        Text(priority!.name),
        if (ancestors.isNotEmpty)
          ...(List<Widget>.of([
                  FIcon.data(
                    PlotIcon.pipe,
                    size: 14,
                    color: context.theme.colorScheme.mutedForeground,
                  ),
                ]) +
                ancestors
                    .map((a) => Text(a.name))
                    .toList()
                    .expand(
                      (widget) => [
                        widget,
                        FIcon.data(
                          PlotIcon.right,
                          size: 14,
                          color: context.theme.colorScheme.mutedForeground,
                        ),
                      ],
                    )
                    .toList()
            ..removeLast()),
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

class PriorityTile extends StatelessWidget {
  const PriorityTile({
    required this.priority,
    this.balances,
    this.maxTime,
    this.fullPath = false,
    this.title,
    super.key,
  });

  final Priority priority;
  final BalanceByType? balances;
  final Duration? maxTime;
  final bool fullPath;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return ListTile.command(
      ChangeCurrentPriority(priority, fullPath: fullPath),
      title: title,
      commands: priorityCommands(priority).commands,
      key: ValueKey(priority.id.toString()),
      // subtitle: balances != null ? PriorityBalance(balances: balances!) : null,
    );
  }
}
