import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;

import 'package:platform_builder/platform_builder.dart';

class Tapable extends StatelessWidget {
  const Tapable({required this.child, required this.onTap, super.key});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      androidBuilder: (_) => material.InkWell(onTap: onTap, child: child),
      builder: (_) => GestureDetector(onTap: onTap, child: child),
    );
  }
}
