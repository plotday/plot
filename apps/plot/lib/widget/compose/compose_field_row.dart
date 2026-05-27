import 'package:plot/util/platform.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart';

/// Horizontal padding of compose-row content (the leading and trailing
/// gutters). Chosen so the row's content starts at the same x as the
/// NoteEditor's text (12 outer + 6 inner editor padding).
const double composeIconLeft = 18;

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
