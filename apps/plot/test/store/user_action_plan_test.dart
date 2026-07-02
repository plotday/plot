import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

void main() {
  group('PlanOperation.description', () {
    test('createFocus renders title', () {
      final op = PlanOperation.fromJson({'type': 'createFocus', 'focusId': 'f1', 'title': 'Archive'});
      expect(op.description, 'Create focus "Archive"');
    });

    test('updateThread move-to-focus renders target focus', () {
      final op = PlanOperation.fromJson({
        'type': 'updateThread',
        'threadId': 't1',
        'threadTitle': 'Old thread',
        'changes': {
          'focus': {'id': 'f1', 'title': 'Archive'},
        },
      });
      expect(op.description, 'Update "Old thread": move to Archive');
    });

    test('updateFocus rename renders focus title', () {
      final op = PlanOperation.fromJson({
        'type': 'updateFocus',
        'focusId': 'f1',
        'focusTitle': 'Inbox',
        'changes': {'title': 'In'},
      });
      expect(op.description, 'Update focus "Inbox": rename');
    });

    test('createThread renders focusTitle', () {
      final op = PlanOperation.fromJson({
        'type': 'createThread',
        'title': 'New',
        'focusId': 'f1',
        'focusTitle': 'Archive',
      });
      expect(op.description, 'Create "New" in Archive');
    });
  });
}
