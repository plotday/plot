import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

/// Catch-up seq pulls use a 500-row page (server MAX_LIMIT is 1000) to cut
/// page-loop round trips after a long absence. Everything else — on-demand
/// feed/agenda slices, per-thread pulls — keeps the 200 default.
void main() {
  test('catch-up constant', () {
    expect(kCatchUpPageLimit, 500);
  });

  test('opt-in limit on high-churn Base classes', () {
    expect(ThreadsBase(limit: kCatchUpPageLimit).limit, 500);
    expect(LinksBase(limit: kCatchUpPageLimit).limit, 500);
    expect(SchedulesBase(limit: kCatchUpPageLimit).limit, 500);
    expect(ThreadTagsBase(limit: kCatchUpPageLimit).limit, 500);
    expect(NotesBase(limit: kCatchUpPageLimit).limit, 500);
    expect(NoteTagsBase(limit: kCatchUpPageLimit).limit, 500);
  });

  test('defaults unchanged', () {
    expect(ThreadsBase().limit, 200);
    expect(ThreadsBase(initial: true).limit, isNull); // unbounded initial
    expect(LinksBase().limit, 200);
    expect(NotesBase().limit, 200);
  });
}
