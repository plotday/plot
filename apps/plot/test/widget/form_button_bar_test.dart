import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:provider/provider.dart';

import 'package:plot/analytics/conventions.dart';
import 'package:plot/command/base.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/form_button_bar.dart';

/// A trivial command that records when it ran. Returns [CommandSkipped] so the
/// wrapped command's success path does NOT call `Modal.pop` — letting these
/// tests run without a `ModalProvider`/`Modal` host.
class _RecordCommand extends Command {
  _RecordCommand(this.onRan, {required super.title})
    : super(
        eventObject: EventObject.action,
        eventAction: EventAction.opened,
      );
  final void Function() onRan;
  @override
  Future<CommandReturn> run(BuildContext context) async {
    onRan();
    return const CommandSkipped();
  }
}

/// Pumps [child] inside the Plot theme at [width] logical pixels wide.
/// width >= 760 => multi-panel; < 760 => single-panel.
Widget host(Widget child, {double width = 900}) {
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
          data: MediaQueryData(size: Size(width, 800)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: width, child: child),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('buildWrappedFormButtonCommand runs the built command', (
    tester,
  ) async {
    var ran = false;
    late CommandWrapper wrapped;
    await tester.pumpWidget(
      host(
        FormScope(
          values: const {},
          validate: () => true,
          child: Builder(
            builder: (context) {
              wrapped = buildWrappedFormButtonCommand(
                context,
                buildCommand: (_) =>
                    _RecordCommand(() => ran = true, title: 'Save'),
                skipValidation: false,
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    await wrapped.run(tester.element(find.byType(SizedBox).first));
    expect(ran, isTrue);
  });

  FormButton btn(
    String key,
    String title, {
    bool isPrimary = false,
    bool skipValidation = false,
    bool destructive = false,
    void Function()? onRan,
  }) => FormButton(
    key: key,
    isPrimary: isPrimary,
    skipValidation: skipValidation,
    destructive: destructive,
    buildCommand: (_) => _RecordCommand(onRan ?? () {}, title: title),
  );

  Widget bar(FormButtonBar b, {required double width}) => host(
    FormScope(
      values: const {},
      validate: () => true,
      child: Builder(
        builder: (context) => b.build(
          context,
          -1,
          enabled: true,
          focusNodes: List.generate(b.focusableCount, (_) => FocusNode()),
        ),
      ),
    ),
    width: width,
  );

  testWidgets('single-panel: buttons stack vertically (primary above secondary)', (
    tester,
  ) async {
    final b = FormButtonBar(
      key: 'actions',
      buttons: [
        btn('save', 'Save', isPrimary: true),
        btn('archive', 'Archive', skipValidation: true, destructive: true),
      ],
    );
    await tester.pumpWidget(bar(b, width: 400)); // single-panel
    await tester.pumpAndSettle();

    final saveRect = tester.getRect(find.text('Save'));
    final archiveRect = tester.getRect(find.text('Archive'));
    // Stacked: Archive sits below Save.
    expect(archiveRect.top, greaterThan(saveRect.bottom));
    // Centred: both labels' horizontal centres are near the 400px midline.
    expect(saveRect.center.dx, moreOrLessEquals(200, epsilon: 8));
    expect(archiveRect.center.dx, moreOrLessEquals(200, epsilon: 8));
  });

  testWidgets('primarySubIndex / isSubSlotEnabled reflect button flags', (
    tester,
  ) async {
    final b = FormButtonBar(
      key: 'actions',
      buttons: [
        btn('save', 'Save', isPrimary: true),
        btn('archive', 'Archive', skipValidation: true),
      ],
    );
    expect(b.primarySubIndex, 0);
    // Primary needs a valid form; skipValidation secondary is always enabled.
    expect(b.isSubSlotEnabled(0, false), isFalse);
    expect(b.isSubSlotEnabled(0, true), isTrue);
    expect(b.isSubSlotEnabled(1, false), isTrue);
  });

  testWidgets('multi-panel: primary fills left, secondary sits to its right', (
    tester,
  ) async {
    final b = FormButtonBar(
      key: 'actions',
      buttons: [
        btn('save', 'Save', isPrimary: true),
        btn('archive', 'Archive', skipValidation: true),
      ],
    );
    await tester.pumpWidget(bar(b, width: 900)); // multi-panel
    await tester.pumpAndSettle();

    final saveRect = tester.getRect(find.text('Save'));
    final archiveRect = tester.getRect(find.text('Archive'));
    // Same row (roughly equal vertical centres).
    expect(
      saveRect.center.dy,
      moreOrLessEquals(archiveRect.center.dy, epsilon: 4),
    );
    // Secondary is to the right of the primary.
    expect(archiveRect.center.dx, greaterThan(saveRect.center.dx));
  });

  testWidgets('multi-panel: 1 + 2 lays all three on one row in order', (
    tester,
  ) async {
    final b = FormButtonBar(
      key: 'actions',
      buttons: [
        btn('save', 'Save', isPrimary: true),
        btn('details', 'Details'),
        btn('archive', 'Archive', skipValidation: true),
      ],
    );
    await tester.pumpWidget(bar(b, width: 900));
    await tester.pumpAndSettle();

    final save = tester.getRect(find.text('Save')).center.dx;
    final details = tester.getRect(find.text('Details')).center.dx;
    final archive = tester.getRect(find.text('Archive')).center.dx;
    expect(save, lessThan(details));
    expect(details, lessThan(archive));
  });

  testWidgets('runSubSlot runs the targeted button (Enter-on-bar wiring)', (
    tester,
  ) async {
    var saved = false;
    var archived = false;
    final b = FormButtonBar(
      key: 'actions',
      buttons: [
        btn('save', 'Save', isPrimary: true, onRan: () => saved = true),
        btn(
          'archive',
          'Archive',
          skipValidation: true,
          onRan: () => archived = true,
        ),
      ],
    );
    await tester.pumpWidget(bar(b, width: 900));
    await tester.pumpAndSettle();

    // FormModal routes Enter on the highlighted cell to runSubSlot(subIndex).
    // The command runs before analytics tracking fires in `finally`; that
    // tracking throws because the Tracker backend isn't initialised in unit
    // tests, so swallow it — the behaviour under test (which button ran) has
    // already happened.
    try {
      await b.runSubSlot(1);
    } catch (_) {}
    await tester.pumpAndSettle();
    expect(archived, isTrue);
    expect(saved, isFalse);
  });

  testWidgets('destructive secondary turns destructive-coloured when highlighted', (
    tester,
  ) async {
    final b = FormButtonBar(
      key: 'actions',
      buttons: [
        btn('save', 'Save', isPrimary: true),
        btn('archive', 'Archive', skipValidation: true, destructive: true),
      ],
    );
    // highlightedSubIndex = 1 forces the Archive cell into its highlighted state.
    await tester.pumpWidget(
      host(
        FormScope(
          values: const {},
          validate: () => true,
          child: Builder(
            builder: (context) => b.build(
              context,
              1,
              enabled: true,
              focusNodes: List.generate(2, (_) => FocusNode()),
            ),
          ),
        ),
        width: 400,
      ),
    );
    await tester.pumpAndSettle();

    final ctx = tester.element(find.text('Archive'));
    // The ListTile renders its title as a Text.rich; the colour sits on the
    // inner TextSpan, not the top-level Text.style.
    final text = tester.widget<Text>(find.text('Archive'));
    final span = text.textSpan as TextSpan;
    final color =
        span.style?.color ?? (span.children?.first as TextSpan?)?.style?.color;
    expect(color, ctx.theme.colors.destructive);
  });
}
