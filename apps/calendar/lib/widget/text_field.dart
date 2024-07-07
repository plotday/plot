import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart';

import 'package:platform_builder/platform_builder.dart';

class TextField extends StatelessWidget {
  const TextField({
    required this.label,
    required this.onChanged,
    this.onSubmitted,
    this.controller,
    super.key,
  });

  final ValueChanged<String> onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextEditingController? controller;
  final String label;

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => MacosTextField(
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        controller: controller,
        placeholder: label,
      ),
      builder: (_) => material.TextField(
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        controller: controller,
        decoration: material.InputDecoration(
          labelText: label,
        ),
      ),
    );
  }
}
