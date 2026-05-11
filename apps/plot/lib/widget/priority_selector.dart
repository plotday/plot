import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';

class PrioritySelector extends StatelessWidget {
  const PrioritySelector({required this.selected, this.onSelect, super.key});

  final Priority? selected;
  final void Function(Priority)? onSelect;

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
    );
  }
}
