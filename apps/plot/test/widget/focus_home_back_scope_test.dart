import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/util/profile_preferences.dart';
import 'package:plot/widget/priorities_shell.dart';

/// [FocusHomeBackScope] makes the Android back gesture exit the app from the
/// Focus home tab (the back target every other tab and the priority feed
/// return to). Without it, an offstage `PopScope(canPop: false)` kept alive in
/// the bottom-nav [IndexedStack] leaves `setFrameworkHandlesBack(true)`, so the
/// system back is swallowed into a no-op haptic instead of backgrounding the
/// app. Single-panel only — multi-panel (desktop) has no Android back gesture
/// and must pass through untouched.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ProfilePreferences.init();
  });

  Future<void> pumpScope(WidgetTester tester, {required double width}) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: width,
            height: 600,
            child: LayoutStateProvider(
              child: const FocusHomeBackScope(child: SizedBox.expand()),
            ),
          ),
        ),
      ),
    );
    // Let LayoutStateProvider's LayoutBuilder push the measured width into
    // LayoutBloc and the BlocBuilder rebuild with the resolved panel mode.
    await tester.pump();
  }

  testWidgets('single-panel: back at the Focus home exits the app', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await pumpScope(tester, width: 400);

    final popScope =
        tester.widget(find.byWidgetPredicate((w) => w is PopScope)) as PopScope;
    expect(popScope.canPop, isFalse);

    // Simulate the system back gesture being routed to this PopScope.
    popScope.onPopInvokedWithResult!(false, null);
    await tester.pump();

    expect(
      calls.where((c) => c.method == 'SystemNavigator.pop'),
      isNotEmpty,
      reason: 'Focus-home back should background the app via SystemNavigator',
    );
  });

  testWidgets('single-panel: a real pop is left alone (no double exit)', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await pumpScope(tester, width: 400);

    final popScope =
        tester.widget(find.byWidgetPredicate((w) => w is PopScope)) as PopScope;
    // didPop == true means the framework already popped a route; the scope
    // must NOT also exit the app.
    popScope.onPopInvokedWithResult!(true, null);
    await tester.pump();

    expect(calls.where((c) => c.method == 'SystemNavigator.pop'), isEmpty);
  });

  testWidgets('multi-panel: passes through without intercepting back', (
    tester,
  ) async {
    await pumpScope(tester, width: 1400);
    expect(find.byWidgetPredicate((w) => w is PopScope), findsNothing);
  });
}
