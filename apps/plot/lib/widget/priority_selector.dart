import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';

class PrioritySelector extends StatelessWidget {
  const PrioritySelector({
    required this.selected,
    this.onSelect,
    super.key,
  });

  final Priority? selected;
  final void Function(Priority)? onSelect;

  @override
  Widget build(BuildContext context) {
    final priority = selected;
    // Focuses are flat — tapping the label selects this focus.
    return FocusLabel(
      priority: priority,
      boldLeaf: true,
      onLeafTap: (priority != null && onSelect != null)
          ? () => onSelect!(priority)
          : null,
    );
  }
}
