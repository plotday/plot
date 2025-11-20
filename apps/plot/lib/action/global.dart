import 'package:flutter/widgets.dart';

import 'action.dart';

class GlobalShortcuts extends StatelessWidget {
  GlobalShortcuts({required this.child, super.key});

  final Widget child;
  final List<StaticActionGroup> actions = [
    StaticActionGroup(
      title: 'Priorities',
      actions: [PickCurrentPriority(), NewPriority()],
    ),
    settingsActions,
    accountActions,
  ];

  @override
  Widget build(BuildContext context) {
    return ActionScope(actions: actions, child: child);
  }
}
