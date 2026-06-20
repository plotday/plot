import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/focus_keeper.dart';

void main() {
  // Cmd+K — the canonical global shortcut. We bind it literally (meta) so the
  // test is independent of the host platform's modifier convention; the bug
  // under test is about the focus *chain*, not which modifier is used.
  Future<void> sendCmdK(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  }

  testWidgets(
    'global shortcut dies when focus parks on an ancestor scope and revives '
    'after restoreFocus',
    (tester) async {
      var cmdK = 0;
      final field = FocusNode(debugLabel: 'field');
      addTearDown(field.dispose);
      final keeper = FocusKeeper.forTest();

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          // An ancestor scope stands in for the root scope macOS parks focus
          // on. It sits *above* CallbackShortcuts, so once it owns focus the
          // shortcut's Focus node is no longer in the key-dispatch chain.
          child: FocusScope(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
                    cmdK++,
              },
              child: Focus(
                focusNode: field,
                child: const SizedBox(width: 10, height: 10),
              ),
            ),
          ),
        ),
      );

      field.requestFocus();
      await tester.pump();
      keeper.recordFocus();
      expect(field.hasFocus, isTrue);

      // Works while the field (a descendant of CallbackShortcuts) owns focus.
      await sendCmdK(tester);
      expect(cmdK, 1);

      // macOS parks focus on the ancestor scope (window blur). The shortcut's
      // Focus node drops out of the dispatch chain.
      field.unfocus();
      await tester.pump();
      keeper.recordFocus(); // scope node — must NOT overwrite the remembered leaf
      expect(field.hasFocus, isFalse);

      // Bug reproduced: the global shortcut is now dead.
      await sendCmdK(tester);
      expect(cmdK, 1);

      // Window regains focus → FocusKeeper restores the last real focus owner.
      keeper.restoreFocus();
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
      expect(field.hasFocus, isTrue);

      // Shortcut fires again.
      await sendCmdK(tester);
      expect(cmdK, 2);
    },
  );

  testWidgets('restoreFocus never steals focus from a control the user is using', (
    tester,
  ) async {
    final a = FocusNode(debugLabel: 'a');
    final b = FocusNode(debugLabel: 'b');
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    final keeper = FocusKeeper.forTest();

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: FocusScope(
          child: Column(
            children: [
              Focus(
                focusNode: a,
                child: const SizedBox(width: 10, height: 10),
              ),
              Focus(
                focusNode: b,
                child: const SizedBox(width: 10, height: 10),
              ),
            ],
          ),
        ),
      ),
    );

    a.requestFocus();
    await tester.pump();
    keeper.recordFocus(); // remembered leaf = a

    // The user has since moved focus to b (a real leaf owns focus).
    b.requestFocus();
    await tester.pump();

    keeper.restoreFocus();
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }

    expect(b.hasFocus, isTrue);
    expect(a.hasFocus, isFalse);
  });

  testWidgets(
    'recordFocus remembers genuine leaves and ignores scope nodes',
    (tester) async {
      final field = FocusNode(debugLabel: 'field');
      addTearDown(field.dispose);
      final keeper = FocusKeeper.forTest();

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: FocusScope(
            child: Focus(
              focusNode: field,
              child: const SizedBox(width: 10, height: 10),
            ),
          ),
        ),
      );

      field.requestFocus();
      await tester.pump();
      keeper.recordFocus();
      expect(keeper.lastFocused, same(field));

      // Focus falls back to the enclosing scope (a FocusScopeNode). The
      // remembered leaf must survive — that is what restore re-targets.
      field.unfocus();
      await tester.pump();
      keeper.recordFocus();
      expect(keeper.lastFocused, same(field));
    },
  );
}
