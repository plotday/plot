import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart';

import 'package:platform_builder/platform_builder.dart';

class TextField extends StatelessWidget {
  const TextField({required this.label, required this.onChanged, super.key});

  final ValueChanged<String> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => MacosTextField(
        onChanged: onChanged,
        placeholder: label,
      ),
      builder: (_) => material.TextField(
        onChanged: onChanged,
        decoration: material.InputDecoration(
          labelText: label,
        ),
      ),
    );
  }
}
