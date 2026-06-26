import 'package:plot/store/store.dart';
import 'package:plot/util/profile_preferences.dart';

/// Device-local SharedPreferences key for the user's most recently
/// *deliberately chosen* focus. Read once at launch by [NowBloc] to seed the
/// "last open focus" rung of `NowLoaded.priority`; written by
/// `ChangeCurrentPriority`. Not synced — each device remembers its own.
const String kLastOpenFocusKey = 'last_open_focus';

/// Prefix for the device-local SharedPreferences keys that store the focus the
/// user most recently *deliberately chose* within a given role. The full key is
/// `<prefix><roleId>`. Exposed so sign-out can clear every per-role entry (they
/// hold user-specific focus ids); see `clearUserScopedPreferences`.
const String kLastOpenFocusRolePrefix = 'last_open_focus_role_';

/// Device-local SharedPreferences key for the focus the user most recently
/// *deliberately chose* within [roleId]. Written alongside [kLastOpenFocusKey]
/// by `ChangeCurrentPriority`; read when a role is opened on desktop so it
/// reopens that role's most-recent focus. Not synced.
String _roleKey(RoleId roleId) => '$kLastOpenFocusRolePrefix$roleId';

/// Persist [picked] as the device-local "last open focus".
///
/// No-op when [picked] is null: the only null caller is the synthetic
/// "Everything" feed (`ChangeCurrentPriority.everything`), which has no anchor
/// focus and must leave the previously stored real focus intact.
Future<void> recordLastOpenFocus(Priority? picked) async {
  if (picked == null) return;
  await ProfilePreferences.instance
      .setString(kLastOpenFocusKey, picked.id.toString());
}

/// Persist [picked] as the device-local "last open focus" for its role.
///
/// No-op when [picked] is null (the "Everything" feed) or [picked] has no
/// [Priority.roleId] (role-less / pre-role-model focuses have no per-role slot).
Future<void> recordLastOpenFocusForRole(Priority? picked) async {
  if (picked == null) return;
  final roleId = picked.roleId;
  if (roleId == null) return;
  await ProfilePreferences.instance
      .setString(_roleKey(roleId), picked.id.toString());
}

/// Parse a stored focus id, or null when [raw] is null or not a valid UUID.
PriorityId? _parseStoredFocusId(String? raw) {
  if (raw == null) return null;
  try {
    final id = Uuid.fromString(raw);
    // UuidValue.fromString() accepts any string without validation; validate()
    // makes malformed values throw and fall through to null.
    id.value.validate();
    return id;
  } catch (_) {
    return null;
  }
}

/// Read the device-local "last open focus" id, or null when unset, the stored
/// value can't be parsed (corrupt pref), or prefs aren't initialized yet.
PriorityId? loadLastOpenFocusId() {
  try {
    return _parseStoredFocusId(
        ProfilePreferences.instance.getString(kLastOpenFocusKey));
  } catch (_) {
    // ProfilePreferences not initialized (some non-production paths).
    return null;
  }
}

/// Read the device-local "last open focus" id for [roleId], or null when unset,
/// unparseable, or prefs aren't initialized.
PriorityId? loadLastOpenFocusIdForRole(RoleId roleId) {
  try {
    return _parseStoredFocusId(
        ProfilePreferences.instance.getString(_roleKey(roleId)));
  } catch (_) {
    return null;
  }
}

/// The focus to open when [roleFocuses] — a role's current, ordered,
/// non-archived focuses (must be non-empty) — is opened: the remembered
/// [rememberedId] if it's still present in the list, else the first. A null,
/// absent, or since-removed (archived/moved) id falls through to the first.
Priority pickRoleOpenFocus(List<Priority> roleFocuses, PriorityId? rememberedId) =>
    roleFocuses.firstWhere((f) => f.id == rememberedId,
        orElse: () => roleFocuses.first);
