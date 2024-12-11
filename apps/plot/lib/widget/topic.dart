import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:posthog_flutter/posthog_flutter.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';

class TopicWidget extends StatelessWidget {
  const TopicWidget({
    required this.note,
    required this.onChange,
    this.onTap,
    this.selected = false,
    super.key,
  });

  final Note note;
  final VoidCallback? onTap;
  final void Function(Note) onChange;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      selected: selected,
      leading: switch (note) {
        _ when note.doNow => IconButton(
            padding: EdgeInsets.zero,
            onPressed: () {
              onChange(note.copyWith(doneAt: Value(DateTime.now())));
              Posthog().capture(
                eventName: 'Topic Started',
              );
            },
            icon: const PlotIcon.todo(
              color: material.Colors.grey,
            ),
          ),
        _ when note.done => IconButton(
            padding: EdgeInsets.zero,
            onPressed: () {
              onChange(note.copyWith(doAt: Value(DateTime.now())));
              Posthog().capture(
                eventName: 'Topic Completed',
              );
            },
            icon: const PlotIcon.done(
              color: material.Colors.grey,
            ),
          ),
        _ when note.scheduled => IconButton(
            padding: EdgeInsets.zero,
            onPressed: () {
              Posthog().capture(
                eventName: 'Topic Scheduled',
              );
            },
            icon: const PlotIcon.scheduled(
              color: material.Colors.grey,
            ),
          ),
        _ when note.pinned => IconButton(
            padding: EdgeInsets.zero,
            onPressed: () {
              onChange(note.copyWith(pinned: false));
              Posthog().capture(
                eventName: 'Topic Un-pinned',
              );
            },
            icon: const PlotIcon.pinned(
              color: material.Colors.grey,
            ),
          ),
        _ => null,
      },
      leadingSize: const Size(18, 18),
      title: Text(note.body),
    );
  }
}
