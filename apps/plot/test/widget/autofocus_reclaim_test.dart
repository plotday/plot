import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/autofocus_reclaim.dart';

void main() {
  Widget harness({
    required FocusNode node,
    required bool autofocus,
    List<Widget> before = const [],
  }) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        children: [
          ...before,
          AutofocusReclaim(
            focusNode: node,
            autofocus: autofocus,
            child: Focus(
              focusNode: node,
              child: const SizedBox(width: 10, height: 10),
            ),
          ),
        ],
      ),
    );
  }

  testWidgets('claims focus on mount when no one owns it', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);

    await tester.pumpWidget(harness(node: node, autofocus: true));
    // Reclaim observes one frame, then requests focus across follow-up frames.
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(node.hasFocus, isTrue);
  });

  testWidgets('does nothing when autofocus is false', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);

    await tester.pumpWidget(harness(node: node, autofocus: false));
    await tester.pump();
    await tester.pump();

    expect(node.hasFocus, isFalse);
  });

  testWidgets('does not steal focus from another focused widget', (
    tester,
  ) async {
    final node = FocusNode();
    final other = FocusNode();
    addTearDown(node.dispose);
    addTearDown(other.dispose);

    await tester.pumpWidget(
      harness(
        node: node,
        autofocus: true,
        before: [
          Focus(
            autofocus: true,
            focusNode: other,
            child: const SizedBox(width: 10, height: 10),
          ),
        ],
      ),
    );
    // Run past the full reclaim retry window — focus must stay with `other`.
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }

    expect(other.hasFocus, isTrue);
    expect(node.hasFocus, isFalse);
  });

  testWidgets('starts reclaiming when autofocus flips on', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);

    // Mounted without autofocus (e.g. a layout where this editor isn't the
    // active composer): focus is left alone.
    await tester.pumpWidget(harness(node: node, autofocus: false));
    await tester.pump();
    await tester.pump();
    expect(node.hasFocus, isFalse);

    // Autofocus turns on (e.g. a panel-layout change promotes it): reclaim.
    await tester.pumpWidget(harness(node: node, autofocus: true));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(node.hasFocus, isTrue);
  });
}
