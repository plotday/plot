import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';

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
                const PlotIcon.pipe(size: 14, color: material.Colors.grey)
              ]) +
              ancestors
                  .map((a) => Text(a.name))
                  .toList()
                  .expand((widget) => [
                        widget,
                        const PlotIcon.right(
                            size: 14, color: material.Colors.grey)
                      ])
                  .toList()
            ..removeLast())
      ],
    );
  }
}

class PriorityBalance extends StatelessWidget {
  const PriorityBalance({
    required this.balances,
    this.isNow = false,
    super.key,
  });

  final BalanceByType balances;
  final bool isNow;

  Duration get past =>
      (balances[BalanceType.accepted]?.pastTime ?? Duration.zero) +
      (balances[BalanceType.session]?.pastTime ?? Duration.zero);
  Duration get future =>
      (balances[BalanceType.accepted]?.futureTime ?? Duration.zero) +
      (balances[BalanceType.tentative]?.futureTime ?? Duration.zero) +
      (balances[BalanceType.session]?.futureTime ?? Duration.zero);

  @override
  Widget build(BuildContext context) {
    return Row(
      spacing: 8,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.ideographic,
      children: [
        if (past >= const Duration(minutes: 1))
          DurationText(duration: past, icon: const PlotIcon.up(size: 14)),
        if (isNow && future >= const Duration(minutes: 1)) ...[
          DurationText(duration: future, icon: const PlotIcon.down(size: 14)),
        ],
      ],
    );
  }
}

class PriorityTile extends StatelessWidget {
  const PriorityTile({
    required this.priority,
    this.balances,
    this.onTap,
    this.selected = false,
    this.isNow = false,
    super.key,
  });

  final Priority? priority;
  final BalanceByType? balances;
  final VoidCallback? onTap;
  final bool selected;
  final bool isNow;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: () {
        onTap?.call();
      },
      selected: selected,
      key: ValueKey(priority?.id.toString()),
      leading: (balances?[BalanceType.todo]?.count != null &&
              balances![BalanceType.todo]!.count > 0)
          ? Badge(count: balances![BalanceType.todo]!.count)
          : null,
      leadingSize: const Size(16, 16),
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(priority?.name ?? 'Everything'),
          if (balances != null)
            PriorityBalance(balances: balances!, isNow: isNow),
        ],
      ),
    );
  }
}
