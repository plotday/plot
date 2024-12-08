import 'package:flutter/material.dart';

import 'package:platform_builder/platform_builder.dart';

class Spinner extends StatelessWidget {
  const Spinner({super.key});

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(builder: (_) => const CircularProgressIndicator());
  }
}
