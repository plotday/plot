import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/event_properties.dart';
import 'package:plot/store/store.dart';

void main() {
  group('recipientScope', () {
    test('private wins over everything', () {
      expect(
        recipientScope(isPrivate: true, hasCustomAudience: true),
        'private',
      );
    });

    test('custom when narrowed audience and not private', () {
      expect(
        recipientScope(isPrivate: false, hasCustomAudience: true),
        'custom',
      );
    });

    test('everyone when no narrowing', () {
      expect(
        recipientScope(isPrivate: false, hasCustomAudience: false),
        'everyone',
      );
    });
  });

  group('attachmentTypeNames', () {
    test('sorted and de-duplicated', () {
      expect(
        attachmentTypeNames([
          UserActionType.file,
          UserActionType.external,
          UserActionType.file,
        ]),
        ['external', 'file'],
      );
    });

    test('empty input yields empty list', () {
      expect(attachmentTypeNames(const []), isEmpty);
    });
  });

  group('composedThreadType', () {
    test('active thread is a task', () {
      expect(composedThreadType(active: true), 'task');
    });

    test('inactive thread is notes', () {
      expect(composedThreadType(active: false), 'notes');
    });
  });
}
