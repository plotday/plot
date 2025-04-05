import 'package:flutter/widgets.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:flutter/material.dart' as material;
// import 'package:macos_window_utils/macos_window_utils.dart' as macos_win;

import 'colour_scheme.dart';

class Scaffold extends StatelessWidget {
  const Scaffold({
    required this.body,
    this.header,
    this.translucent = false,
    super.key,
  });

  final Widget body;
  final Widget? header;
  final bool translucent;

  @override
  Widget build(BuildContext context) {
    final page = Container(
      color: translucent ? null : context.colour.background,
      child: Column(
        children: [if (header != null) header!, Expanded(child: body)],
      ),
    );

    return PlatformBuilder(
      // macOSBuilder: (_) => macos_win.TitlebarSafeArea(
      //   child: page,
      // ),
      androidBuilder: (_) => material.Material(child: page),
      builder: (_) => page,
    );
  }
}
