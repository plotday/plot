import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'package:plot/router.dart';
import 'action.dart';

class GlobalShortcuts extends StatelessWidget {
  GlobalShortcuts({required this.child, super.key});

  final Widget child;
  final List<StaticActionGroup> actions = [settingsActions];

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          context.focusedRouter.maybePop();
        },
      },
      child: ActionScope(actions: actions, child: child),
    );
  }
}
