import 'package:flutter/widgets.dart';

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
      Row(children: [
        Text(note.createdAt.toString()),
      ]),
      Viewer(
        markdown: note.body,
      ),
    ];
    if (reverse) {
      children = children.reversed.toList();
    }
    return Column(children: children);
  }
}

class NotesView extends StatelessWidget {
  final List<Note> notes;

  const NotesView({super.key, required this.notes});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      reverse: true,
      itemCount: notes.length,
      itemBuilder: (context, index) {
        final note = notes[notes.length - index - 1];
        return NoteWidget(
          key: ValueKey(note.id),
          note: note,
        );
      },
    );
  }
}
