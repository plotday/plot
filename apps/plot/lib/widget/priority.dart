import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';

import 'logging.dart';

class PriorityLabel extends StatelessWidget {
  const PriorityLabel({
    required this.priority,
    this.context,
    this.onlyAncestors = false,
    this.onSelect,
    super.key,
  });

  final Priority? priority;
  final Priority? context;
  final bool onlyAncestors;
  final void Function(PriorityId)? onSelect;

  @override
  Widget build(BuildContext context) {
    final ancestors = priority?.ancestors(context: this.context) ?? [];
    return Row(
      children: [
        ...ancestors.indexed.map((entry) {
          final i = entry.$1;
          final ancestor = entry.$2;
          final isLast = i == ancestors.length - 1;
          return DefaultTextStyle(
            style: DefaultTextStyle.of(context).style.copyWith(
              color: context.theme.colors.mutedForeground,
              fontSize: context.theme.typography.xs.fontSize,
            ),
            child: Row(
              children: [
                Tapable(
                  onTap: () async {
                    if (onSelect != null) {
                      onSelect?.call(ancestor.id);
                    } else {
                      final priority = await Priority.getOne(ancestor.id);
                      if (!context.mounted) return;
                      context.run<void>(ChangeCurrentPriority(priority));
                    }
                  },
                  child: Text(ancestor.title),
                ),
                if (!isLast || !onlyAncestors) Text(Priority.separator),
              ],
            ),
          );
        }),
        if (!onlyAncestors)
          DefaultTextStyle(
            style: DefaultTextStyle.of(
              context,
            ).style.copyWith(fontSize: context.theme.typography.xs.fontSize),
            child: Text(priority?.title ?? 'Everything'),
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
            context.theme.colors.primary,
            context.theme.colors.mutedForeground,
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
    this.onHover,
    super.key,
  });

  /// If true, show as a parent note with some functionality (such as navigating to it) disabled.
  final Priority priority;

  /// Display priority relative to this priority.
  final Priority? context;

  final bool selected;

  final void Function(bool hovered)? onHover;

  @override
  Widget build(BuildContext context) {
    bool isContext = priority == this.context;
    bool contextChild = priority.parentId == this.context?.id;
    bool expanded =
        isContext || (!priority.doNow && !priority.done && !priority.pinned);
    return ListTile(
      command: !isContext ? ChangeCurrentPriority(priority) : null,
      leadingCommand: priorityPrimaryCommand(priority),
      trailingCommands: [ShowPriorityCommands(priority)],
      body: Viewer(
        markdown: (expanded ? priority.note : null) ?? priority.title,
        onTap: () {
          context.run<void>(ChangeCurrentPriority(priority));
        },
      ),
      header: contextChild
          ? null
          : PriorityLabel(
              priority: priority,
              context: this.context,
              onlyAncestors: true,
            ),
      selected: selected,
      onHover: onHover,
    );
  }
}
