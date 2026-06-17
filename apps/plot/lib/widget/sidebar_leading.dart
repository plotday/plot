import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/spacing.dart';
import 'package:plot/widget/leading_icon.dart';

/// Leading-icon slot shared by the sidebar tiles (focus items, connection and
/// account tiles).
///
/// A thin [LeadingIcon] wrapper: the icon sits in an `iconSizes.base` square
/// with a [PlotSpacing.lg] inset on the left (from the panel's content edge)
/// and [PlotSpacing.md] on the right (to the label). The symmetric box keeps
/// the running-command spinner (centred over the leading slot by `ListTile`)
/// landing on the icon. Callers build their glyph at the cap-height leading
/// size (`iconSizes.leading`) so every sidebar row shares one icon rhythm.
Widget sidebarLeading(BuildContext context, Widget icon) => LeadingIcon(
  padding: EdgeInsets.only(
    left: context.theme.spacing.lg,
    right: context.theme.spacing.md,
  ),
  child: icon,
);
