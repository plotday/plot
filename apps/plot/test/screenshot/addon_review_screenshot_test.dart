/// Generates the App Store review screenshot for the connection add-on
/// subscriptions. Renders the REAL purchase confirmation — the `SelectModal`
/// that `BuyAddonCommand` shows, with the real `SubscriptionDisclosure`
/// (price + auto-renew + Terms/Privacy) — into a PNG.
///
/// Run: `flutter test test/screenshot/addon_review_screenshot_test.dart`
/// Output: `build/app_store/addon_review.png` (upload to all three add-on
/// products in App Store Connect — Apple wants the in-app purchase screen,
/// not its own StoreKit sheet). Rerun whenever the copy or price changes.
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
import 'package:plot/style/plot_colors.dart';
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

    // The same SelectModal BuyAddonCommand._pickAddonCount shows: the quantity
    // picker (0–3) with the real disclosure subtitle. Prices are hardcoded to
    // the US amounts here (the live app reads localized prices from StoreKit).
    const current = 0;
    const prices = {1: '\$6.99', 2: '\$12.99', 3: '\$17.99'};
    final modal = SelectModal<int>(
      showFilter: false,
      title: 'Connection add-ons',
      subtitleWidget: const SubscriptionDisclosure(
        note:
            'Connection add-ons are provided by a third party and bill on top '
            'of your plan. Each also counts as one of your plan connections.',
      ),
      selectedValue: current,
      initialItems: [
        SelectGroup<int>(items: const [0, 1, 2, 3]),
      ],
      items: (_) async => [
        SelectGroup<int>(items: const [0, 1, 2, 3]),
      ],
      itemBuilder: (count, _) => Builder(
        builder: (context) {
          final muted = context.theme.typography.sm.copyWith(
            color: context.theme.plotColors.muted,
          );
          if (count == 0) {
            return ListTile(
              title: 'None',
              details: Text(
                count == current ? 'Current' : 'Cancel in App Store settings',
                style: muted,
              ),
            );
          }
          return ListTile(
            title:
                '$count connection add-on${count == 1 ? '' : 's'} — '
                '${prices[count]}/month',
            details: count == current ? Text('Current', style: muted) : null,
          );
        },
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
    await tester.pumpAndSettle();

    final boundary =
        boundaryKey.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    expect(bytes, isNotNull);

    final out = File('build/app_store/addon_review.png');
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(bytes!.buffer.asUint8List());
    expect(out.lengthSync(), greaterThan(0));
    // ignore: avoid_print
    print('Wrote review screenshot: ${out.absolute.path}');
  });
}
