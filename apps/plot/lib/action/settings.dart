import 'package:flutter/widgets.dart' hide Action, Actions;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart' hide Action, Actions;
import 'package:supabase_flutter/supabase_flutter.dart' as supa;

import 'package:plot/analytics/analytics.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/router.dart';
import 'action.dart';
import 'logging.dart';

final settingsActions = StaticActionGroup(
  title: 'Account',
  actions: [SignOut()],
);

class ShowSettings extends ShowActions {
  ShowSettings()
    : super(
        title: 'Settings',
        icon: PlotIcon.settings,
        actions: (context) => Future.value(
          Actions(groups: [settingsActions], prompt: 'Settings'),
        ),
        shortcut: const SingleActivator(LogicalKeyboardKey.period, meta: true),
      );
}

class SignOut extends Action {
  SignOut()
    : super(
        title: 'Sign Out',
        eventObject: EventObject.settings,
        eventAction: EventAction.clicked,
        icon: PlotIcon.signOut,
      );

  @override
  Future<ActionReturn> run(BuildContext context) async {
    try {
      return ActionRoute(SignInRoute(signOut: true));
    } on supa.AuthException catch (e, t) {
      log.warning("Sign out failed", e, t);
      return ActionMessage('Sign out failed: ${e.message}', isError: true);
    }
  }
}
