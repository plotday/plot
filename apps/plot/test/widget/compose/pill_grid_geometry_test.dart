// apps/plot/test/widget/compose/pill_grid_geometry_test.dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/compose/pill_grid_geometry.dart';

void main() {
  // Two rows: row 0 = indices 0,1,2 (y=0,h=30); row 1 = indices 3,4 (y=40,h=30).
  // x layout: 0:[0,40] 1:[50,90] 2:[100,140]  3:[0,40] 4:[50,90]
  Rect r(double x, double y, double w) => Rect.fromLTWH(x, y, w, 30);
  final rects = <Rect>[
    r(0, 0, 40), r(50, 0, 40), r(100, 0, 40), // row 0
    r(0, 40, 40), r(50, 40, 40), // row 1
  ];
  final g = PillGridGeometry(rects);

  test('horizontal moves clamp at ends', () {
    expect(g.horizontal(0, -1), 0); // already first
    expect(g.horizontal(0, 1), 1);
    expect(g.horizontal(2, 1), 3); // next reading-order index, across the row boundary
    expect(g.horizontal(4, 1), 4); // already last
  });

  test('down picks nearest pill in next row by centre-x', () {
    // index 0 centre-x = 20 -> next row nearest is index 3 (centre-x 20)
    expect(g.vertical(0, 1), 3);
    // index 2 centre-x = 120 -> next row only has 3(20),4(70); nearest is 4
    expect(g.vertical(2, 1), 4);
  });

  test('down from last row stays put', () {
    expect(g.vertical(3, 1), 3);
    expect(g.vertical(4, 1), 4);
  });

  test('up picks nearest pill in previous row by centre-x', () {
    expect(g.vertical(3, -1), 0); // centre-x 20 -> index 0
    expect(g.vertical(4, -1), 1); // centre-x 70 -> index 1 (centre 70)
  });

  test('up from top row returns -1 sentinel (focus search bar)', () {
    expect(g.vertical(0, -1), PillGridGeometry.toSearchBar);
    expect(g.vertical(2, -1), PillGridGeometry.toSearchBar);
  });

  test('empty geometry is safe', () {
    final e = PillGridGeometry(const []);
    expect(e.horizontal(0, 1), 0);
    expect(e.vertical(0, 1), 0);
    expect(e.vertical(0, -1), PillGridGeometry.toSearchBar);
  });
}
