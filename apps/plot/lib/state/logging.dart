import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';

import 'package:plot/analytics/analytics.dart';

final Logger log = Logger('plot.state');

class BlocLogger extends BlocObserver {
  @override
  void onChange(BlocBase<dynamic> bloc, Change<dynamic> change) {
    super.onChange(bloc, change);
    // Only log when state actually changes (not duplicates)
    if (change.currentState != change.nextState) {
      log.fine('${bloc.runtimeType}: $change');
    }
  }

  @override
  void onError(BlocBase<dynamic> bloc, Object error, StackTrace stackTrace) {
    super.onError(bloc, error, stackTrace);
    log.warning(bloc.runtimeType, error, stackTrace);

    // Track error to PostHog
    final blocName = _normalizeBlocName(bloc.runtimeType.toString());
    Analytics.instance.trackError(
      blocName,
      errorType: error.runtimeType.toString(),
      errorMessage: error.toString(),
      stackTrace: extractStackTrace(stackTrace),
      context: 'state',
    );
  }

  /// Normalize bloc names for analytics
  /// Examples:
  /// - UserBloc -> user
  /// - NowBloc -> now
  /// - PriorityBloc -> priority
  String _normalizeBlocName(String blocName) {
    // Remove "Bloc" suffix
    String name = blocName.replaceAll('Bloc', '').toLowerCase();
    return name.isEmpty ? 'bloc' : name;
  }
}
