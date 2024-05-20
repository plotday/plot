import 'package:flutter/material.dart';

import 'style.dart';

class Spinner extends StatelessWidget {
  const Spinner({super.key});

  @override
  Widget build(BuildContext context) {
    switch (style) {
      default:
        return const CircularProgressIndicator();
    }
  }
}
