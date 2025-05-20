import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'colour_scheme.dart';

class Scaffold extends StatelessWidget {
  const Scaffold({
    required this.body,
    this.header,
    this.footer,
    this.translucent = false,
    super.key,
  });

  final Widget body;
  final Widget? header;
  final Widget? footer;
  final bool translucent;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: translucent ? null : context.colour.background,
      child: FScaffold(
        header: header,
        footer: footer,
        childPad: false,
        child: body,
      ),
    );
  }
}
