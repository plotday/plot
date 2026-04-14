part of 'store.dart';

enum ThreadSubType {
  action('action', PlotIcon.action, 'Action'),
  notes('notes', PlotIcon.notes, 'Notes'),
  idea('idea', PlotIcon.idea, 'Idea'),
  goal('goal', PlotIcon.goal, 'Goal'),
  decision('decision', PlotIcon.decision, 'Decision'),
  discussion('discussion', PlotIcon.messages, 'Discussion'),
  announcement('announcement', PlotIcon.bullhorn, 'Announcement'),
  ask('ask', PlotIcon.question, 'Ask');

  final String value;
  final IconData icon;
  final String label;

  const ThreadSubType(this.value, this.icon, this.label);

  static ThreadSubType? fromIcon(String? icon) =>
      ThreadSubType.values.firstWhereOrNull((t) => t.value == icon);

  static ThreadSubType defaultFor() => ThreadSubType.notes;
}
