import 'package:flutter/widgets.dart';
import 'package:widgetbook_annotation/widgetbook_annotation.dart' as widgetbook;

import 'package:plot/store/store.dart';
import 'package:plot/widget/activity.dart';

@widgetbook.UseCase(name: 'Plain', type: ActivityWidget)
Widget buildActivity(BuildContext context) {
  return ActivityWidget(
    note: Note.draft(priorityId: null).copyWith(body: "I'm a note."),
    onChange: (activity) {},
  );
}

@widgetbook.UseCase(name: 'Do now', type: ActivityWidget)
Widget buildActivityDoNow(BuildContext context) {
  return ActivityWidget(
    note: Note.draft(priorityId: null).copyWith(
      body: "I'm a note.",
      doAt: Value(DateTime.now()),
    ),
    onChange: (activity) {},
  );
}
