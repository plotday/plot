import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';

class NoteWidget extends StatelessWidget {
  const NoteWidget({
    required this.note,
    super.key,
  });

  final Note note;

  @override
  Widget build(BuildContext context) {
    return Text(note.body);
  }
}
