import 'package:flutter/services.dart';
import 'package:plot/analytics/tracker.dart';
import 'base.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart';

/// Placeholder command for the twist picker button.
/// The actual modal opening is handled by the `run` override in CommandWrapper.
class PickTwist extends Command {
  PickTwist()
      : super(
          title: 'Select twist',
          eventObject: EventObject.note,
          eventAction: EventAction.tagged,
          icon: PlotIcon.twist,
          shortcut: platformSingleActivator(
            LogicalKeyboardKey.keyM,
            shift: true,
          ),
        );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    return const CommandSkipped();
  }
}
