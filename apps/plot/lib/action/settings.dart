import 'package:flutter/widgets.dart' hide Action, Actions;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart' hide Action, Actions;
import 'package:supabase_flutter/supabase_flutter.dart' as supa;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/analytics/analytics.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/router.dart';
import 'package:plot/state/theme.dart';
import 'action.dart';
import 'logging.dart';

final appearanceActions = StaticActionGroup(
  title: 'Appearance',
  actions: [
    ChangeTheme(AppThemeMode.system),
    ChangeTheme(AppThemeMode.light),
    ChangeTheme(AppThemeMode.dark),
  ],
);

final settingsActions = StaticActionGroup(
  title: 'Settings',
  actions: [ChangeAppearance()],
);

final accountActions = StaticActionGroup(
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

class ChangeAppearance extends ShowActions {
  ChangeAppearance()
    : super(
        title: 'Change Light/Dark Mode',
        icon: FontAwesomeIcons.sun,
        actions: (context) =>
            Future.value(Actions(groups: [appearanceActions])),
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

class ChangeTheme extends Action {
  ChangeTheme(this.themeMode)
    : super(
        title: _getTitle(themeMode),
        subtitle: _getSubtitle(themeMode),
        eventObject: EventObject.settings,
        eventAction: EventAction.updated,
        icon: _getIcon(themeMode),
      );

  final AppThemeMode themeMode;

  static String _getTitle(AppThemeMode mode) {
    return switch (mode) {
      AppThemeMode.system => 'System',
      AppThemeMode.light => 'Light',
      AppThemeMode.dark => 'Dark',
    };
  }

  static String _getSubtitle(AppThemeMode mode) {
    return switch (mode) {
      AppThemeMode.system => 'Follow system theme',
      AppThemeMode.light => 'Always use light theme',
      AppThemeMode.dark => 'Always use dark theme',
    };
  }

  static IconData _getIcon(AppThemeMode mode) {
    return switch (mode) {
      AppThemeMode.system => FontAwesomeIcons.circleHalfStroke,
      AppThemeMode.light => FontAwesomeIcons.sun,
      AppThemeMode.dark => FontAwesomeIcons.moon,
    };
  }

  @override
  Future<ActionReturn> run(BuildContext context) async {
    try {
      context.read<ThemeBloc>().setThemeMode(themeMode);
      return const ActionDone();
    } catch (e, t) {
      log.warning("Change theme failed", e, t);
      return ActionMessage('Failed to change theme', isError: true);
    }
  }
}
