import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plot/command/priority.dart';
import 'package:plot/store/store.dart';

Priority _priority({required String title}) {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: title,
    path: Path(title.toLowerCase()),
    order: Order(0),
    unread: false,
    role: 'member',
    isInbox: false,
    isFyi: false,
    attentionWindowSet: false,
    seeWithinSet: false,
    earlyNotificationsEnabledSet: false,
    notifyWindowSet: false,
    sendWindowSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

void main() {
  testWidgets(
    'NewPrivateNote.run returns OpenPrivateNoteThread for the priority',
    (tester) async {
      final priority = _priority(title: 'Work');
      late BuildContext ctx;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final result = await NewPrivateNote(priority).run(ctx);

      expect(result, isA<OpenPrivateNoteThread>());
      expect(
        (result as OpenPrivateNoteThread).priorityIdString,
        priority.id.toShortString(),
      );
    },
  );
}
