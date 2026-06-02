import 'package:flutter/widgets.dart';
// Material is only pulled in here to satisfy material.ReorderableListView's
// MaterialLocalizations/Overlay requirements in the test harness; the widget
// under test lives in lib/widget and is framework-agnostic.
import 'package:flutter/material.dart' show MaterialApp, Scaffold;
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/reorderable_list_view.dart';

/// Regression guard for optimistic reordering.
///
/// [ReorderableListView] keeps a private optimistic copy of the list so a drop
/// renders in its new position immediately, before the async persistence round
/// trip (e.g. a Drift `.save()` → bloc re-emit) feeds the reordered list back
/// down as a prop. The danger: an *ancestor* rebuild that fires in that window
/// (a sibling bloc emitting, a `ScrollEdgeFade` toggling its `ShaderMask`, …)
/// re-passes the still-stale pre-save order. If `didUpdateWidget` blindly
/// adopts every incoming list, that stale echo clobbers the optimistic order
/// and the dropped row visibly flashes back to where it started before the
/// save lands and settles it again.
///
/// These tests pin the contract: while a local reorder is in flight, a parent
/// rebuild carrying the *old* order must NOT revert the optimistic arrangement.
void main() {
  // The test host reports a physical keyboard (desktop), so rows use an
  // immediate ReorderableDragStartListener — a plain pointer drag drives the
  // material reorder callback path (`onReorderItem` → optimistic `setState` →
  // `widget.onReorder`), which is the code under test.
  group('ReorderableListView optimistic reorder', () {
    testWidgets(
        'keeps the optimistic order when a parent rebuild re-passes the '
        'stale pre-save list', (tester) async {
      await tester.pumpWidget(const _Harness());

      expect(_rowOrder(tester), ['A', 'B', 'C']);

      // Drag A down past B. The state's onReorderItem updates the optimistic
      // copy and then invokes onReorder, which (faithful to the app) triggers
      // an ancestor rebuild WITHOUT yet mutating the source list — simulating
      // the gap before the async save propagates.
      await _dragDown(tester, 'A');

      // The optimistic order must hold: A landed after B. Before the fix the
      // stale parent rebuild reverted this to ['A', 'B', 'C'].
      expect(_rowOrder(tester), ['B', 'A', 'C']);
    });

    testWidgets('adopts the persisted order once the save propagates',
        (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key));

      await _dragDown(tester, 'A');
      expect(_rowOrder(tester), ['B', 'A', 'C']);

      // The save lands: the source now matches the optimistic order. The
      // widget should keep showing it (and stop guarding) without a flash.
      key.currentState!.commit(['B', 'A', 'C']);
      await tester.pump();
      expect(_rowOrder(tester), ['B', 'A', 'C']);
    });

    testWidgets('reflects a genuine external reorder pushed from the parent',
        (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key));

      // No local drag in flight — a reorder arriving purely from the parent
      // (e.g. another device) must be adopted.
      key.currentState!.commit(['C', 'B', 'A']);
      await tester.pump();
      expect(_rowOrder(tester), ['C', 'B', 'A']);
    });

    testWidgets('adopts membership changes even while a reorder is in flight',
        (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key));

      await _dragDown(tester, 'A');
      expect(_rowOrder(tester), ['B', 'A', 'C']);

      // A new item appears before the save echoes back. Membership changed, so
      // the optimistic guard must yield rather than strand the new element.
      key.currentState!.commit(['A', 'B', 'C', 'D']);
      await tester.pump();
      expect(_rowOrder(tester).toSet(), {'A', 'B', 'C', 'D'});
    });
  });
}

const double _rowHeight = 60;

List<String> _rowOrder(WidgetTester tester) {
  final rows = tester.widgetList<_Row>(find.byType(_Row)).toList();
  rows.sort((a, b) {
    final ay = tester.getTopLeft(find.byKey(ValueKey('row-${a.label}'))).dy;
    final by = tester.getTopLeft(find.byKey(ValueKey('row-${b.label}'))).dy;
    return ay.compareTo(by);
  });
  return rows.map((r) => r.label).toList();
}

/// Reorders [label] one slot downward through the material reorder callback,
/// mirroring a drop, then settles the implicit reorder animation.
Future<void> _dragDown(WidgetTester tester, String label) async {
  final start = tester.getCenter(find.byKey(ValueKey('row-$label')));
  final gesture = await tester.startGesture(start);
  // Desktop drag start is immediate (ReorderableDragStartListener); move past
  // the next row so material commits the reorder on release.
  await tester.pump();
  await gesture.moveBy(const Offset(0, _rowHeight * 0.6));
  await tester.pump();
  await gesture.moveBy(const Offset(0, _rowHeight * 0.6));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

/// Host that owns the source list and, on reorder, rebuilds WITHOUT mutating it
/// — the exact window where a stale ancestor rebuild used to clobber the
/// optimistic order. [commit] models the save finally propagating.
class _Harness extends StatefulWidget {
  const _Harness({super.key});

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  List<String> _source = ['A', 'B', 'C'];

  void commit(List<String> next) => setState(() => _source = next);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            height: _rowHeight * 6,
            width: 300,
            // Fresh list instance every build, exactly like the app rebuilds
            // `focuses` in PrioritiesList — so `widget.list != oldWidget.list`
            // is always true and the optimistic guard is actually exercised.
            child: ReorderableListView<String>(
              list: [..._source],
              keyExtractor: (s) => ValueKey(s),
              itemBuilder: (context, item, index) => _Row(label: item),
              onReorder: (oldIndex, newIndex) {
                // Faithful to the app: the save is async, so the source is NOT
                // updated synchronously here. We only force an ancestor
                // rebuild, which re-passes the still-stale order down.
                setState(() {});
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: ValueKey('row-$label'),
      height: _rowHeight,
      child: Text(label),
    );
  }
}
