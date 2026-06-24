import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:provider/provider.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/util/value.dart';
import 'package:plot/widget/modal.dart';

/// Hosts a [ModalProvider] under a [Navigator] (which showFDialog needs) and
/// captures a context inside the provider so the test can drive push/popForSwap
/// directly — the real hand-off path used after OAuth.
Widget _host(void Function(BuildContext) onInner) {
  final scheme = ColourSchemeData(
    themeColor: const ThemeColor.defaultColor(),
    brightness: Brightness.light,
  );
  return Provider<ColourSchemeData>.value(
    value: scheme,
    child: Builder(
      builder: (context) => FTheme(
        data: buildTheme(context, scheme),
        child: MediaQuery(
          // >760px => multi-panel => Modal uses showFDialog (needs a Navigator).
          data: const MediaQueryData(size: Size(900, 800)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Navigator(
              onGenerateRoute: (_) => PageRouteBuilder<void>(
                pageBuilder: (_, _, _) => ModalProvider(
                  child: Builder(
                    builder: (inner) {
                      onInner(inner);
                      return const SizedBox.expand();
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A modal whose content is a single labelled [Text], so the test can find it
/// and inspect the [Offstage] the modal stack wraps each entry in.
Modal _labelled(String label) =>
    Modal(builder: (_) => Text(label), showCloseButton: false);

/// Whether [label]'s modal is the visible top of the stack — i.e. its
/// modal-stack [Offstage] wrapper is showing (not offstage). Returns false when
/// the text isn't mounted at all.
bool _isShown(WidgetTester tester, String label) {
  final text = find.text(label);
  if (text.evaluate().isEmpty) return false;
  final offstage = find.ancestor(of: text, matching: find.byType(Offstage));
  if (offstage.evaluate().isEmpty) return true;
  // The nearest Offstage ancestor is the modal stack's per-entry wrapper.
  return !tester.widget<Offstage>(offstage.first).offstage;
}

void main() {
  testWidgets(
    'popForSwap keeps the handed-off modal on top until the next push swaps it '
    '— the modal beneath never flashes into view',
    (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(_host((inner) => ctx = inner));
      await tester.pump();

      // Stack: [A]. A is the underlying modal (stands in for the connections
      // list). It opens the dialog route.
      unawaited2(
        Modal(
          builder: (_) => const Text('A'),
          showCloseButton: false,
        ).show<void>(ctx),
      );
      await tester.pumpAndSettle();
      expect(_isShown(tester, 'A'), isTrue);

      // Stack: [A, B]. B is the auth modal (AddSourceDetail).
      final bFuture = _labelled('B').show<void>(ctx);
      await tester.pumpAndSettle();
      expect(_isShown(tester, 'B'), isTrue, reason: 'B is the new top');
      expect(_isShown(tester, 'A'), isFalse, reason: 'A is covered by B');

      // OAuth success: hand B off. Its run() resumes (bFuture completes) but B
      // STAYS on display so A (the list) does not flash in while the next modal
      // loads.
      Modal.popForSwap<void>(ctx, Value<void>.absent());
      await bFuture; // run() resumed
      // Pump a frame: this is exactly the window where the bug showed A.
      await tester.pump();
      expect(
        _isShown(tester, 'B'),
        isTrue,
        reason: 'handed-off B must remain on display during the gap',
      );
      expect(
        _isShown(tester, 'A'),
        isFalse,
        reason: 'A (the connections list) must NOT flash into view',
      );

      // The next modal opens (EditSource). It atomically replaces B; A is still
      // never revealed.
      unawaited2(_labelled('C').show<void>(ctx));
      await tester.pumpAndSettle();
      expect(_isShown(tester, 'C'), isTrue, reason: 'C is the new top');
      expect(_isShown(tester, 'B'), isFalse, reason: 'B was swapped out');
      expect(_isShown(tester, 'A'), isFalse, reason: 'A still covered by C');

      // Closing C returns to A — the retained B is gone, so it is not revisited.
      Modal.pop<void>(ctx, Value<void>.absent());
      await tester.pumpAndSettle();
      expect(_isShown(tester, 'A'), isTrue, reason: 'back to the list');
      expect(find.text('B'), findsNothing);
      expect(find.text('C'), findsNothing);
    },
  );

  testWidgets(
    'swap works when the handed-off modal is the ONLY one on the stack '
    '(onboarding) — the dialog route is reused, not reopened',
    (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(_host((inner) => ctx = inner));
      await tester.pump();

      // Stack: [B] — B opens the dialog route (no underlying list modal).
      final bFuture = _labelled('B').show<void>(ctx);
      await tester.pumpAndSettle();
      expect(_isShown(tester, 'B'), isTrue);

      // Hand B off, then open C. With B as the sole modal this is the length==1
      // edge: the swap must NOT reopen the dialog route.
      Modal.popForSwap<void>(ctx, Value<void>.absent());
      await bFuture;
      await tester.pump();
      unawaited2(_labelled('C').show<void>(ctx));
      await tester.pumpAndSettle();
      expect(_isShown(tester, 'C'), isTrue);
      expect(find.text('B'), findsNothing);

      // Closing C drains the (single) route and returns to the host — no
      // stranded B and no leftover second dialog.
      Modal.pop<void>(ctx, Value<void>.absent());
      await tester.pumpAndSettle();
      expect(find.text('C'), findsNothing);
      expect(find.text('B'), findsNothing);
    },
  );

  testWidgets(
    'a user dismiss during the hand-off window still removes the retained modal',
    (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(_host((inner) => ctx = inner));
      await tester.pump();

      unawaited2(_labelled('A').show<void>(ctx));
      await tester.pumpAndSettle();
      final bFuture = _labelled('B').show<void>(ctx);
      await tester.pumpAndSettle();

      Modal.popForSwap<void>(ctx, Value<void>.absent());
      await bFuture;
      await tester.pump();

      // User hits Esc before the next modal opens: dismiss must not throw on the
      // already-completed completer, and must drop B back to A.
      Modal.pop<void>(ctx, Value<void>.absent());
      await tester.pumpAndSettle();
      expect(_isShown(tester, 'A'), isTrue);
      expect(find.text('B'), findsNothing);
    },
  );
}

/// Local `unawaited` so the test file needs no extra import.
void unawaited2(Future<void> _) {}
