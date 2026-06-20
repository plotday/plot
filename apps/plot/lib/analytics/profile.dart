/// Per-user analytics profile: counts pushed as PostHog person properties.
///
/// These answer "how many roles / focuses / connectors does a user have" and —
/// by breaking down on `connectors` — "how many users have each connector".
/// They're per-user *state*, not clicks, so they live on the person profile via
/// `$set` rather than as events.
library;

import 'package:logging/logging.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/store/store.dart';

final _log = Logger('AnalyticsProfile');

bool _refreshedThisSession = false;

/// One-shot baseline refresh, run the first time the stores are known to be
/// populated (after the first full sync). Does NOT consume its flag until the
/// user is actually identified, so a sync that races ahead of sign-in doesn't
/// swallow the baseline. Within-session changes are handled by explicit
/// [refreshUserAnalyticsProfile] calls from the create/connect commands.
Future<void> refreshUserAnalyticsProfileOnce() async {
  if (_refreshedThisSession || !Base.signedIn) return;
  _refreshedThisSession = true;
  await refreshUserAnalyticsProfile();
}

/// Mark the per-session baseline stale so the next [refreshUserAnalyticsProfileOnce]
/// (after the next sync, by which point the change has synced into the stores)
/// recomputes the counts. Call after a change that affects them — connect, role
/// create, focus create. Cheaper and more reliable than recomputing inline at
/// the mutation site, which may run before the new row reaches the local store.
void markUserAnalyticsProfileStale() {
  _refreshedThisSession = false;
}

/// Recompute the per-user counts from the local stores and set them as person
/// properties. Recompute-from-store is idempotent, so it's safe to call after
/// any create/archive/connect, and at startup once the user is identified.
///
/// Best-effort: any failure is logged and swallowed so analytics never breaks
/// an app flow.
Future<void> refreshUserAnalyticsProfile() async {
  if (!Base.signedIn) return;
  try {
    final roles = await Role.all(archived: false);
    final priorities = await Priority.getRaw(archived: false);
    // Focuses are priorities excluding the server-managed Inbox/FYI.
    final focusCount = priorities
        .where((p) => !p.isInbox && !p.isFyi)
        .length;
    final connections = (await TwistInstance.get(archived: false))
        .where((t) => t.isSource)
        .toList();
    final connectorNames = connections.map((t) => t.name).toSet().toList()
      ..sort();

    await Tracker.setPersonProperties({
      'role_count': roles.length,
      'focus_count': focusCount,
      'connector_count': connections.length,
      'connectors': connectorNames,
    });
  } catch (e, stackTrace) {
    // Expected to occasionally fail during startup/teardown when stores aren't
    // ready; best-effort analytics, so log without reporting to error tracking.
    _log.warning('Failed to refresh user analytics profile', e, stackTrace);
  }
}
