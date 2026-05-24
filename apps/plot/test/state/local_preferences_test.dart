import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/state/local_preferences.dart';
import 'package:plot/util/profile_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ProfilePreferences.init();
  });

  group('LocalPreferencesBloc connection MRU', () {
    test('records per-priority usage and ranks priority-recency first',
        () async {
      final bloc = LocalPreferencesBloc();
      // Ensure async constructor load has settled.
      await Future<void>.delayed(Duration.zero);

      // Use B once globally, A once in priority p1.
      await bloc.recordConnectionUsage(channelKey: 'B', priorityId: 'pX');
      await bloc.recordConnectionUsage(channelKey: 'A', priorityId: 'p1');

      // Rank for p1: A (priority match) before B (global only).
      final ranked = bloc.rankConnectionsByMru(
        keys: ['B', 'A', 'C'],
        priorityId: 'p1',
      );
      expect(ranked, ['A', 'B', 'C']);
    });

    test('within priority, most recent priority use wins', () async {
      final bloc = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);

      await bloc.recordConnectionUsage(channelKey: 'A', priorityId: 'p1');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await bloc.recordConnectionUsage(channelKey: 'B', priorityId: 'p1');

      final ranked = bloc.rankConnectionsByMru(
        keys: ['A', 'B'],
        priorityId: 'p1',
      );
      expect(ranked, ['B', 'A']);
    });

    test('persists across instances', () async {
      final bloc1 = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);
      await bloc1.recordConnectionUsage(channelKey: 'A', priorityId: 'p1');

      final bloc2 = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);

      final ranked = bloc2.rankConnectionsByMru(
        keys: ['B', 'A'],
        priorityId: 'p1',
      );
      expect(ranked, ['A', 'B']);
    });

    test('unseen keys preserve their input order', () async {
      final bloc = LocalPreferencesBloc();
      await Future<void>.delayed(Duration.zero);

      final ranked = bloc.rankConnectionsByMru(
        keys: ['Z', 'A', 'M'],
        priorityId: 'p1',
      );
      expect(ranked, ['Z', 'A', 'M']);
    });
  });
}
