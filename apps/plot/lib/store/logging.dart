import 'package:logging/logging.dart';

final Logger log = Logger('plot.store');

/// Enables verbose sync perf logging (per-entity pull/push timings, syncAll
/// level breakdowns, app-resume catch-up trigger). Off by default — pass
/// `--dart-define=SYNC_PERF_LOG=true` when profiling sync.
const bool syncPerfLog = bool.fromEnvironment('SYNC_PERF_LOG');
