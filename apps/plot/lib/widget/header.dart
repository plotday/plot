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
    Widget? backButton =
        context.router.canPop()
            ? modal
                ? FHeaderAction.x(onPress: () => context.router.maybePop())
                : FHeaderAction.back(onPress: () => context.router.maybePop())
            : null;

    return FHeader.nested(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (main != null || (!modal && backButton != null))
            Row(
              spacing: 8,
              children: [
                if (!modal && backButton != null) backButton,
                if (main != null) main!,
              ],
            ),
          if (modal && backButton != null) backButton,
        ],
      ),
    );
  }
}
