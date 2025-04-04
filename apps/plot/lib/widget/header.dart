import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/widget/widget.dart';
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
      prefixActions: [if (!modal && backButton != null) backButton],
      suffixActions: [
        ...commands.map((command) => Button.icon(command)),
        if (modal && backButton != null) backButton,
      ],
      title: main ?? const Text(''),
    );
  }
}
