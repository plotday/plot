import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart';

/// Horizontal padding of compose-row content (the leading and trailing
/// gutters). Chosen so the row's content starts at the same x as the
/// NoteEditor's text (12 outer + 6 inner editor padding).
const double composeIconLeft = 18;

/// Horizontal gap between a row's leading icon column and its text label.
/// Shared by every compose row so the labels start at the same x.
const double composeIconGap = 10;

/// Extra width added to the leading-icon column beyond the ambient icon
/// size, split evenly on both sides by [ComposeLeadingIcon]'s centering.
/// Glyph icons render at the cap-height `iconSizes.leading` size and gain
/// breathing room, while the contacts field's avatar (which fills its full
/// circle) renders at the full column width — visibly larger than a bare
/// glyph — without any row's label falling out of alignment.
const double composeLeadingPadding = 8;

/// Resolved width of the leading-icon column: the ambient `iconSizes.base`
/// plus [composeLeadingPadding]. Shared by [ComposeLeadingIcon] and the
/// contacts field's avatar so a single avatar fills the column and its
/// label lands in the same column as every other compose row.
double composeLeadingWidth(BuildContext context) =>
    context.theme.iconSizes.base + composeLeadingPadding;

/// Wraps a leading icon (sparkles, logo, avatars, etc.) in a fixed-width
/// slot so icons of differing intrinsic widths center within the same
/// column. Keeps the text label that follows pinned to the same x across
/// every compose row. Width is [composeLeadingWidth] so it tracks the
/// typography scale (desktop = 15px font / 16px icon) plus shared padding.
class ComposeLeadingIcon extends StatelessWidget {
  const ComposeLeadingIcon({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      LeadingIcon(slotWidth: composeLeadingWidth(context), child: child);
}

/// Shared chrome for compose-surface rows. Renders the row's [child]
/// inside consistent horizontal gutters, wraps the whole row in an
/// [FTooltip] that shows [tooltip] + optional [shortcut] on hover, and
/// invokes [onTapField] when the row is tapped anywhere.
class ComposeFieldRow extends StatelessWidget {
  const ComposeFieldRow({
    super.key,
    required this.tooltip,
    required this.child,
    this.shortcut,
    this.onTapField,
  });

  final String tooltip;
  final Widget child;
  final ShortcutActivator? shortcut;
  final VoidCallback? onTapField;

  @override
  Widget build(BuildContext context) {
    final row = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTapField,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: isMobilePlatform() ? 44 : 36,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(width: composeIconLeft),
            Expanded(child: child),
            const SizedBox(width: composeIconLeft),
          ],
        ),
      ),
    );

    if (!hasPhysicalKeyboard()) return row;
    return FTooltip(
      tipBuilder: (context, controller) => _buildTooltip(context),
      child: row,
    );
  }

  Widget _buildTooltip(BuildContext context) {
    final shortcutText = formatShortcut(shortcut);
    if (shortcutText.isEmpty) return Text(tooltip);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tooltip),
        Text(
          shortcutText,
          style: context.theme.typography.xs.copyWith(
            color: context.theme.colors.mutedForeground,
          ),
        ),
      ],
    );
  }
}
