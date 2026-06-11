import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:provider/provider.dart';

import 'package:plot/analytics/conventions.dart';
import 'package:plot/command/base.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/list_tile.dart';
import 'package:plot/widget/spinner.dart';

/// The running-command spinner is centred over the leading slot. Leading slots
/// centre their icon in a symmetric box (the sidebar's md-both-sides slot, the
/// modal unread dot), so the spinner lands on the icon. This guards against an
/// asymmetric leading box (e.g. the old left-20 / right-12 metric) drifting the
/// spinner off the icon.
class _SlowCommand extends Command {
  _SlowCommand(this.gate)
    : super(
        title: 'Slow',
        eventObject: EventObject.action,
        eventAction: EventAction.opened,
      );

  final Completer<void> gate;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await gate.future;
    return const CommandDone();
  }
}

void main() {
  Widget host(Widget child) {
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
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 280, child: child),
            ),
          ),
        ),
      ),
    );
  }

  const slotKey = Key('leading-slot');

  /// Pumps the tile, fires the (in-flight) command, waits past the 100ms
  /// spinner-delay timer, and returns the icon-slot and spinner centres.
  Future<(double slotCenter, double spinnerCenter)> showSpinner(
    WidgetTester tester,
    Widget Function(bool, bool) leadingBuilder,
  ) async {
    final gate = Completer<void>();
    final controller = ListTileController();

    await tester.pumpWidget(
      host(
        ListTile(
          controller: controller,
          command: _SlowCommand(gate),
          onRun: (context, result) async => true,
          leadingBuilder: leadingBuilder,
          title: 'Reconnect Gmail',
        ),
      ),
    );

    unawaited(controller.run());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    final spinner = find.byType(Spinner);
    expect(spinner, findsOneWidget, reason: 'spinner should be visible');

    final slotCenter = tester.getRect(find.byKey(slotKey)).center.dx;
    final spinnerCenter = tester.getRect(spinner).center.dx;

    gate.complete();
    await tester.pumpAndSettle();
    return (slotCenter, spinnerCenter);
  }

  testWidgets('sidebar slot: spinner centres on the icon (md both sides)', (
    tester,
  ) async {
    // Mirrors sidebarLeading: an iconSize square with a symmetric horizontal
    // inset. The keyed box marks the icon slot.
    final (slotCenter, spinnerCenter) = await showSpinner(
      tester,
      (_, _) => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 10),
        child: SizedBox.square(key: slotKey, dimension: 16),
      ),
    );

    expect(
      spinnerCenter,
      moreOrLessEquals(slotCenter, epsilon: 0.5),
      reason: 'spinner ($spinnerCenter) must sit on the icon ($slotCenter)',
    );
  });

  testWidgets('modal unread row: spinner centres on the dot box', (
    tester,
  ) async {
    // Mirrors command_modal's unread row: a 6px dot centred in a 20px box.
    final (slotCenter, spinnerCenter) = await showSpinner(
      tester,
      (_, _) => const SizedBox(
        key: slotKey,
        width: 20,
        child: Center(child: SizedBox.square(dimension: 6)),
      ),
    );

    expect(
      spinnerCenter,
      moreOrLessEquals(slotCenter, epsilon: 0.5),
      reason:
          'spinner ($spinnerCenter) must stay centred over the 20px box '
          '($slotCenter) so modal rows are unchanged',
    );
  });
}
