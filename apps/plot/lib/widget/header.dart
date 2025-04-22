import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/command/command.dart';

class Header extends StatelessWidget {
  Header({
    Widget? main,
    String? title,
    this.commands = const [],
    this.modal = false,
    super.key,
  }) : main = main ?? (title != null ? Text(title) : null);

  final Widget? main;
  final List<Command> commands;
  final bool modal;

  @override
  Widget build(BuildContext context) {
    return FHeader(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          if (!modal && context.router.canPop())
            FTappable(
              onPress: () => context.router.maybePop(),
              child: FIcon(FAssets.icons.arrowLeft, size: 14),
            ),
          if (main != null) main!,
        ],
      ),
      actions: [
        ...commands.map(
          (command) => FHeaderAction(
            icon:
                command.icon != null
                    ? FIcon.data(command.icon!, size: 14)
                    : Text(command.title),
            onPress: () => context.run<void>(command),
          ),
        ),
        if (modal && context.router.canPop())
          FTappable(
            onPress: () => context.router.maybePop(),
            child: FIcon(FAssets.icons.x, size: 14),
          ),
      ],
    );
  }
}
