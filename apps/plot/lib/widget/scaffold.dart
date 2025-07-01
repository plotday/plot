import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:forui/forui.dart';

import 'colour_scheme.dart';

class Scaffold extends StatelessWidget {
  const Scaffold({
    required this.body,
    this.header,
    this.sidebar,
    this.footer,
    this.translucent = false,
    super.key,
  });

  final Widget body;
  final Widget? header;
  final Widget? sidebar;
  final Widget? footer;
  final bool translucent;

  @override
  Widget build(BuildContext context) {
    return material.Material(
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Container(
          color: translucent ? null : context.colour.background,
          child: FScaffold(
            header: header,
            sidebar: sidebar,
            footer: footer,
            childPad: false,
            child: body,
          ),
        ),
      ),
    );
  }
}
