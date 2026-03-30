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

  /// Whether this sub-type is only available in shared priorities
  bool get sharedOnly =>
      this == discussion || this == announcement || this == ask;

  static ThreadSubType? fromIcon(String? icon) =>
      ThreadSubType.values.firstWhereOrNull((t) => t.value == icon);

  static List<ThreadSubType> forPriority({required bool sharing}) => sharing
      ? [
          ...ThreadSubType.values.where((t) => t.sharedOnly),
          ...ThreadSubType.values.where((t) => !t.sharedOnly),
        ]
      : ThreadSubType.values.where((t) => !t.sharedOnly).toList();

  static ThreadSubType defaultFor({required bool sharing}) =>
      sharing ? ThreadSubType.discussion : ThreadSubType.notes;
}
