import 'package:flutter/widgets.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';

class Header extends StatelessWidget {
  const Header({
    required this.priorities,
    required this.currentPriority,
    required this.onCurrentPrioritySelected,
    this.balances,
    this.isNow = true,
    super.key,
  });

  final List<Priority> priorities;
  final Priority? currentPriority;
  final BalanceByType? balances;
  final bool isNow;
  final void Function(Priority?) onCurrentPrioritySelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: PrioritySelector(
            priorities: priorities,
            selected: currentPriority,
            onSelect: onCurrentPrioritySelected,
          ),
        ),
        if (balances != null)
          PriorityBalance(
            balances: balances!,
            isNow: isNow,
          ),
      ],
    );
  }
}
