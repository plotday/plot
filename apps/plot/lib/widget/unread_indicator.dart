import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/state/theme.dart';
import 'package:plot/util/theme_color.dart';

class UnreadIndicator extends StatelessWidget {
  const UnreadIndicator({required this.color, required this.unread, super.key});

  final ThemeColor? color;
  final bool unread;

  @override
  Widget build(BuildContext context) {
    if (unread && color != null) {
      return BlocBuilder<ThemeBloc, ThemeState>(
        builder: (context, themeState) {
          final dark = context.read<ThemeBloc>().isDarkMode(context);
          return Container(
            width: 6.0,
            height: 6.0,
            decoration: BoxDecoration(
              color: context.colour.colours.fromTheme(
                color!,
                lightness: dark ? 0.7 : 0.7,
              ),
              shape: BoxShape.circle,
            ),
          );
        },
      );
    }
    return SizedBox.shrink();
  }
}
