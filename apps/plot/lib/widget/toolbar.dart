import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos;
import 'package:platform_builder/platform_builder.dart';

class Toolbar extends StatelessWidget {
  const Toolbar({super.key});

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      builder: (_) => const macos.ToolBar(
        title: Text('Priority'),
        actions: [
          macos.ToolBarIconButton(
            icon: material.Icon(material.Icons.calendar_today),
            label: 'Schedule',
            showLabel: false,
          ),
        ],
      ),
    );
  }
}
