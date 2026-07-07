import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/sync_catchup_stats.dart';

void main() {
  test('accumulates pulls, waves and totals into event props', () {
    final stats = SyncCatchupStats('resume');
    stats.recordPull('threads', 120, 2, 350);
    stats.recordPull('notes', 90, 1, 40);
    stats.recordPull('links', 80, 1, 12);
    stats.recordWave(0, 150);
    stats.recordWave(1, 60);

    final props = stats.finish();
    expect(props['trigger'], 'resume');
    expect(props['ok'], isTrue);
    expect(props['threads_ms'], 120);
    expect(props['notes_ms'], 90);
    expect(props['wave1_ms'], 150);
    expect(props['wave2_ms'], 60);
    expect(props['requests'], 4); // one per page
    expect(props['pages'], 4);
    expect(props['rows_total'], 402);
    expect(props['total_ms'], isA<int>());
  });

  test('ok is true by default and flips false once marked failed', () {
    final stats = SyncCatchupStats('resync');
    expect(stats.finish()['ok'], isTrue);

    stats.failed = true;
    expect(stats.finish()['ok'], isFalse);
  });

  test('current is null outside a catch-up window', () {
    expect(SyncCatchupStats.current, isNull);
  });
}
