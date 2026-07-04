import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:plot/widget/note_editor_top_bar.dart';

void main() {
  testWidgets('ForwardingState renders "Forwarding" + preview + clear', (
    tester,
  ) async {
    var cleared = false;
    await tester.pumpWidget(
      FTheme(
        data: FThemes.zinc.light.desktop,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: NoteEditorTopBar(
            state: const ForwardingState(quotePreview: 'Q3 budget review'),
            roundTop: false,
            onClearReply: () {},
            onCancelEdit: () {},
            onClearForward: () => cleared = true,
          ),
        ),
      ),
    );
    expect(find.text('Forwarding'), findsOneWidget);
    expect(find.text('Q3 budget review'), findsOneWidget);
    await tester.tap(find.byKey(const Key('top-bar-clear')));
    expect(cleared, isTrue);
  });
}
