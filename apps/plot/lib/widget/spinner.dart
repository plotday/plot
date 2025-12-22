import 'package:flutter/widgets.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:forui/forui.dart';

class Spinner extends StatelessWidget {
  const Spinner({this.message, this.size = 15, this.color, super.key});
  const Spinner.message(this.message, {this.size = 15, this.color, super.key});

  final String? message;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      builder: (_) => Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          if (message != null) Text(message!),
          SizedBox(
            width: size,
            height: size,
            child: FCircularProgress(
              style:
                  FCircularProgressStyle.inherit(
                    colors: context.theme.colors,
                    // ignore: unused_result
                  ).copyWith(
                    iconStyle: IconThemeData(
                      color: color ?? context.theme.colors.mutedForeground,
                      size: size,
                    ),
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
