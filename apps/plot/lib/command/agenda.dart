import 'package:flutter/widgets.dart';

import 'command.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/router.dart';

class OpenAgenda extends Command {
  OpenAgenda()
    : super(
        title: 'Agenda',
        eventObject: EventObject.navigation,
        eventAction: EventAction.opened,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    return const CommandRoute(AgendaRoute());
  }
}
