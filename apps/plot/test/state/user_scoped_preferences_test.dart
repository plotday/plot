import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/state/last_open_focus.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/user_scoped_preferences.dart';
import 'package:plot/util/profile_preferences.dart';

void main() {
  group('clearUserScopedPreferences', () {
    test('removes every user-scoped key but keeps device-global ones',
        () async {
      SharedPreferences.setMockInitialValues({
        // User-scoped (must be cleared on sign-out).
        kLastOpenFocusKey: 'a-focus-id',
        LocalPreferencesBloc.kMentionMruKey: 'c1,c2',
        LocalPreferencesBloc.kShowAllPrioritiesKey: true,
        LocalPreferencesBloc.kConnectionMruKey: '{}',
        LocalPreferencesBloc.kReactionMruKey: '[]',
        LocalPreferencesBloc.kLinkMruKey: '{}',
        // Device/profile-global (must survive sign-out).
        'theme_mode': 'dark',
        'panel_width_left': 320.0,
        'clerk_user_id': 'old-user',
      });
      await ProfilePreferences.init();

      await clearUserScopedPreferences();

      final prefs = ProfilePreferences.instance;
      expect(prefs.containsKey(kLastOpenFocusKey), isFalse);
      expect(prefs.containsKey(LocalPreferencesBloc.kMentionMruKey), isFalse);
      expect(
        prefs.containsKey(LocalPreferencesBloc.kShowAllPrioritiesKey),
        isFalse,
      );
      expect(prefs.containsKey(LocalPreferencesBloc.kConnectionMruKey), isFalse);
      expect(prefs.containsKey(LocalPreferencesBloc.kReactionMruKey), isFalse);
      expect(prefs.containsKey(LocalPreferencesBloc.kLinkMruKey), isFalse);

      // Device-global preferences are untouched.
      expect(prefs.getString('theme_mode'), 'dark');
      expect(prefs.getDouble('panel_width_left'), 320.0);
      expect(prefs.getString('clerk_user_id'), 'old-user');
    });

    test('removes prefix-keyed user-scoped entries (per-role / per-priority)',
        () async {
      SharedPreferences.setMockInitialValues({
        '${kLastOpenFocusRolePrefix}role-1': 'focus-1',
        '${kLastOpenFocusRolePrefix}role-2': 'focus-2',
        '${LocalPreferencesBloc.kSubTypeMruPrefix}priority-1': 'task,note',
        '${LocalPreferencesBloc.kSubTypeMruPrefix}priority-2': 'note,task',
        'theme_mode': 'light',
      });
      await ProfilePreferences.init();

      await clearUserScopedPreferences();

      final prefs = ProfilePreferences.instance;
      expect(prefs.containsKey('${kLastOpenFocusRolePrefix}role-1'), isFalse);
      expect(prefs.containsKey('${kLastOpenFocusRolePrefix}role-2'), isFalse);
      expect(
        prefs.containsKey('${LocalPreferencesBloc.kSubTypeMruPrefix}priority-1'),
        isFalse,
      );
      expect(
        prefs.containsKey('${LocalPreferencesBloc.kSubTypeMruPrefix}priority-2'),
        isFalse,
      );
      expect(prefs.getString('theme_mode'), 'light');
    });
  });

  group('LocalPreferencesBloc.reset', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ProfilePreferences.init();
    });

    test('drops in-memory user-scoped state so the next user starts clean',
        () async {
      final bloc = LocalPreferencesBloc();
      await bloc.recordMentionUsage('contact-from-user-a');
      await bloc.recordConnectionUsage(channelKey: 'gmail:a@x.com');
      await bloc.recordLinkUsage('gmail:a@x.com');
      await bloc.toggleShowAllPriorities();

      // Sanity: state carries the previous user's data.
      expect(bloc.state.mentionMruIds, isNotEmpty);
      expect(bloc.state.connectionMru, isNotEmpty);
      expect(bloc.state.linkMru, isNotEmpty);
      expect(bloc.state.showAllPriorities, isTrue);

      bloc.reset();

      expect(bloc.state.mentionMruIds, isEmpty);
      expect(bloc.state.connectionMru, isEmpty);
      expect(bloc.state.linkMru, isEmpty);
      expect(bloc.state.reactionMru, isEmpty);
      expect(bloc.state.showAllPriorities, isFalse);

      await bloc.close();
    });
  });
}
