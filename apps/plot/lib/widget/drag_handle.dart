import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/widget/widget.dart';

/// Trailing grip-icon target shown on touch devices so a drag gesture
/// can be distinguished from a scroll. The widget is purely visual —
/// callers wrap it in the appropriate drag-source widget
/// (`ReorderableDragStartListener` for `ReorderableListView` lists,
/// `Draggable` for the agenda's custom block-drag system).
class DragHandle extends StatelessWidget {
  const DragHandle({this.padding, this.color, super.key});

  /// Override the touch-target padding around the icon. The default
  /// matches the inset used in [ReorderableListView] thread/priority
  /// rows so the handle reads consistently across surfaces.
  final EdgeInsets? padding;

  /// Override the icon color (defaults to the muted plot color).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0x00000000),
      padding:
          padding ?? const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Icon(
        FontAwesomeIcons.gripDotsVertical,
        size: context.theme.iconSizes.sm,
        color: color ?? context.theme.plotColors.muted,
      ),
    );
  }
}
