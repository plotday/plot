import 'package:flutter/foundation.dart';
import 'package:plot/state/agenda_model.dart';
import 'package:plot/store/store.dart';

/// Whether the swipe-between-threads carousel should be used.
///
/// Touch-only: native iOS and Android. Web (even on a mobile device) and
/// desktop keep keyboard arrows / clicks and render the single thread view.
bool shouldUseThreadCarousel({
  required bool isWeb,
  required TargetPlatform platform,
}) {
  if (isWeb) return false;
  return platform == TargetPlatform.iOS ||
      platform == TargetPlatform.android;
}

/// Extracts the [Thread] from an [AgendaItem], or null for headers / null.
Thread? threadFromAgendaItem(AgendaItem? item) {
  if (item == null) return null;
  return item.when<Thread?>(
    header: (_) => null,
    activity: (a) => a.thread,
  );
}

/// The feed's threads in display order, headers dropped — the list the swipe
/// carousel pages through. Adjacency in this list matches the next/previous
/// thread the keyboard arrows navigate to.
List<Thread> feedThreads(List<AgendaItem> items) => [
      for (final item in items) ?threadFromAgendaItem(item),
    ];
