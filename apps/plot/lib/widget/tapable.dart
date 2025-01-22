import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;

import 'package:platform_builder/platform_builder.dart';

class Tapable extends StatefulWidget {
  const Tapable({required this.child, required this.onTap, super.key});

  final VoidCallback? onTap;
  final Widget child;

  @override
  State<Tapable> createState() => _TapableState();
}

class _TapableState extends State<Tapable> {
  bool _isDragging = false;

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      androidBuilder: (_) => material.InkWell(
        onTap: widget.onTap,
        child: widget.child,
      ),
      builder: (_) => GestureDetector(
        onTap: _isDragging ? null : widget.onTap,
        onPanStart: (_) => _isDragging = true,
        onPanEnd: (_) => _isDragging = false,
        onPanCancel: () => _isDragging = false,
        child: widget.child,
      ),
    );
  }
}
