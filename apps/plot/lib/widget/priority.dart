import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';

class PriorityLabel extends StatelessWidget {
  const PriorityLabel({
    required this.priority,
    this.context,
    this.onlyAncestors = false,
    super.key,
  });

  final Priority? priority;
  final Priority? context;
  final bool onlyAncestors;

  @override
  Widget build(BuildContext context) {
    if (priority == null) {
      return const Text('All Priorities');
    }
    final ancestors = priority!.ancestors;
    return Row(
      children: [
        if (!onlyAncestors) Text("${priority!.title} "),
        if (ancestors.isNotEmpty)
          DefaultTextStyle(
            style: DefaultTextStyle.of(context).style.copyWith(
              color: context.theme.colorScheme.mutedForeground,
              fontSize: context.theme.typography.xs.fontSize,
            ),
            child: Text(priority!.ancestorsLabel(context: this.context)),
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
    this.context,
    this.selected = false,
    super.key,
  });

  /// If true, show as a parent note with some functionality (such as navigating to it) disabled.
  final Priority priority;

  /// Display priority relative to this priority.
  final Priority? context;

  final bool selected;

  @override
  Widget build(BuildContext context) {
    bool isContext = priority == this.context;
    bool contextChild = priority.ancestors.last.id == this.context?.id;
    bool expanded =
        isContext || (!priority.doNow && !priority.done && !priority.pinned);
    return ListTile(
      command: !isContext ? ChangeCurrentPriority(priority) : null,
      trailingCommands: [
        if (!priority.pinned) PinPriority(priority),
        priorityCommand(priority),
      ],
      body: Viewer(
        markdown: (expanded ? priority.note : null) ?? priority.title,
      ),
      header:
          contextChild
              ? null
              : PriorityLabel(
                priority: priority,
                context: this.context,
                onlyAncestors: true,
              ),
      selected: selected,
    );
  }
}
