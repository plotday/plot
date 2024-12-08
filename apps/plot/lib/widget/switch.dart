import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos;

import 'package:platform_builder/platform_builder.dart';

class Switch extends StatelessWidget {
  const Switch({
    required this.child,
    required this.onChanged,
    required this.value,
    super.key,
  });

  final ValueChanged<bool> onChanged;
  final Widget child;
  final bool value;

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => Row(
        children: <Widget>[
          Expanded(child: child),
          macos.MacosSwitch(
            value: value,
            onChanged: onChanged,
          ),
        ],
      ),
      builder: (_) => material.InkWell(
        onTap: () {
          onChanged(!value);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20.0),
          child: Row(
            children: <Widget>[
              Expanded(child: child),
              material.Switch(
                value: value,
                onChanged: (bool newValue) {
                  onChanged(newValue);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
