import 'package:plot/store/store.dart';
import 'package:plot/util/theme_color.dart';

/// Pre-filled values for the focus create form. The "Add a focus" picker opens
/// the create modal with one of these populated so a suggestion is one tap from
/// an editable, ready-to-create focus. Onboarding's chips used to drive this;
/// the suggestions now live in the regular create flow.
class FocusPrefill {
  const FocusPrefill({
    required this.title,
    required this.description,
    required this.iconKey,
    this.color,
    this.suggestionKey,
  });

  /// Focus name pre-filled into the title field.
  final String title;

  /// Description pre-filled into the (required) description field. Transient —
  /// it feeds matching but isn't stored on the focus.
  final String description;

  /// Key into [PlotIcon.focusIcons] for the pre-selected icon.
  final String iconKey;

  /// Optional pre-selected colour. Null seeds the picker with the default
  /// colour.
  final ThemeColor? color;

  /// Stable identifier for a curated suggestion. When a focus is created from a
  /// prefill that carries this, the key is recorded in
  /// [DismissedFocusSuggestions] so the suggestion stops appearing. Null for
  /// the custom/empty create path.
  final String? suggestionKey;
}

/// Curated focus suggestions shown in the "Add a focus" picker.
///
/// Maintaining this list:
///  * Add an item → append with a fresh unique [FocusPrefill.suggestionKey];
///    it appears for everyone (no one has dismissed a brand-new key).
///  * Remove an item → delete the entry; any stored dismissal of its key
///    becomes a harmless orphan (filtering ignores unknown keys).
///  * Never reuse a key for a different concept — it would inherit the old
///    item's dismissals.
const List<FocusPrefill> kFocusSuggestions = [
  FocusPrefill(
    suggestionKey: 'project',
    title: 'Project',
    description: "Tasks, docs, and discussions for a project",
    iconKey: 'rocket',
    color: ThemeColor(0),
  ),
  FocusPrefill(
    suggestionKey: 'customers',
    title: 'Customers',
    description:
        'Supporting current customers and developing prospective customers',
    iconKey: 'handshake',
    color: ThemeColor(5),
  ),
  FocusPrefill(
    suggestionKey: 'operations',
    title: 'Operations',
    description: 'Maintaining processes and systems',
    iconKey: 'conveyorBelt',
    color: ThemeColor(1),
  ),
  FocusPrefill(
    suggestionKey: 'management',
    title: 'Management',
    description: 'One-on-ones, updates, and the people you manage',
    iconKey: 'userGroup',
    color: ThemeColor(2),
  ),
  FocusPrefill(
    suggestionKey: 'recruiting',
    title: 'Recruiting',
    description: 'Candidates, interviews, and your hiring pipeline',
    iconKey: 'userMagnifyingGlass',
    color: ThemeColor(5),
  ),
  FocusPrefill(
    suggestionKey: 'admin',
    title: 'Admin',
    description: 'HR, expenses, and administrative tasks',
    iconKey: 'receipt',
    color: ThemeColor(7),
  ),
  FocusPrefill(
    suggestionKey: 'reading',
    title: 'Reading',
    description: 'Articles, newsletters, and other long-form content',
    iconKey: 'bookOpen',
    color: ThemeColor(3),
  ),
  FocusPrefill(
    suggestionKey: 'volunteering',
    title: 'Volunteering',
    description: 'Everything related to a volunteer role',
    iconKey: 'handHoldingHeart',
    color: ThemeColor(4),
  ),
  FocusPrefill(
    suggestionKey: 'personal_admin',
    title: 'Personal admin',
    description: 'Errands, appointments, and personal to-dos',
    iconKey: 'house',
    color: ThemeColor(3),
  ),
  FocusPrefill(
    suggestionKey: 'social',
    title: 'Social',
    description: 'Friends and events',
    iconKey: 'balloons',
    color: ThemeColor(3),
  ),
  FocusPrefill(
    suggestionKey: 'promotions',
    title: 'Promotions',
    description: 'Offers and updates from brands you follow',
    iconKey: 'billboard',
    color: ThemeColor(6),
  ),
];

/// The suggestions still worth offering: every [kFocusSuggestions] entry whose
/// key is not in [dismissed], in source order.
List<FocusPrefill> visibleFocusSuggestions(Set<String> dismissed) =>
    kFocusSuggestions
        .where((s) => !dismissed.contains(s.suggestionKey))
        .toList();

/// Pure: append [key] to [existing] unless already present, preserving order.
/// Returns the same instance when nothing changes (lets callers skip a write).
List<String> mergeDismissed(List<String> existing, String key) {
  if (existing.contains(key)) return existing;
  return [...existing, key];
}

/// Cross-device record of the focus suggestions the user has acted on. Backed
/// by `user_settings.dismissed_focus_suggestions` (synced; union-merged
/// server-side).
class DismissedFocusSuggestions {
  const DismissedFocusSuggestions._();

  /// The dismissed suggestion keys. Empty when no settings row exists yet.
  static Future<Set<String>> get() async {
    final row = await UserSettingsEntity.get();
    return (row?.dismissedFocusSuggestions ?? const <String>[]).toSet();
  }

  /// Records [key] as dismissed (idempotent). No-op when already present, so a
  /// re-created suggestion doesn't churn the sync row.
  static Future<void> add(String key) async {
    final row = await UserSettingsEntity.get();
    final existing = row?.dismissedFocusSuggestions ?? const <String>[];
    final merged = mergeDismissed(existing, key);
    if (identical(merged, existing)) return;
    // Only this column is set; Store.save's DoUpdate updates present columns
    // only, so other settings (onboarding_completed, etc.) are preserved.
    await UserSettingsEntity.save(
      UserSettingsCompanion(dismissedFocusSuggestions: Value(merged)),
    );
  }
}
