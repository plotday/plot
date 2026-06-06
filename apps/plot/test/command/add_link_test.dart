import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/add_link.dart';
import 'package:plot/store/store.dart';

void main() {
  group('appendThreadReference', () {
    test('appends a ThreadUserAction with the given fields', () {
      final result = appendThreadReference(
        const [],
        threadId: 't1',
        title: 'Quarterly plan',
        priorityId: 'p1',
      );

      expect(result, hasLength(1));
      final action = result.single as ThreadUserAction;
      expect(action.threadId, 't1');
      expect(action.title, 'Quarterly plan');
      expect(action.priorityId, 'p1');
    });

    test('preserves existing actions and appends at the end', () {
      const existing = ExternalUserAction(title: 'Doc', url: 'https://x.test');
      final result = appendThreadReference(
        const [existing],
        threadId: 't1',
        title: 'Plan',
        priorityId: 'p1',
      );

      expect(result, hasLength(2));
      expect(result.first, existing);
      expect((result.last as ThreadUserAction).threadId, 't1');
    });

    test('is a no-op when the same threadId is already attached', () {
      const existing = ThreadUserAction(threadId: 't1', title: 'Old');
      final result = appendThreadReference(
        const [existing],
        threadId: 't1',
        title: 'New title',
        priorityId: 'p1',
      );

      expect(result, hasLength(1));
      // Unchanged reference returned (no duplicate, no overwrite).
      expect(result.single, existing);
    });

    test('does not mutate the input list', () {
      final input = <UserAction>[];
      appendThreadReference(input, threadId: 't1', title: 'A', priorityId: 'p1');
      expect(input, isEmpty);
    });
  });
}
