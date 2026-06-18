import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';

/// Displays a role's name rendered in the role's own colour.
///
/// This is the canonical way to surface a role in a list row, picker, chip, or
/// label. A role's colour is part of its *identity*, not a value being chosen,
/// so it is carried by the label text itself.
///
/// **Do not pair a [ColorDot] with a role name.** [ColorDot] is reserved for
/// colour *selection* UIs (picking a colour value); using it as a leading dot
/// beside a role label is wrong — render the label in colour with [RoleLabel]
/// instead. See [ColorDot]'s doc comment for the full rule.
///
/// The text inherits the ambient [DefaultTextStyle] (or [style] when provided)
/// and overrides only the colour, so it matches whatever surface it sits on
/// (modal list, form-field chip, etc.).
class RoleLabel extends StatelessWidget {
  const RoleLabel({required this.role, this.style, super.key});

  /// The role whose name and colour are displayed.
  final Role role;

  /// Base text style to merge the role colour into. Defaults to the ambient
  /// [DefaultTextStyle]. The colour is always taken from the role.
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final color = context.colour.colours.fromTheme(role.displayColor);
    final base = style ?? DefaultTextStyle.of(context).style;
    return Text(
      role.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: base.copyWith(color: color),
    );
  }
}
