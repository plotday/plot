import 'package:flutter/material.dart';

import 'style.dart';

class Tapable extends StatelessWidget {
  const Tapable({required this.child, required this.onTap, super.key});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    switch (style) {
      case Style.material:
        return InkWell(onTap: onTap, child: child);
      default:
        return GestureDetector(onTap: onTap, child: child);
    }
  }
}
