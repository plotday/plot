import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart' as macos;

class Header extends StatelessWidget {
  Header({
    Widget? main,
    String? title,
    this.actions,
    super.key,
  }) : main = main ?? (title != null ? Text(title) : null);

  final Widget? main;
  final List<Widget>? actions;

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
          children: actions ?? [],
        ),
      ],
    );
  }
}
