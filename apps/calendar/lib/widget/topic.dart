import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';

class TopicWidget extends StatelessWidget {
  const TopicWidget({
    required this.note,
    this.onTap,
    this.selected = false,
    super.key,
  });

  final Note note;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      selected: selected,
      leading: switch (note) {
        _ when note.done => Icons.done,
        _ when note.pinned => Icons.pinned,
        _ when note.doNow => Icons.scheduled,
        _ => null,
      },
      title: Text(note.body),
    );
  }
}
