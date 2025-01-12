import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';

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
      spacing: 4,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.ideographic,
      children: [
        if (past >= const Duration(minutes: 1)) DurationText(duration: past),
        if (isNow && future >= const Duration(minutes: 1)) ...[
          const Text("+"),
          DurationText(duration: future),
        ],
      ],
    );
  }
}

class PriorityWidget extends StatelessWidget {
  const PriorityWidget({
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
