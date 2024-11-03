import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/router.dart';

class NoteWidget extends StatelessWidget {
  const NoteWidget({
    required this.note,
    super.key,
  });

  final Note note;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: () => TopicRoute.byId(note.activityId, note.topicId).go(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          children: [
            Expanded(
              child: Text(note.body),
            ),
          ],
        ),
      ),
    );
  }
}
