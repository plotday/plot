import 'package:flutter/services.dart';
import 'package:plot/analytics/tracker.dart';
import 'base.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart' hide Link;
import 'package:plot/store/store.dart';

class AddLink extends Command {
  AddLink({
    required this.currentActions,
    required this.onActionsChanged,
  }) : super(
         title: 'Add link',
         eventObject: EventObject.note,
         eventAction: EventAction.added,
         icon: PlotIcon.link,
         shortcut: platformSingleActivator(
           LogicalKeyboardKey.keyL,
           shift: true,
         ),
       );

  final List<UserAction> currentActions;
  final void Function(List<UserAction> actions) onActionsChanged;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final result = await LinkModal.open(context);
    if (result == null) return const CommandSkipped();

    if (result.isThread) {
      // Attach a reference to the existing Plot thread instead of navigating
      // to it. Deduped by threadId so re-picking the same thread is a no-op.
      final thread = result.existingThread!;
      onActionsChanged(
        appendThreadReference(
          currentActions,
          threadId: thread.id.toString(),
          title: thread.title,
          priorityId: thread.priority.id.toString(),
        ),
      );
      return const CommandDone();
    }

    if (result.isLink) {
      final linkAction = ExternalUserAction(
        title: result.title ?? result.url!,
        url: result.url!,
        favicon: result.favicon,
      );
      onActionsChanged([...currentActions, linkAction]);
    }

    return const CommandDone();
  }
}

/// Returns a new actions list with a [ThreadUserAction] for [threadId]
/// appended. If a thread reference for [threadId] is already present, the
/// list is returned unchanged (no duplicate, existing reference preserved).
/// Does not mutate [current].
List<UserAction> appendThreadReference(
  List<UserAction> current, {
  required String threadId,
  String? title,
  String? priorityId,
}) {
  final alreadyAttached = current.any(
    (a) => a is ThreadUserAction && a.threadId == threadId,
  );
  if (alreadyAttached) return current;
  return [
    ...current,
    ThreadUserAction(threadId: threadId, title: title, priorityId: priorityId),
  ];
}
