import 'package:flutter_test/flutter_test.dart';
import 'package:plot/analytics/conventions.dart';
import 'package:plot/analytics/properties.dart';

void main() {
  group('buildActionProperties', () {
    test('always includes the base action keys', () {
      final props = buildActionProperties(
        actionType: 'AddNote',
        success: true,
        durationMs: 12,
      );
      expect(props[PropertyKey.actionType], 'AddNote');
      expect(props[PropertyKey.success], true);
      expect(props[PropertyKey.durationMs], 12);
    });

    test('merges command-specific extra properties', () {
      final props = buildActionProperties(
        actionType: 'AddNote',
        success: true,
        durationMs: 0,
        extra: {'is_todo': true, 'attachment_count': 2},
      );
      expect(props['is_todo'], true);
      expect(props['attachment_count'], 2);
      // Base keys still present alongside the extras.
      expect(props[PropertyKey.actionType], 'AddNote');
    });

    test('null extra leaves the base properties untouched', () {
      final props = buildActionProperties(
        actionType: 'X',
        success: false,
        durationMs: 5,
        extra: null,
      );
      expect(props.containsKey('is_todo'), isFalse);
      expect(props[PropertyKey.success], false);
    });
  });

  group('buildEventName for new enum values', () {
    test('role added', () {
      expect(
        buildEventName(EventCategory.action, EventObject.role, EventAction.added),
        '[Action] Role Added',
      );
    });

    test('activity joined', () {
      expect(
        buildEventName(
          EventCategory.action,
          EventObject.activity,
          EventAction.joined,
        ),
        '[Action] Activity Joined',
      );
    });

    test('note retried', () {
      expect(
        buildEventName(
          EventCategory.action,
          EventObject.note,
          EventAction.retried,
        ),
        '[Action] Note Retried',
      );
    });
  });
}
