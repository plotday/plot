import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/form_scheduler.dart';

void main() {
  group('StepperRow key handling', () {
    late FocusNode node;
    setUp(() => node = FocusNode());
    tearDown(() => node.dispose());

    Future<void> pump(WidgetTester tester, List<String> log) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: StepperRow(
            focusNode: node,
            onStepBack: () => log.add('back'),
            onStepForward: () => log.add('forward'),
            onJumpBack: () => log.add('jumpBack'),
            onJumpForward: () => log.add('jumpForward'),
            child: const SizedBox(width: 100, height: 20),
          ),
        ),
      );
      node.requestFocus();
      await tester.pump();
    }

    testWidgets('Left/Right step; Shift+Left/Right jump', (tester) async {
      final log = <String>[];
      await pump(tester, log);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(log, ['back', 'forward']);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(log, ['back', 'forward', 'jumpBack', 'jumpForward']);
    });

    testWidgets('Up/Down/Tab do not trigger step callbacks', (tester) async {
      final log = <String>[];
      await pump(tester, log);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      expect(log, isEmpty);
    });

    testWidgets('paints highlightColor behind the child when provided',
        (tester) async {
      const hl = Color(0xFF123456);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: StepperRow(
            focusNode: node,
            highlightColor: hl,
            child: const SizedBox(width: 100, height: 20),
          ),
        ),
      );
      final boxes = tester.widgetList<ColoredBox>(find.byType(ColoredBox));
      expect(boxes.any((b) => b.color == hl), isTrue);
    });
  });
}
