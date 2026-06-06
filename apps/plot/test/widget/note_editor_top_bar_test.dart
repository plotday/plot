import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';
import 'package:plot/widget/note_editor_top_bar.dart';

void main() {
  TopBarPill pill(String id, String label) {
    return TopBarPill(
      id: id,
      label: label,
      onTap: () {},
    );
  }

  Widget host(Widget child) => FTheme(
        data: FThemes.zinc.light.desktop,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Overlay(
            initialEntries: [OverlayEntry(builder: (_) => child)],
          ),
        ),
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

    testWidgets('active tab label is heavier than inactive', (tester) async {
      await tester.pumpWidget(host(NoteEditorTopBar(
        state: PillRowState(
          pills: [pill('a', 'A'), pill('b', 'B')],
          activeId: 'a',
        ),
        onClearReply: () {},
        onCancelEdit: () {},
      )));
      final active = tester.widget<Text>(find.text('A'));
      final inactive = tester.widget<Text>(find.text('B'));
      expect(active.style?.fontWeight, FontWeight.w600);
      expect(inactive.style?.fontWeight, FontWeight.normal);
      expect(active.style?.color, isNot(equals(inactive.style?.color)));
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

  group('NoteEditorTopBar — pill affordances', () {
    testWidgets('renders leading icon and recipient count pill', (tester) async {
      await tester.pumpWidget(host(NoteEditorTopBar(
        state: PillRowState(
          pills: [
            TopBarPill(
              id: 'reply',
              label: 'Reply all',
              leadingIcon: FontAwesomeIcons.replyAll,
              recipientCount: 3,
              editIcon: FontAwesomeIcons.pen,
              editTooltip: 'Edit recipients',
              onTap: () {},
              onEdit: () {},
            ),
          ],
          activeId: 'reply',
        ),
        onClearReply: () {},
        onCancelEdit: () {},
      )));
      expect(find.byIcon(FontAwesomeIcons.replyAll), findsOneWidget);
      expect(find.byIcon(FontAwesomeIcons.pen), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('tapping the edit affordance invokes onEdit, not onTap',
        (tester) async {
      var tapped = false;
      var edited = false;
      await tester.pumpWidget(host(NoteEditorTopBar(
        state: PillRowState(
          pills: [
            TopBarPill(
              id: 'reply',
              label: 'Reply',
              editIcon: FontAwesomeIcons.userPlus,
              editTooltip: 'Edit recipients',
              onTap: () => tapped = true,
              onEdit: () => edited = true,
            ),
          ],
          activeId: 'reply',
        ),
        onClearReply: () {},
        onCancelEdit: () {},
      )));
      await tester.tap(find.byIcon(FontAwesomeIcons.userPlus));
      // Drain the FTooltip hide-delay timer before the test ends.
      await tester.pumpAndSettle();
      expect(edited, isTrue);
      expect(tapped, isFalse);
    });

    testWidgets('no edit affordance when editIcon is null', (tester) async {
      await tester.pumpWidget(host(NoteEditorTopBar(
        state: PillRowState(
          pills: [TopBarPill(id: 'reply', label: 'Reply', onTap: () {})],
          activeId: 'reply',
        ),
        onClearReply: () {},
        onCancelEdit: () {},
      )));
      expect(find.byIcon(FontAwesomeIcons.pen), findsNothing);
      expect(find.byIcon(FontAwesomeIcons.userPlus), findsNothing);
    });
  });
}
