import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/state/subscription_service.dart';

SubscriptionInfo _sub(String plan) => SubscriptionInfo(
      plan: plan,
      effectivePlan: plan,
      effectiveSource: 'personal',
    );

UsageData _usage({List<TeamUsage> teams = const []}) => UsageData(
      personal: const PersonalUsage(
        connections: ResourceUsage(count: 0, limit: 2),
        twists: ResourceUsage(count: 0, limit: 2),
      ),
      teams: teams,
    );

void main() {
  group('SubscriptionService', () {
    test('refresh fans the latest snapshot into the notifier', () async {
      var plan = 'free';
      final svc = SubscriptionService(
        fetchSubscription: () async => _sub(plan),
        fetchUsage: () async => _usage(),
        fetchTeams: () async => const [],
        showToast: (_) {},
      );
      await svc.refresh();
      expect(svc.notifier.value.subscription?.effectivePlan, 'free');
      expect(svc.notifier.value.hasTeams, false);

      plan = 'pro';
      await svc.refresh();
      expect(svc.notifier.value.subscription?.effectivePlan, 'pro');
    });

    test('coalesces concurrent refreshes into one round-trip', () async {
      var calls = 0;
      final svc = SubscriptionService(
        fetchSubscription: () async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return _sub('free');
        },
        fetchUsage: () async => _usage(),
        fetchTeams: () async => const [],
        showToast: (_) {},
      );
      await Future.wait([svc.refresh(), svc.refresh(), svc.refresh()]);
      expect(calls, 1);
    });

    test('derives hasTeams from the team payload', () async {
      final svc = SubscriptionService(
        fetchSubscription: () async => _sub('free'),
        fetchUsage: () async => _usage(),
        fetchTeams: () async => [
          {'id': 't1', 'role': 'admin'},
          {'id': 't2', 'role': 'member'},
        ],
        showToast: (_) {},
      );
      await svc.refresh();
      expect(svc.notifier.value.hasTeams, true);
    });

    test('first load sets the baseline so resume does not toast it', () async {
      final toasts = <String>[];
      final svc = SubscriptionService(
        fetchSubscription: () async => _sub('pro'),
        fetchUsage: () async => _usage(),
        fetchTeams: () async => const [],
        showToast: toasts.add,
      );
      await svc.refresh(); // baseline := pro
      await svc.handleAppResumed(); // pro == pro, no toast
      expect(toasts, isEmpty);
    });

    test('resume toasts when the plan increased while backgrounded', () async {
      final toasts = <String>[];
      var plan = 'free';
      final svc = SubscriptionService(
        fetchSubscription: () async => _sub(plan),
        fetchUsage: () async => _usage(),
        fetchTeams: () async => const [],
        showToast: toasts.add,
      );
      await svc.refresh(); // baseline := free
      plan = 'pro'; // upgraded in the browser
      await svc.handleAppResumed();
      expect(toasts, ["You're now on Plot Pro"]);
      // Acknowledged now — a second resume with no further change is silent.
      await svc.handleAppResumed();
      expect(toasts.length, 1);
    });

    test('team membership toasts with neutral wording', () async {
      final toasts = <String>[];
      var plan = 'free';
      final svc = SubscriptionService(
        fetchSubscription: () async => _sub(plan),
        fetchUsage: () async => _usage(),
        fetchTeams: () async => const [],
        showToast: toasts.add,
      );
      await svc.refresh();
      plan = 'team';
      await svc.handleAppResumed();
      expect(toasts, ['You can now add more connections']);
    });

    test('acknowledgeBaseline suppresses a later resume toast (IAP path)',
        () async {
      final toasts = <String>[];
      var plan = 'free';
      final svc = SubscriptionService(
        fetchSubscription: () async => _sub(plan),
        fetchUsage: () async => _usage(),
        fetchTeams: () async => const [],
        showToast: toasts.add,
      );
      await svc.refresh(); // baseline := free
      plan = 'pro';
      await svc.refresh(); // simulate IAP-driven refresh (no toast)
      svc.acknowledgeBaseline(); // IAP already showed its own toast
      await svc.handleAppResumed();
      expect(toasts, isEmpty);
    });

    test('reset clears the snapshot and baseline', () async {
      final toasts = <String>[];
      var plan = 'pro';
      final svc = SubscriptionService(
        fetchSubscription: () async => _sub(plan),
        fetchUsage: () async => _usage(),
        fetchTeams: () async => const [],
        showToast: toasts.add,
      );
      await svc.refresh();
      svc.reset();
      expect(svc.notifier.value.subscription, isNull);
      await svc.refresh();
      await svc.handleAppResumed();
      expect(toasts, isEmpty);
    });

    test('a refresh in flight when reset() is called does not repopulate state',
        () async {
      final gate = Completer<SubscriptionInfo>();
      final svc = SubscriptionService(
        fetchSubscription: () => gate.future,
        fetchUsage: () async => _usage(),
        fetchTeams: () async => const [],
        showToast: (_) {},
      );
      final pending = svc.refresh(); // starts, blocks on the completer
      svc.reset(); // sign-out mid-flight
      gate.complete(_sub('pro')); // the stale fetch now finishes
      await pending;
      // The stale result must be discarded — snapshot stays cleared.
      expect(svc.notifier.value.subscription, isNull);
    });
  });
}
