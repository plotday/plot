import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/state/theme.dart';
import 'package:plot/util/theme_color.dart';

class ColorDot extends StatelessWidget {
  const ColorDot({required this.color, this.size = 12.0, super.key});

  final ThemeColor color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ThemeBloc, ThemeState>(
      builder: (context, themeState) {
        final dark = context.read<ThemeBloc>().isDarkMode(context);
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: context.colour.colours.fromTheme(
              color,
              lightness: dark ? 0.5 : 0.8,
            ),
            border: Border.all(
              color: context.colour.colours.fromTheme(
                color,
                lightness: dark ? 0.5 : 0.5,
              ),
              width: 1.0,
            ),
            shape: BoxShape.circle,
          ),
        );
      },
    );
  }
}
