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

  /// Optional caret rendered after the leaf priority — forwarded to the
  /// underlying [PriorityLabel] so the selector can host a scope toggle
  /// or other affordance without an extra button.
  final IconData? leafTrailingIcon;

  /// Tap callback for the combined leaf + [leafTrailingIcon] hit area.
  final VoidCallback? onLeafTap;

  void _onSelect(PriorityId id) async {
    if (onSelect == null) return;
    final priority = await Priority.getOne(id);
    onSelect!(priority);
  }

  @override
  Widget build(BuildContext context) {
    return PriorityLabel(
      priority: selected,
      onSelect: _onSelect,
      boldLeaf: true,
      leafTrailingIcon: leafTrailingIcon,
      onLeafTap: onLeafTap,
    );
  }
}
