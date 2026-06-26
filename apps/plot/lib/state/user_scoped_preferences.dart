import 'package:plot/state/last_open_focus.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/util/profile_preferences.dart';

/// Single source of truth for the device-local [ProfilePreferences] keys that
/// hold **user-specific** data and therefore MUST be cleared on sign-out.
///
/// Device-local preferences are scoped by *profile* (the `flutter.profile.*`
/// prefix set in `main.dart`), NOT by signed-in user. So when one account signs
/// out and another signs up on the same device, everything below would
/// otherwise leak into the new user's session — their focus links, their
/// contacts in the @-mention picker, their connections in the compose target
/// list, and so on.
///
/// Device/profile-global preferences (theme, panel sizes, the Clerk auth
/// session cache, env config) are intentionally NOT listed — they are tied to
/// the device, not the user, and must survive sign-out.
///
/// ⚠️ When you add a new device-local preference keyed to the signed-in user,
/// register its key here (or its prefix in [_userScopedPreferencePrefixes]).
/// `test/state/user_scoped_preferences_test.dart` guards this contract.
const List<String> _userScopedPreferenceKeys = [
  kLastOpenFocusKey,
  LocalPreferencesBloc.kMentionMruKey,
  LocalPreferencesBloc.kShowAllPrioritiesKey,
  LocalPreferencesBloc.kConnectionMruKey,
  LocalPreferencesBloc.kReactionMruKey,
  LocalPreferencesBloc.kLinkMruKey,
];

/// User-scoped keys whose full names carry a dynamic suffix (a role id or a
/// priority id), so they must be matched by prefix rather than listed exactly.
const List<String> _userScopedPreferencePrefixes = [
  kLastOpenFocusRolePrefix, // last_open_focus_role_<roleId>
  LocalPreferencesBloc.kSubTypeMruPrefix, // thread_subtype_mru:<priorityId>
];

/// Remove every user-scoped device-local preference so the next user to sign in
/// on this device starts clean. Call from the sign-out path; pair it with
/// `LocalPreferencesBloc.reset()` to also drop the in-memory copies.
Future<void> clearUserScopedPreferences() async {
  final prefs = ProfilePreferences.instance;
  for (final key in _userScopedPreferenceKeys) {
    await prefs.remove(key);
  }
  await prefs.removeWhere(
    (key) => _userScopedPreferencePrefixes.any(key.startsWith),
  );
}
