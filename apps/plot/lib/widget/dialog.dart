import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos;
import 'package:platform_builder/platform_builder.dart';

class Dialog extends StatelessWidget {
  static Future<T?> show<T>({
    required BuildContext context,
    required Widget Function(BuildContext) builder,
    bool barrierDismissible = true,
  }) {
    return PlatformResolver.current(
      macOSResolver: () => macos.showMacosSheet<T>(
        context: context,
        builder: builder,
        barrierDismissible: barrierDismissible,
        barrierColor: macos.MacosDynamicColor.resolve(
          macos.MacosColors.black,
          context,
        ).withValues(alpha: 0.6),
      ),
      defaultResolver: () => material.showDialog<T>(
        context: context,
        builder: builder,
        barrierDismissible: barrierDismissible,
      ),
    );
  }

  const Dialog({
    required this.child,
    super.key,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => macos.MacosSheet(
        child: Container(
          child: child,
        ),
      ),
      builder: (_) => material.Dialog(
        child: child,
      ),
    );
  }
}
