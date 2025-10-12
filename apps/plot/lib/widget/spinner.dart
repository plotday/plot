import 'package:flutter/material.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:macos_ui/macos_ui.dart' as macos;

class Spinner extends StatelessWidget {
  const Spinner({this.message, this.size = 16, super.key});
  const Spinner.message(this.message, {this.size = 16, super.key});

  final String? message;
  final double size;

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          if (message != null) Text(message!),
          SizedBox(
            width: size,
            height: size,
            child: const macos.ProgressCircle(),
          ),
        ],
      ),
      builder: (_) => Row(
        spacing: 8,
        children: [
          if (message != null) Text(message!),
          SizedBox(
            width: size,
            height: size,
            child: const CircularProgressIndicator(strokeWidth: 2),
          ),
        ],
      ),
    );
  }
}
