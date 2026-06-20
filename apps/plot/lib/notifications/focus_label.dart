/// The role/focus crumb separator. Must match `Priority.separator` (' › ')
/// in `store/priority.dart`; kept inline here so this leaf helper (and its
/// unit test) carries no dependency on the Drift store library.
const String _focusSeparator = ' › ';

/// Build the "Role › Focus" label shown in a notification's header (Android
/// subText / iOS subtitle) so the user can tell which focus an update belongs
/// to.
///
/// The role is prepended only when the user has more than one role, mirroring
/// the `FocusLabel` display rule (`roles.length >= 2`) and the server's
/// `buildFocusLabel`. It uses the same ` › ` separator (`Priority.separator`).
/// A role-less focus (e.g. FYI) shows the focus alone, and the Personal root
/// focus title "Everything" is normalized to "Inbox" to match
/// `Priority.displayTitle`. Returns null when there is no focus title, so
/// callers can omit the subtext entirely.
///
/// This is the foreground-fallback twin of the server helper: it only runs when
/// the `/notification-summary` fetch fails and the client must label from local
/// data. The background isolate and the normal foreground path carry the label
/// in the server payload (`focus_label`).
String? buildFocusLabel(String? focusTitle, String? roleName, int roleCount) {
  final focus = focusTitle?.trim();
  if (focus == null || focus.isEmpty) return null;
  final normalizedFocus = focus == 'Everything' ? 'Inbox' : focus;
  final role = roleName?.trim();
  if (roleCount > 1 && role != null && role.isNotEmpty) {
    return '$role$_focusSeparator$normalizedFocus';
  }
  return normalizedFocus;
}
