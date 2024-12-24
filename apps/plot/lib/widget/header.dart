import 'package:flutter/widgets.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';

class Header extends StatelessWidget {
  const Header({
    required this.activities,
    required this.currentActivity,
    required this.onCurrentActivitySelected,
    this.balances,
    super.key,
  });

  final List<Activity> activities;
  final Activity? currentActivity;
  final BalanceByType? balances;
  final void Function(Activity?) onCurrentActivitySelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: ActivitySelector(
            activities: activities,
            selected: currentActivity,
            onSelect: onCurrentActivitySelected,
          ),
        ),
        if (balances != null)
          ActivityBalance(
            balances: balances!,
            isNow: true,
          ),
      ],
    );
  }
}
