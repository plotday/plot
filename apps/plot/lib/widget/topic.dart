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
        _ when note.done => const PlotIcon.done(size: 16),
        _ when note.pinned => const PlotIcon.pinned(size: 16),
        _ when note.doNow => const PlotIcon.scheduled(size: 16),
        _ => null,
      },
      leadingSize: const Size(16, 16),
      title: Text(note.body),
    );
  }
}
