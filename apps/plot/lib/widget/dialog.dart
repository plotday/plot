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
    this.constraints = const BoxConstraints(
      maxHeight: 500,
      maxWidth: 750,
    ),
    this.padding = const EdgeInsets.all(16),
    this.maxWidthPercentage = 0.8,
    this.maxHeightPercentage = 0.8,
    super.key,
  });

  final Widget child;
  final BoxConstraints constraints;
  final EdgeInsets padding;
  final double maxWidthPercentage;
  final double maxHeightPercentage;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    BoxConstraints constraints = this.constraints.enforce(BoxConstraints(
          maxHeight: mediaQuery.size.height * maxHeightPercentage,
          maxWidth: mediaQuery.size.width * maxWidthPercentage,
        ));

    return PlatformBuilder(
      macOSBuilder: (_) => macos.MacosSheet(
        child: Container(
          constraints: constraints,
          padding: padding,
          child: child,
        ),
      ),
      builder: (_) => material.Dialog(
        child: child,
      ),
    );
  }
}
