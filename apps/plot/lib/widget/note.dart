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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(note.body),
          ),
        ],
      ),
    );
  }
}
