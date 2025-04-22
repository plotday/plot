import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:flutter/material.dart' as material;
import 'package:platform_builder/platform_builder.dart';
import 'package:drift/drift.dart' show Value;

import 'colour_scheme.dart';

class Dialog extends StatelessWidget {
  static Future<Value<T>> show<T>({
    required BuildContext context,
    required Widget Function(BuildContext) builder,
    bool barrierDismissible = true,
  }) async {
    final ret = await material.showDialog<Value<T>>(
      context: context,
      builder: builder,
      barrierColor: context.colourOnce.barrier,
      barrierDismissible: barrierDismissible,
    );
    if (ret == null) {
      return Value.absent();
    }
    return ret;
  }

  const Dialog({
    required this.body,
    this.header,
    this.constraints = const BoxConstraints(maxHeight: 500, maxWidth: 750),
    this.maxWidthPercentage = 0.8,
    this.maxHeightPercentage = 0.8,
    this.padding = const EdgeInsets.all(16),
    super.key,
  });

  final Widget body;
  final Widget? header;
  final BoxConstraints constraints;
  final double maxWidthPercentage;
  final double maxHeightPercentage;
  final EdgeInsets padding;

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
                color: context.colour.modalBackground,
                border: Border.all(color: context.colour.border),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            builder:
                (context, style) => Padding(
                  padding: EdgeInsets.all(1),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (header != null) header!,
                        Container(padding: padding, child: body),
                      ],
                    ),
                  ),
                ),
          ),
    );
  }
}
