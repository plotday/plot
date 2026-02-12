import 'package:flutter/widgets.dart';

import 'package:forui/forui.dart';

/// Overlays a small count at the bottom-right of [child] when [count] > 1.
class CountBadge extends StatelessWidget {
  const CountBadge({required this.count, required this.child, super.key});

  final int count;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (count <= 1) return child;

    final style = context.theme.typography.xs.copyWith(
      color: context.theme.colors.mutedForeground,
      fontSize: 10,
      height: 1,
    );

    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          right: -2,
          bottom: 0,
          child: Text('$count', style: style),
        ),
      ],
    );
  }
}
