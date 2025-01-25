import 'package:flutter/widgets.dart';
import 'package:sliver_tools/sliver_tools.dart';

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
    return MultiSliver(children: [
      SliverToBoxAdapter(
        child: Row(children: [
          Text(note.createdAt.toString()),
        ]),
      ),
      Viewer(
        markdown: note.body,
      ),
    ]);
  }
}

class NotesView extends StatelessWidget {
  final List<Note> notes;

  const NotesView({super.key, required this.notes});

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: notes.map((note) => NoteWidget(note: note)).toList(),
    );
  }
}
