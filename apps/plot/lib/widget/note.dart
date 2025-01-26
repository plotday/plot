import 'package:flutter/widgets.dart';
import 'package:sliver_tools/sliver_tools.dart';

import 'package:plot/store/store.dart';
import 'editor.dart';

class NoteWidget extends StatelessWidget {
  const NoteWidget({
    required this.note,
    this.reverse = false,
    super.key,
  });

  final Note note;
  final bool reverse;

  @override
  Widget build(BuildContext context) {
    var children = [
      SliverToBoxAdapter(
        child: Row(children: [
          Text(note.createdAt.toString()),
        ]),
      ),
      Viewer(
        markdown: note.body,
      ),
    ];
    if (reverse) {
      children = children.reversed.toList();
    }
    return MultiSliver(children: children);
  }
}

class NotesView extends StatelessWidget {
  final List<Note> notes;

  const NotesView({super.key, required this.notes});

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      reverse: true,
      slivers: notes.reversed
          .map((note) => NoteWidget(
                key: ValueKey(note.id),
                note: note,
                reverse: true,
              ))
          .toList(),
    );
  }
}
