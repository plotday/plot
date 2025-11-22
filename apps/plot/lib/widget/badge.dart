import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;

import 'package:plot/style/colors.dart';

class Badge extends StatelessWidget {
  const Badge({required this.count, super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    return material.Badge.count(
      count: count,
      backgroundColor: context.colour.accentBackground,
    );
  }
}
