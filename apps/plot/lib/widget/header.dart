import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart' as macos;
import 'package:auto_route/auto_route.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';

class Header extends StatelessWidget {
  Header({
    Widget? main,
    String? title,
    this.commands = const [],
    super.key,
  }) : main = main ?? (title != null ? Text(title) : null);

  final Widget? main;
  final List<Command> commands;

  @override
  Widget build(BuildContext context) {
    Widget? backButton = context.router.canPop()
        ? Container(
            width: 20.0,
            alignment: Alignment.centerLeft,
            child: macos.MacosBackButton(
              fillColor: macos.MacosColors.transparent,
              onPressed: () => context.router.pop(),
            ),
          )
        : null;

    return Row(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                if (backButton != null) backButton,
                if (main != null) main!,
              ],
            ),
          ),
        ),
        Row(
          children: commands.map((command) => Button.icon(command)).toList(),
        ),
      ],
    );
  }
}
