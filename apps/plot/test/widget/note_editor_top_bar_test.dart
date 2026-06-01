import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:plot/widget/note_editor_top_bar.dart';

void main() {
  TopBarPill pill(String id, String label, {bool isActive = false, List<String>? avatars}) {
    return TopBarPill(
      id: id,
      label: label,
      avatarSlot: avatars,
      onTap: () {},
      onAvatarsTap: avatars == null ? null : () {},
    );
  }

  Widget host(Widget child) => FTheme(
        data: FThemes.zinc.light.desktop,
        child: Directionality(textDirection: TextDirection.ltr, child: child),
      );

  group('NoteEditorTopBar — PillRowState', () {
    testWidgets('renders all pill labels', (tester) async {
      await tester.pumpWidget(host(NoteEditorTopBar(
        state: PillRowState(
          pills: [pill('reply', 'Reply'), pill('task', 'Task'), pill('private', 'Private note')],
          activeId: 'reply',
        ),
        onClearReply: () {},
        onCancelEdit: () {},
      )));
      expect(find.text('Reply'), findsOneWidget);
      expect(find.text('Task'), findsOneWidget);
      expect(find.text('Private note'), findsOneWidget);
    });

    testWidgets('active pill has a background fill; inactive has none', (tester) async {
      await tester.pumpWidget(host(NoteEditorTopBar(
        state: PillRowState(
          pills: [pill('a', 'A'), pill('b', 'B')],
          activeId: 'a',
        ),
        onClearReply: () {},
        onCancelEdit: () {},
      )));
      // The pill container is keyed by 'pill-<id>'.
      final activeContainerFinder = find.descendant(
        of: find.byKey(const Key('pill-a')),
        matching: find.byType(Container),
      );
      final inactiveContainerFinder = find.descendant(
        of: find.byKey(const Key('pill-b')),
        matching: find.byType(Container),
      );
      final active = tester.widget<Container>(activeContainerFinder.first);
      final inactive = tester.widget<Container>(inactiveContainerFinder.first);
      expect((active.decoration as BoxDecoration?)?.color, isNotNull);
      expect((inactive.decoration as BoxDecoration?)?.color, isNull);
    });

    testWidgets('tapping a pill invokes its onTap', (tester) async {
      var tapped = false;
      await tester.pumpWidget(host(NoteEditorTopBar(
        state: PillRowState(
          pills: [TopBarPill(id: 'task', label: 'Task', onTap: () => tapped = true)],
          activeId: 'reply',
        ),
        onClearReply: () {},
        onCancelEdit: () {},
      )));
      await tester.tap(find.text('Task'));
      expect(tapped, isTrue);
    });
  });

  group('NoteEditorTopBar — ReplyingState', () {
    testWidgets('renders the reply chrome with quote preview', (tester) async {
      await tester.pumpWidget(host(NoteEditorTopBar(
        state: const ReplyingState(quotePreview: 'Sounds good, ship Friday'),
        onClearReply: () {},
        onCancelEdit: () {},
      )));
      expect(find.text('Replying'), findsOneWidget);
      expect(find.text('Sounds good, ship Friday'), findsOneWidget);
    });

    testWidgets('tapping X invokes onClearReply', (tester) async {
      var cleared = false;
      await tester.pumpWidget(host(NoteEditorTopBar(
        state: const ReplyingState(quotePreview: 'q'),
        onClearReply: () => cleared = true,
        onCancelEdit: () {},
      )));
      await tester.tap(find.byKey(const Key('top-bar-clear')));
      expect(cleared, isTrue);
    });
  });

  group('NoteEditorTopBar — EditingState', () {
    testWidgets('renders the editing chrome with preview', (tester) async {
      await tester.pumpWidget(host(NoteEditorTopBar(
        state: const EditingState(quotePreview: 'Old text'),
        onClearReply: () {},
        onCancelEdit: () {},
      )));
      expect(find.text('Editing'), findsOneWidget);
      expect(find.text('Old text'), findsOneWidget);
    });

    testWidgets('tapping X invokes onCancelEdit', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(host(NoteEditorTopBar(
        state: const EditingState(quotePreview: 'q'),
        onClearReply: () {},
        onCancelEdit: () => cancelled = true,
      )));
      await tester.tap(find.byKey(const Key('top-bar-clear')));
      expect(cancelled, isTrue);
    });
  });
}
