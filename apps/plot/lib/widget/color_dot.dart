import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/state/theme.dart';
import 'package:plot/util/theme_color.dart';

/// A small filled circle in a [ThemeColor], used **only** for colour
/// *selection* — i.e. when the colour itself is the value being picked or
/// previewed (the "Color" field in the focus/role forms, swatches in a colour
/// picker).
///
/// **Never use a [ColorDot] as a leading marker for a non-colour item** such as
/// a role, focus, priority, or contact. There the colour is the item's
/// *identity*, not a value being chosen, so it belongs on the label text
/// itself. For a role use [RoleLabel] (the name rendered in the role's colour);
/// for a focus use `FocusLabel`. A `ColorDot` + role name is the anti-pattern
/// this rule exists to prevent.
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
              lightness: dark ? 0.5 : 0.65,
            ),
            border: Border.all(
              color: context.colour.colours.fromTheme(
                color,
                lightness: dark ? 0.5 : 0.50,
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
