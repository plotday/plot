import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart';

/// Shared row chrome for compose fields. Renders a leading icon with a
/// tooltip (label + optional shortcut hint) and a content slot. Tapping
/// anywhere in the row invokes [onTapField] so the field can request focus.
/// Rows have no dividers between them — the compose surface owns a single
/// divider below the field stack.
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

    final Widget leadingIcon = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
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
          minHeight: isMobilePlatform() ? 48 : 40,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            leading,
            Expanded(child: child),
            const SizedBox(width: 8),
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
