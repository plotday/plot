/// Generates the App Store review screenshot for the connection add-on
/// subscriptions. Renders the REAL purchase confirmation — the `SelectModal`
/// that `BuyAddonCommand` shows (via `ConfirmModal`), with the real
/// `SubscriptionDisclosure` (price + auto-renew + Terms/Privacy) — into a PNG.
///
/// Run: `flutter test test/screenshot/addon_review_screenshot_test.dart`
/// Output: `docs/app-store/screenshots/addon-connection-review.png` (upload to
/// all three add-on products in App Store Connect — Apple wants the in-app
/// purchase screen, not its own StoreKit sheet). Rerun and commit the PNG
/// whenever the copy or price changes.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:provider/provider.dart';

import 'package:plot/command/upgrade.dart' show SubscriptionDisclosure;
import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/list_tile.dart';
import 'package:plot/widget/modal.dart';
import 'package:plot/widget/select_modal.dart';

/// Tests render text as placeholder boxes unless real fonts are loaded. Load
/// the app's Figtree family from its asset files so the screenshot shows real
/// text.
Future<void> _loadFigtree() async {
  final loader = FontLoader('Figtree');
  for (final path in const [
    'assets/fonts/figtree/Figtree-Regular.ttf',
    'assets/fonts/figtree/Figtree-Medium.ttf',
    'assets/fonts/figtree/Figtree-SemiBold.ttf',
    'assets/fonts/figtree/Figtree-Bold.ttf',
  ]) {
    final bytes = File(path).readAsBytesSync();
    loader.addFont(
      Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)),
    );
  }
  await loader.load();
}

void main() {
  testWidgets('generate App Store add-on review screenshot', (tester) async {
    await _loadFigtree();

    // Render at a Mac window size (Apple accepts a desktop capture for the
    // IAP review screenshot — it just has to show the purchase screen).
    const logical = Size(1000, 720);
    tester.view.physicalSize = const Size(2000, 1440);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final scheme = ColourSchemeData(
      themeColor: const ThemeColor.defaultColor(),
      brightness: Brightness.light,
    );

    // Mirrors what BuyAddonCommand shows via ConfirmModal on the App Store: a
    // SelectModal<bool> with the real SubscriptionDisclosure as its subtitle.
    // On the App Store the add-on modal is only ever reached for a premium
    // connector (LinkedIn / Instagram / WhatsApp — the connectors the
    // addon_1/2/3 products exist for), so it leads with "<connector> requires a
    // connection add-on.", labels the button "Purchase a connection add-on", and
    // shows no Cancel row (showCancel: false — dismiss via Esc / X).
    final modal = SelectModal<bool>(
      showFilter: false,
      title: 'Add a connection add-on',
      subtitleWidget: const SubscriptionDisclosure(
        priceLine: r'Connection add-on — $5/month',
        note: 'LinkedIn requires a connection add-on. It is billed separately '
            "from your plan and does not count toward your plan's connection "
            'limit.',
      ),
      selectedValue: true,
      initialItems: [
        SelectGroup<bool>(items: const [true]),
      ],
      items: (_) async => [
        SelectGroup<bool>(items: const [true]),
      ],
      itemBuilder: (value, _) => ListTile(
        title: 'Purchase a connection add-on',
      ),
    );

    final boundaryKey = GlobalKey();

    await tester.pumpWidget(
      Provider<ColourSchemeData>.value(
        value: scheme,
        child: Builder(
          builder: (context) => FTheme(
            data: buildTheme(context, scheme),
            child: MediaQuery(
              data: const MediaQueryData(size: logical),
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: ModalProvider(
                  child: RepaintBoundary(
                    key: boundaryKey,
                    child: Container(
                      width: logical.width,
                      height: logical.height,
                      color: const Color(0xFFE9E9EC),
                      alignment: Alignment.center,
                      child: Container(
                        width: 480,
                        decoration: BoxDecoration(
                          color: scheme.background,
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x33000000),
                              blurRadius: 32,
                              offset: Offset(0, 12),
                            ),
                          ],
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Builder(
                          builder: (inner) => modal.builder(inner),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // Bounded pumps instead of pumpAndSettle: the modal's filter-hidden branch
    // reschedules a focus-request post-frame callback every build on platforms
    // with a physical keyboard (macOS host), so pumpAndSettle never settles.
    // A few fixed frames are enough to lay out the synchronously-provided
    // initialItems and the disclosure.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Assert the NEW purchase copy is on screen, so this harness verifies
    // correctness even when the PNG raster path is flaky in headless CI.
    expect(find.text('Add a connection add-on'), findsOneWidget);
    expect(find.text(r'Connection add-on — $5/month'), findsOneWidget);
    expect(
      find.text(
        'LinkedIn requires a connection add-on. It is billed separately '
        "from your plan and does not count toward your plan's connection "
        'limit.',
      ),
      findsOneWidget,
    );
    expect(find.text('Purchase a connection add-on'), findsOneWidget);
    // No Cancel row (showCancel: false) — the user dismisses via Esc / X.
    expect(find.text('Cancel'), findsNothing);
    expect(find.textContaining('auto-renew'), findsOneWidget);
    expect(find.text('Terms of Service'), findsOneWidget);
    expect(find.text('Privacy Policy'), findsOneWidget);
    // The OLD copy must be gone.
    expect(find.text(r'Add for $5/month'), findsNothing);
    expect(find.textContaining('bill on top of your plan'), findsNothing);
    expect(
      find.textContaining('counts as one of your plan connections'),
      findsNothing,
    );

    final boundary =
        boundaryKey.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    expect(bytes, isNotNull);

    final out = File(
      'docs/app-store/screenshots/addon-connection-review.png',
    );
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(bytes!.buffer.asUint8List());
    expect(out.lengthSync(), greaterThan(0));
    // ignore: avoid_print
    print('Wrote review screenshot: ${out.absolute.path}');

    // Dispose the widget tree so the modal's State.dispose runs (disposing its
    // focus node / controllers) and the test terminates cleanly instead of
    // hanging on the rescheduled focus callback.
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
