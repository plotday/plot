import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'editor.dart';
import 'colour_scheme.dart';

class NoteWidget extends StatelessWidget {
  const NoteWidget({required this.note, super.key});

  final Note note;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Viewer(markdown: note.body),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                note.createdAt.toTimeAgo(),
                style: TextStyle(color: context.colour.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class NotesView extends StatelessWidget {
  final List<Note> notes;
  final bool shrinkWrap;
  final bool reverse;

  const NotesView({
    required this.notes,
    this.shrinkWrap = false,
    this.reverse = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      reverse: reverse,
      shrinkWrap: shrinkWrap,
      itemCount: notes.length,
      itemBuilder: (context, index) {
        final note = notes[index];
        return NoteWidget(key: ValueKey(note.id), note: note);
      },
    );
  }
}
