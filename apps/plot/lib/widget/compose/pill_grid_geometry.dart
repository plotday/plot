// apps/plot/lib/widget/compose/pill_grid_geometry.dart
import 'package:flutter/widgets.dart';

/// Pure 2D-grid navigation over pill rectangles laid out (wrapped) in reading
/// order. Rects are in a shared content-space; index order == reading order.
///
/// `horizontal` walks reading order (clamped). `vertical` moves between visual
/// rows, choosing the pill in the adjacent row whose horizontal centre is
/// nearest. `vertical(_, -1)` past the first row returns [toSearchBar] so the
/// view can hand focus back to the search field; `vertical(_, 1)` past the last
/// row returns the same index (stay).
class PillGridGeometry {
  PillGridGeometry(this.rects);

  final List<Rect> rects;

  /// Sentinel returned by [vertical] when moving up past the first row.
  static const int toSearchBar = -1;

  /// Two rects share a row when their vertical centres are within half the
  /// smaller height.
  bool _sameRow(Rect a, Rect b) =>
      (a.center.dy - b.center.dy).abs() <
      (a.height < b.height ? a.height : b.height) / 2;

  int horizontal(int from, int delta) {
    if (rects.isEmpty) return 0;
    return (from + delta).clamp(0, rects.length - 1);
  }

  int vertical(int from, int dy) {
    if (rects.isEmpty || from < 0 || from >= rects.length) {
      return dy < 0 ? toSearchBar : (rects.isEmpty ? 0 : from);
    }
    final cur = rects[from];
    // Candidate pills strictly above (dy<0) or below (dy>0) the current row.
    final candidates = <int>[];
    for (var i = 0; i < rects.length; i++) {
      if (i == from) continue;
      final r = rects[i];
      if (_sameRow(r, cur)) continue;
      final below = r.center.dy > cur.center.dy;
      if (dy > 0 && below) candidates.add(i);
      if (dy < 0 && !below) candidates.add(i);
    }
    if (candidates.isEmpty) return dy < 0 ? toSearchBar : from;
    // Nearest adjacent row: min vertical distance to current centre. The
    // `cur.height / 2` row-membership epsilon below assumes near-uniform pill
    // heights (true for this UI); revisit if variable-height rows are added.
    double rowKey(int i) => (rects[i].center.dy - cur.center.dy).abs();
    final nearestRowDy = candidates.map(rowKey).reduce((a, b) => a < b ? a : b);
    final inRow = candidates
        .where((i) => (rowKey(i) - nearestRowDy).abs() < cur.height / 2)
        .toList();
    // Within that row, nearest by horizontal centre.
    inRow.sort((a, b) => (rects[a].center.dx - cur.center.dx)
        .abs()
        .compareTo((rects[b].center.dx - cur.center.dx).abs()));
    return inRow.first;
  }
}
