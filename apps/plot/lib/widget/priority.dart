import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';

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
    // bool contextChild = priority.parentId == this.context?.id;
    return ListTile(
      command: !isContext
          ? CommandWrapper(ChangeCurrentPriority(priority), icon: Value(null))
          : null,
      trailingCommands: [ShowPriorityCommands(priority)],
      body: PriorityLabel(priority: priority),
      selected: selected,
      onHover: onHover,
    );
  }
}

class PriorityLabel extends StatelessWidget {
  PriorityLabel({
    List<PriorityAncestor>? ancestors,
    this.priority,
    Priority? context,
    this.onSelect,
    super.key,
  }) : ancestors =
           ancestors ?? priority?.ancestors(context: context) ?? const [];

  final List<PriorityAncestor> ancestors;
  final Priority? priority;
  final void Function(PriorityId)? onSelect;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ...ancestors.indexed.expand((entry) {
        final i = entry.$1;
        final ancestor = entry.$2;
        final isLast = i == ancestors.length - 1;
        return [
          Flexible(
            child: DefaultTextStyle(
              style: DefaultTextStyle.of(context).style.copyWith(
                color: context.theme.colors.mutedForeground,
                fontSize: context.theme.typography.xs.fontSize,
              ),
              child: Tapable(
                onTap: () async {
                  if (onSelect != null) {
                    onSelect?.call(ancestor.id);
                  } else {
                    final priority = await Priority.getOne(ancestor.id);
                    if (!context.mounted) return;
                    context.run(ChangeCurrentPriority(priority));
                  }
                },
                child: Text(
                  ancestor.title,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ),
          ),
          if (!isLast || priority != null)
            DefaultTextStyle(
              style: DefaultTextStyle.of(context).style.copyWith(
                color: context.theme.colors.mutedForeground,
                fontSize: context.theme.typography.xs.fontSize,
              ),
              child: Text(Priority.separator),
            ),
        ];
      }),
      if (priority != null)
        Flexible(
          child: DefaultTextStyle(
            style: DefaultTextStyle.of(
              context,
            ).style.copyWith(fontSize: context.theme.typography.xs.fontSize),
            child: Text(
              priority!.title,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ),
    ],
  );
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
