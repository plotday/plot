import 'package:equatable/equatable.dart';
import 'package:flutter/widgets.dart';

import 'package:plot/api/api.dart' as api;
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/logging.dart';
import 'package:plot/main.dart' show navigatorKey;
import 'package:plot/store/store.dart';
import 'package:plot/widget/toast.dart';
import 'subscription_plan.dart';

/// Immutable view of the current user's subscription/usage/team state.
class SubscriptionSnapshot extends Equatable {
  final SubscriptionInfo? subscription;
  final UsageData? usage;
  final List<Map<String, dynamic>> adminOrgs;
  final bool hasTeams;

  const SubscriptionSnapshot({
    this.subscription,
    this.usage,
    this.adminOrgs = const [],
    this.hasTeams = false,
  });

  @override
  List<Object?> get props => [subscription, usage, adminOrgs, hasTeams];
}

typedef SubscriptionFetcher = Future<SubscriptionInfo> Function();
typedef UsageFetcher = Future<UsageData> Function();
typedef TeamsFetcher = Future<List<Map<String, dynamic>>> Function();
typedef ToastSink = void Function(String message);

/// App-wide source of truth for subscription + usage state.
///
/// Refreshed on websocket broadcast, websocket reconnect, and app refocus.
/// Consumers listen to [notifier]; the onboarding gate awaits [ensureFresh]
/// before deciding whether to show the upgrade picker. A plan increase
/// detected on refocus surfaces a one-off success toast.
class SubscriptionService with WidgetsBindingObserver {
  SubscriptionService({
    required SubscriptionFetcher fetchSubscription,
    required UsageFetcher fetchUsage,
    required TeamsFetcher fetchTeams,
    required ToastSink showToast,
  })  : _fetchSubscription = fetchSubscription, // ignore: prefer_initializing_formals
        _fetchUsage = fetchUsage, // ignore: prefer_initializing_formals
        _fetchTeams = fetchTeams, // ignore: prefer_initializing_formals
        _showToast = showToast; // ignore: prefer_initializing_formals

  static SubscriptionService? _instance;
  static SubscriptionService get instance => _instance ??= SubscriptionService(
        fetchSubscription: UpgradeApi.getSubscription,
        fetchUsage: UpgradeApi.getUsage,
        fetchTeams: _defaultFetchTeams,
        showToast: _defaultShowToast,
      );

  final SubscriptionFetcher _fetchSubscription;
  final UsageFetcher _fetchUsage;
  final TeamsFetcher _fetchTeams;
  final ToastSink _showToast;

  final ValueNotifier<SubscriptionSnapshot> notifier =
      ValueNotifier<SubscriptionSnapshot>(const SubscriptionSnapshot());

  Future<void>? _inFlight;
  int _generation = 0;
  bool _baselineInitialized = false;
  int _acknowledgedRank = 0;
  bool _started = false;

  SubscriptionInfo? get subscription => notifier.value.subscription;
  UsageData? get usage => notifier.value.usage;

  /// Wire app-level triggers and load the initial snapshot. Idempotent.
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    Store.get.onSubscriptionChanged = refresh;
    refresh();
  }

  /// Tear down on sign-out so a fresh sign-in re-baselines.
  void reset() {
    // Invalidate any in-flight refresh so its result can't repopulate the
    // snapshot/baseline for a now-signed-out (or about-to-change) user.
    _generation++;
    if (_started) {
      WidgetsBinding.instance.removeObserver(this);
      Store.get.onSubscriptionChanged = null;
    }
    _started = false;
    notifier.value = const SubscriptionSnapshot();
    _baselineInitialized = false;
    _acknowledgedRank = 0;
    _inFlight = null;
  }

  /// Refetch subscription + usage + teams, coalescing concurrent callers.
  Future<void> refresh() {
    final existing = _inFlight;
    if (existing != null) return existing;
    final future = _doRefresh();
    _inFlight = future;
    // Only clear the slot if it still points at THIS future — a refresh that
    // was superseded by reset()+a new refresh() must not clobber the new one.
    future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
    return future;
  }

  /// Awaitable refresh used before gating decisions.
  Future<void> ensureFresh() => refresh();

  Future<void> _doRefresh() async {
    final generation = _generation;
    try {
      final results = await Future.wait([
        _fetchSubscription(),
        _fetchUsage(),
        _fetchTeams(),
      ]);
      // reset() (e.g. sign-out) ran while this was in flight — discard so we
      // don't repopulate the snapshot/baseline for a stale user.
      if (generation != _generation) return;
      final sub = results[0] as SubscriptionInfo;
      final usage = results[1] as UsageData;
      final orgs = results[2] as List<Map<String, dynamic>>;
      notifier.value = SubscriptionSnapshot(
        subscription: sub,
        usage: usage,
        adminOrgs: orgs.where((o) => o['role'] == 'admin').toList(),
        hasTeams: orgs.isNotEmpty,
      );
      if (!_baselineInitialized) {
        _acknowledgedRank = planRank(sub.effectivePlan);
        _baselineInitialized = true;
      }
    } catch (e, st) {
      // Best-effort: keep the last good snapshot. Consumers fall back to their
      // own backstops (AddSourceDetail re-fetches usage on run). Logged (not
      // PostHog-captured) since failures here are usually expected network /
      // auth blips on app resume.
      log.warning('Subscription refresh failed', e, st);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      handleAppResumed();
    }
  }

  /// Refresh on refocus and toast if the plan went up since last acknowledged.
  Future<void> handleAppResumed() async {
    final wasInitialized = _baselineInitialized;
    await refresh();
    if (!wasInitialized) return; // first-ever successful load — no toast
    final plan = notifier.value.subscription?.effectivePlan;
    if (plan == null) return;
    final newRank = planRank(plan);
    final message = planUpToastMessage(
      prevRank: _acknowledgedRank,
      newRank: newRank,
      newEffectivePlan: plan,
    );
    _acknowledgedRank = newRank; // ack even on downgrade (silent)
    if (message != null) _showToast(message);
  }

  /// Mark the current plan as already acknowledged so the next refocus does
  /// not re-toast it. Called after an inline IAP purchase shows its own toast.
  void acknowledgeBaseline() {
    final plan = notifier.value.subscription?.effectivePlan;
    if (plan != null) {
      _acknowledgedRank = planRank(plan);
      _baselineInitialized = true;
    }
  }
}

Future<List<Map<String, dynamic>>> _defaultFetchTeams() async {
  final response = await api.get<List<dynamic>>('/team');
  return response.cast<Map<String, dynamic>>();
}

void _defaultShowToast(String message) {
  final context = navigatorKey?.currentContext;
  if (context == null) return;
  context.showToast(message: message);
}
