import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/value.dart';
import 'package:plot/widget/widget.dart';

/// Action a user picked from a chip menu in the compose contacts field.
enum ComposeChipAction { remove, addAsCc, addAsBcc }

/// Open the chip-action menu for [chipLabel]. Renders as a dialog on
/// multi-panel desktop and a bottom sheet on touch (Modal handles this).
/// Returns the chosen action, or null if dismissed.
///
/// `addAsCc` / `addAsBcc` are present in the menu but disabled until the
/// CC/BCC feature ships.
Future<ComposeChipAction?> showComposeChipMenu(
  BuildContext context, {
  required String chipLabel,
}) async {
  final result = await Modal(
    header: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Text(
        chipLabel,
        style: context.theme.typography.sm,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    constraints: const BoxConstraints(maxWidth: 320, maxHeight: 240),
    padding: const EdgeInsets.symmetric(vertical: 4),
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MenuItem(
          icon: PlotIcon.close,
          label: 'Remove',
          onTap: () => Modal.pop<ComposeChipAction>(
            context,
            const Value(ComposeChipAction.remove),
          ),
        ),
        _MenuItem(
          icon: PlotIcon.user,
          label: 'Add as CC',
          enabled: false,
          onTap: () {},
        ),
        _MenuItem(
          icon: PlotIcon.user,
          label: 'Add as BCC',
          enabled: false,
          onTap: () {},
        ),
      ],
    ),
  ).show<ComposeChipAction>(context);
  return result.present ? result.value : null;
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final color = enabled
        ? theme.colors.foreground
        : theme.plotColors.veryMuted;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 12,
          vertical: isMobilePlatform() ? 14 : 10,
        ),
        child: Row(
          children: [
            Icon(icon, size: theme.iconSizes.sm, color: color),
            const SizedBox(width: 10),
            Text(label, style: TextStyle(color: color)),
          ],
        ),
      ),
    );
  }
}
