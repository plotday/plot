import 'package:flutter_test/flutter_test.dart';

import 'package:plot/notifications/focus_label.dart';

void main() {
  group('buildFocusLabel', () {
    test('prefixes the role when the user has more than one role', () {
      // Mirrors the server helper and FocusLabel's `roles.length >= 2` rule,
      // using the same ` › ` separator (Priority.separator).
      expect(buildFocusLabel('Marketing', 'Plot', 2), 'Plot › Marketing');
    });

    test('shows the focus alone when the user has exactly one role', () {
      expect(buildFocusLabel('Marketing', 'Plot', 1), 'Marketing');
    });

    test("normalizes the Personal root focus title 'Everything' to 'Inbox'", () {
      expect(buildFocusLabel('Everything', 'Plot', 2), 'Plot › Inbox');
      expect(buildFocusLabel('Everything', 'Plot', 1), 'Inbox');
    });

    test('omits the role prefix when the focus has no role', () {
      expect(buildFocusLabel('Operations', null, 3), 'Operations');
    });

    test('returns null when there is no focus title', () {
      expect(buildFocusLabel(null, 'Plot', 2), isNull);
      expect(buildFocusLabel('', 'Plot', 2), isNull);
    });
  });
}
