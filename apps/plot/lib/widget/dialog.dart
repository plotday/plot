import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:flutter/material.dart' as material;
import 'package:platform_builder/platform_builder.dart';

import 'colour_scheme.dart';

class Dialog extends StatelessWidget {
  static Future<T?> show<T>({
    required BuildContext context,
    required Widget Function(BuildContext) builder,
    bool barrierDismissible = true,
  }) {
    return PlatformResolver.current(
      defaultResolver:
          () => material.showAdaptiveDialog<T>(
            context: context,
            builder: builder,
            barrierDismissible: barrierDismissible,
          ),
    );
  }

  const Dialog({
    required this.child,
    this.constraints = const BoxConstraints(maxHeight: 500, maxWidth: 750),
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
    BoxConstraints constraints = this.constraints.enforce(
      BoxConstraints(
        maxHeight: mediaQuery.size.height * maxHeightPercentage,
        maxWidth: mediaQuery.size.width * maxWidthPercentage,
      ),
    );

    return PlatformBuilder(
      builder:
          (_) => FDialog.raw(
            style: context.theme.dialogStyle.copyWith(
              decoration: BoxDecoration(
                color: context.colour.background,
                border: Border.all(color: context.colour.border),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            builder:
                (context, style) => ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: child,
                ),
          ),
    );
  }
}
