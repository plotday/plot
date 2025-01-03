import 'package:flutter/widgets.dart';
import 'package:widgetbook_annotation/widgetbook_annotation.dart' as widgetbook;

import 'package:plot/store/store.dart';
import 'package:plot/widget/topic.dart';

@widgetbook.UseCase(name: 'Plain', type: TopicWidget)
Widget buildTopic(BuildContext context) {
  return TopicWidget(
    note: Note.draft(activityId: null).copyWith(body: "I'm a note."),
    onChange: (topic) {},
  );
}

@widgetbook.UseCase(name: 'Do now', type: TopicWidget)
Widget buildTopicDoNow(BuildContext context) {
  return TopicWidget(
    note: Note.draft(activityId: null).copyWith(
      body: "I'm a note.",
      doAt: Value(DateTime.now()),
    ),
    onChange: (topic) {},
  );
}
