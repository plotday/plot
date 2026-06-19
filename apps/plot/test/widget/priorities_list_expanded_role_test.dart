import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/priorities_list.dart';

/// In single-panel mode the focus sidebar IS the whole screen, so a fully
/// collapsed accordion (every role shut) leaves the user no way to reach any
/// focus. [expandedRoleWithFallback] keeps exactly one role open: the
/// selection- or tap-driven one when present, otherwise the role of the last
/// focus the user opened ([lastSelected]), and only as a last resort the most
/// recently created role. These tests pin that contract.
Role _role({required DateTime createdAt}) => Role.fromRow(
  RoleRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: createdAt,
    updatedAt: createdAt,
    name: 'Role ${createdAt.toIso8601String()}',
    color: const ThemeColor.defaultColor(),
  ),
);

void main() {
  group('mostRecentRole', () {
    test('returns null for an empty list', () {
      expect(mostRecentRole(const []), isNull);
    });

    test('picks the role with the latest createdAt regardless of list order', () {
      final oldest = _role(createdAt: DateTime(2026, 1, 1));
      final middle = _role(createdAt: DateTime(2026, 3, 1));
      final newest = _role(createdAt: DateTime(2026, 6, 1));

      // Pass them shuffled — the comparison, not the position, decides.
      expect(mostRecentRole([middle, newest, oldest])?.id, newest.id);
    });
  });

  group('expandedRoleWithFallback', () {
    final oldest = _role(createdAt: DateTime(2026, 1, 1));
    final newest = _role(createdAt: DateTime(2026, 6, 1));
    final roles = [oldest, newest];

    test('keeps the preferred (selection/tap-driven) role when one is set', () {
      expect(
        expandedRoleWithFallback(
          singlePanel: true,
          roles: roles,
          preferred: oldest.id,
          // Even with a different last-selected role, the live selection wins.
          lastSelected: newest.id,
        ),
        oldest.id,
      );
    });

    test('no preferred re-opens the last focus\'s role (not the newest)', () {
      // The user last worked in the oldest role; returning to the list should
      // re-open it rather than defaulting to the most recently created role.
      expect(
        expandedRoleWithFallback(
          singlePanel: true,
          roles: roles,
          preferred: null,
          lastSelected: oldest.id,
        ),
        oldest.id,
      );
    });

    test('a removed last-selected role falls back to the most recent role', () {
      final removed = _role(createdAt: DateTime(2025, 1, 1));
      expect(
        expandedRoleWithFallback(
          singlePanel: true,
          roles: roles,
          preferred: null,
          lastSelected: removed.id, // no longer in `roles`
        ),
        newest.id,
      );
    });

    test('no preferred and nothing opened yet falls back to the most recent', () {
      expect(
        expandedRoleWithFallback(
          singlePanel: true,
          roles: roles,
          preferred: null,
          lastSelected: null,
        ),
        newest.id,
      );
    });

    test('multi-panel with no preferred stays all-collapsed (feed beside it)', () {
      expect(
        expandedRoleWithFallback(
          singlePanel: false,
          roles: roles,
          preferred: null,
          lastSelected: oldest.id,
        ),
        isNull,
      );
    });

    test('a single role keeps the flat layout — no fallback', () {
      expect(
        expandedRoleWithFallback(
          singlePanel: true,
          roles: [oldest],
          preferred: null,
          lastSelected: oldest.id,
        ),
        isNull,
      );
    });
  });
}
