import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart' as macos;

import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';

class HeaderAction {
  const HeaderAction({
    required this.icon,
    required this.label,
    this.showLabel = true,
    required this.onPressed,
  });
  final Widget icon;
  final String label;
  final bool showLabel;
  final VoidCallback onPressed;
}

class Header extends StatelessWidget {
  const Header({
    this.title,
    this.actions,
    super.key,
  });

  final String? title;
  final List<HeaderAction>? actions;

  @override
  Widget build(BuildContext context) {
    Widget? backButton = ModalRoute.of(context)?.canPop != true
        ? null
        : Container(
            width: 20.0,
            alignment: Alignment.centerLeft,
            child: macos.MacosBackButton(
              fillColor: macos.MacosColors.transparent,
              onPressed: () => Navigator.maybePop(context),
            ),
          );

    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              if (backButton != null) backButton,
              if (title != null)
                Expanded(
                  child: Text(title!),
                ),
            ],
          ),
        ),
        Row(
          children: (actions ?? [])
              .map(
                (action) => IconButton(
                  icon: action.icon,
                  onPressed: action.onPressed,
                ),
              )
              .toList(),
        ),
      ],
    );
  }
}

class GlobalHeader extends StatelessWidget {
  const GlobalHeader({
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
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
      ),
    );
  }
}
