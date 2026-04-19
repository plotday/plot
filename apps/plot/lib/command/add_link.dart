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
    this.onNavigateToThread,
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
  final void Function(Thread thread)? onNavigateToThread;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final result = await LinkModal.open(context);
    if (result == null) return const CommandSkipped();

    if (result.isThread) {
      onNavigateToThread?.call(result.existingThread!);
      return const CommandDone();
    }

    if (result.isCreateAction) {
      // Only one create-link action per thread; replace any existing one.
      final filtered = currentActions
          .where((a) => a is! CreateLinkUserAction)
          .toList();
      onActionsChanged([result.createAction!, ...filtered]);
      return const CommandDone();
    }

    if (result.isLink) {
      final linkAction = ExternalUserAction(
        title: result.title ?? result.url!,
        url: result.url!,
      );
      onActionsChanged([...currentActions, linkAction]);
    }

    return const CommandDone();
  }
}
