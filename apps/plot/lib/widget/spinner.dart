import 'package:flutter/material.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:macos_ui/macos_ui.dart' as macos;

class Spinner extends StatelessWidget {
  const Spinner({this.message, super.key});
  const Spinner.message(String message, {super.key}) : message = message;

  final String? message;

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
        macOSBuilder: (_) => Row(
              spacing: 8,
              children: [
                if (message != null) Text(message!),
                const macos.ProgressCircle(),
              ],
            ),
        builder: (_) => message == null
            ? const CircularProgressIndicator()
            : Row(
                spacing: 8,
                children: [
                  Text(message!),
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                    ),
                  ),
                ],
              ));
  }
}
