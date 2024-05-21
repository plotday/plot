import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos;

import 'style.dart';

class Scaffold extends StatelessWidget {
  const Scaffold({required this.body, super.key});

  @override
  Widget build(BuildContext context) {
    switch (style) {
      case Style.mac:
        return macos.MacosScaffold(
          children: [
            macos.ContentArea(
              builder: (_, __) => body,
            )
          ],
        );
      default:
        return material.Scaffold(
          body: body,
        );
    }
  }

  final Widget body;
}
