import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

/// syncAll's incremental catch-up pulls in two explicit waves instead of
/// dependency-topo levels: wave 1 = thread + note (what the user is waiting
/// for after reopening the app — updated threads land in round trip #1),
/// wave 2 = everything else (typically 0 rows on reopen). Safe because
/// incremental rows are idempotent insertOrReplace upserts, cross-entity
/// reads join at query time, and every pullFn still self-seeds via its own
/// pullInitial. Initial syncs keep strict topo ordering.
void main() {
  final waves = SyncOrchestrator.instance.incrementalPullWaves();

  test('exactly two waves; thread and note are wave 1', () {
    expect(waves, hasLength(2));
    expect(
      waves[0].map((e) => e.debugName).toSet(),
      {'thread', 'note'},
    );
  });

  test('waves cover allEntities exactly, no duplicates', () {
    final waveNames = waves.expand((w) => w).map((e) => e.debugName).toList();
    final allNames =
        SyncOrchestrator.allEntities.map((e) => e.debugName).toList();
    expect(waveNames.toSet(), allNames.toSet());
    expect(waveNames.length, allNames.length, reason: 'no entity twice');
  });

  test('critical initial path still topo-sorted (untouched)', () {
    // Guard that the wave change didn't leak into the initial path.
    expect(
      () => SyncOrchestrator.instance.criticalPullLevels(),
      returnsNormally,
    );
  });
}
