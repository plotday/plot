import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'editor.dart';

class NoteWidget extends StatelessWidget {
  const NoteWidget({
    required this.note,
    super.key,
  });

  final Note note;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Viewer(
        markdown: note.body,
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(note.createdAt.toTimeAgo()),
          ],
        ),
      ),
    ]);
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
