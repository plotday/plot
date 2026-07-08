import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/layout.dart' show listRowGutter, listRowIconGap;
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

/// Roomy (single-panel mobile) variant of [sidebarLeading]. The glyph sits in a
/// [listRowGutter]-wide gutter — the same one the NewThreadPage compose rows use
/// — with a [listRowIconGap] gap to the label and a small [PlotSpacing.sm] left
/// inset, so a focus row's leading rhythm matches a compose pill's exactly (icon
/// size, gutter, and where the label starts). Callers build the glyph at
/// [listRowIconSize]. Pairs with the 36px roomy row height so the [listRowGutter]
/// gutter centres with 6px above and below.
Widget roomyLeading(BuildContext context, Widget icon) => Padding(
  padding: EdgeInsets.only(left: context.theme.spacing.sm),
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: listRowGutter,
        height: listRowGutter,
        child: Center(child: icon),
      ),
      SizedBox(width: listRowIconGap),
    ],
  ),
);
