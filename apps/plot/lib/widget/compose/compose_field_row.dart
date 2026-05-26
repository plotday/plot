import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart';

/// Horizontal offset of the leading icon's left edge inside a compose row,
/// chosen to align with where note-editor text starts (12 outer + 6 inner
/// editor padding). Exposed so the [NewThreadPage] compose surface and any
/// future compose-style rows stay consistent.
const double composeIconLeft = 18;

/// Shared row chrome for compose fields. Renders a leading icon with a
/// tooltip (label + optional shortcut hint) and a content slot. Tapping
/// anywhere in the row invokes [onTapField] so the field can request focus.
/// Rows have no dividers, borders, or radius between them — the compose
/// surface owns a single divider below the field stack.
class ComposeFieldRow extends StatelessWidget {
  const ComposeFieldRow({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.child,
    this.shortcut,
    this.onTapField,
  });

  final IconData icon;
  final String tooltip;
  final Widget child;
  final ShortcutActivator? shortcut;
  final VoidCallback? onTapField;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final iconColor = theme.plotColors.muted;
    final iconSize = theme.iconSizes.sm;

    final Widget leadingIcon = SizedBox(
      width: iconSize,
      child: FaIcon(icon, size: iconSize, color: iconColor),
    );

    final Widget leading = hasPhysicalKeyboard()
        ? FTooltip(
            tipBuilder: (context, controller) => _buildTooltip(context),
            child: leadingIcon,
          )
        : leadingIcon;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTapField,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: isMobilePlatform() ? 44 : 36,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Icon's left edge sits at [composeIconLeft] so it aligns with
            // the note editor's text start.
            const SizedBox(width: composeIconLeft),
            leading,
            const SizedBox(width: 10),
            Expanded(child: child),
            const SizedBox(width: 12),
          ],
        ),
      ),
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
