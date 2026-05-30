import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';

class PrioritySelector extends StatelessWidget {
  const PrioritySelector({
    required this.selected,
    this.onSelect,
    this.leafTrailingIcon,
    this.onLeafTap,
    super.key,
  });

  final Priority? selected;
  final void Function(Priority)? onSelect;

  /// Optional caret rendered after the focus label — a separate tap target
  /// (see [onLeafTap]) so the selector can host a scope toggle or other
  /// affordance without an extra button.
  final IconData? leafTrailingIcon;

  /// Tap callback for the [leafTrailingIcon] hit area.
  final VoidCallback? onLeafTap;

  @override
  Widget build(BuildContext context) {
    final priority = selected;
    // Focuses are flat — tapping the label selects this focus.
    final label = FocusLabel(
      priority: priority,
      boldLeaf: true,
      onLeafTap: (priority != null && onSelect != null)
          ? () => onSelect!(priority)
          : null,
    );

    final caret = leafTrailingIcon;
    if (caret == null) return label;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(child: label),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onLeafTap,
          child: Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Icon(caret, size: 10),
          ),
        ),
      ],
    );
  }
}
