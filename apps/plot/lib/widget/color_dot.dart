import 'package:flutter/widgets.dart';

class ColorDot extends StatelessWidget {
  const ColorDot({
    required this.color,
    this.size = 12.0,
    super.key,
  });

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}
