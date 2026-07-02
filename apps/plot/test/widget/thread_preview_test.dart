import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:provider/provider.dart';

import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/note_editor.dart';
import 'package:plot/widget/thread_preview.dart';

Priority _testPriority() {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: 'Test',
    path: Path('test'),
    order: const Order(0),
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

Widget _host(Widget child) {
  final scheme = ColourSchemeData(
    themeColor: const ThemeColor.defaultColor(),
    brightness: Brightness.light,
  );
  return Provider<ColourSchemeData>.value(
    value: scheme,
    child: Builder(
      builder: (context) => FTheme(
        data: buildTheme(context, scheme),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: child,
        ),
      ),
    ),
  );
}

void main() {
  final priority = _testPriority();

  testWidgets('renders the thread title', (tester) async {
    final thread = Thread(priority: priority, title: 'Weekly sync');
    await tester.pumpWidget(_host(ThreadPreview(thread: thread)));
    expect(find.text('Weekly sync'), findsOneWidget);
  });

  testWidgets('never mounts a NoteEditor', (tester) async {
    final thread = Thread(priority: priority, title: 'No editor here');
    await tester.pumpWidget(_host(ThreadPreview(thread: thread)));
    expect(find.byType(NoteEditor), findsNothing);
  });

  testWidgets('is non-interactive (wrapped in IgnorePointer)', (tester) async {
    final thread = Thread(priority: priority, title: 'Read only');
    await tester.pumpWidget(_host(ThreadPreview(thread: thread)));
    expect(find.byType(IgnorePointer), findsWidgets);
  });
}
