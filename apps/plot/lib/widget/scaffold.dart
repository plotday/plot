import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:forui/forui.dart';
import 'package:platform_builder/platform_builder.dart';

import 'colour_scheme.dart';

class Scaffold extends StatelessWidget {
  const Scaffold({
    required this.body,
    this.header,
    this.sidebar,
    this.translucent = false,
    this.scrollable = true,
    super.key,
  });

  final Widget body;
  final Widget? header;
  final Widget? sidebar;
  final bool translucent;
  final bool scrollable;

  Widget _buildBody(BuildContext context) {
    if (!scrollable) {
      return body;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return SafeArea(child: SingleChildScrollView(child: body));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final wrappedBody = _buildBody(context);
    final scaffold = FScaffold(
      header: header,
      sidebar: sidebar,
      childPad: false,
      child: wrappedBody,
    );

    return PlatformBuilder(
      androidBuilder: (_) => material.Material(child: scaffold),
      webBuilder: (_) => material.Material(child: scaffold),
      builder: (_) => Directionality(
        textDirection: TextDirection.ltr,
        child: Container(
          color: translucent ? null : context.colour.background,
          child: scaffold,
        ),
      ),
    );
  }
}
