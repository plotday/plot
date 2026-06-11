import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/spacing.dart';

/// Leading-icon slot shared by the sidebar tiles (focus items, connection and
/// account tiles).
///
/// The icon sits in an `iconSizes.base` square with a [PlotSpacing.md] inset on
/// either side — md from the panel's content edge and md to the label. The
/// symmetric box keeps the running-command spinner (centred over the leading
/// slot by `ListTile`) landing on the icon.
Widget sidebarLeading(BuildContext context, Widget icon) {
  final size = context.theme.iconSizes.base;
  return Padding(
    padding: EdgeInsets.only(
      left: context.theme.spacing.lg,
      right: context.theme.spacing.md,
    ),
    child: SizedBox.square(
      dimension: size,
      child: Center(child: icon),
    ),
  );
}
