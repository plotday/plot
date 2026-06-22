import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:provider/provider.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/util/input_modality.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/modal.dart';
import 'package:plot/widget/select_modal.dart';

/// A minimal item row that records whether the SelectModal asked it to show a
/// loading indicator. Keyed by label so the test can assert which specific row
/// is loading.
class _TestRow extends StatelessWidget {
  const _TestRow({required this.label, required this.isLoading})
    : super(key: const ValueKey('row'));

  final String label;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Text(label),
    );
  }
}

/// Hosts a [SelectModal]'s content inside the Plot theme + a [ModalProvider],
/// matching the harness used by other modal widget tests.
Widget _host({
  required List<String> items,
  required Future<bool> Function(BuildContext, String, String) onSelect,
}) {
  final scheme = ColourSchemeData(
    themeColor: const ThemeColor.defaultColor(),
    brightness: Brightness.light,
  );
  final groups = [SelectGroup<String>(items: items)];
  return Provider<ColourSchemeData>.value(
    value: scheme,
    child: Builder(
      builder: (context) => FTheme(
        data: buildTheme(context, scheme),
        child: MediaQuery(
          data: const MediaQueryData(size: Size(900, 800)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            // SelectModal auto-focuses its search field, whose text-selection
            // machinery needs an Overlay ancestor.
            child: Overlay(
              initialEntries: [
                OverlayEntry(
                  builder: (_) => ModalProvider(
                    child: Center(
                      child: SizedBox(
                        width: 460,
                        height: 560,
                        child: Builder(
                          builder: (inner) => SelectModal<String>(
                            items: (_) async => groups,
                            initialItems: groups,
                            itemBuilder: (item, isLoading) =>
                                _TestRow(label: item, isLoading: isLoading),
                            onSelect: onSelect,
                          ).builder(inner),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

_TestRow _rowFor(WidgetTester tester, String label) {
  return tester.widget<_TestRow>(
    find.byWidgetPredicate((w) => w is _TestRow && w.label == label),
  );
}

void main() {
  testWidgets(
    'tapping an un-hovered row shows the spinner on THAT row, not the first',
    (tester) async {
      // Tapping with a touch pointer fires no hover/enter events, so the
      // modal's hover-highlight never moves off its initial position — exactly
      // what happens when the modal opens under the cursor or on a touch
      // device. The loading spinner must still land on the tapped row.
      InputModality.debugSetLastInputWasKeyboard(false);

      final completer = Completer<bool>();
      await tester.pumpWidget(
        _host(
          items: const ['Apple', 'Banana', 'Cherry'],
          onSelect: (_, _, _) => completer.future,
        ),
      );
      await tester.pump();

      // Nothing is loading before the tap.
      expect(_rowFor(tester, 'Cherry').isLoading, isFalse);

      // Tap the third row without ever moving the mouse over it.
      await tester.tap(find.text('Cherry'));
      await tester.pump();

      // The spinner must be on the tapped row, and only that row.
      expect(
        _rowFor(tester, 'Cherry').isLoading,
        isTrue,
        reason: 'tapped row should show the loading spinner',
      );
      expect(
        _rowFor(tester, 'Apple').isLoading,
        isFalse,
        reason: 'untapped first row must NOT show a spinner',
      );

      completer.complete(false);
      await tester.pump();
    },
  );
}
