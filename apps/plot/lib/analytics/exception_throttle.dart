/// Client-side throttling for exception reporting.
///
/// Protects PostHog Error Tracking from crash loops: when the renderer or a
/// rebuild path throws the same exception every frame (e.g. the CanvasKit
/// WASM module aborting on web), an unthrottled handler reports ~30 events
/// per second — one user produced 318K events in 3 hours. A few occurrences
/// of an issue carry all the signal; the rest is ingestion cost.
library;

/// Decides which exceptions are worth reporting.
///
/// Two layers of protection:
/// - Per fingerprint (error type + first line of its message): the first
///   [maxPerFingerprint] occurrences are admitted, after which one heartbeat
///   per [resendInterval] is admitted carrying a `suppressed_count` property
///   so the issue's true magnitude stays visible in PostHog.
/// - Global: at most [globalLimit] exceptions per [globalWindow] across all
///   fingerprints, guarding against loops whose message varies per occurrence
///   (which would defeat fingerprinting).
class ExceptionThrottle {
  static const int defaultMaxPerFingerprint = 5;
  static const Duration defaultResendInterval = Duration(minutes: 5);
  static const int defaultGlobalLimit = 20;
  static const Duration defaultGlobalWindow = Duration(minutes: 1);

  /// Bound on tracked fingerprints; the map is cleared beyond this to keep
  /// memory flat during pathological floods.
  static const int _maxTrackedFingerprints = 500;

  final int maxPerFingerprint;
  final Duration resendInterval;
  final int globalLimit;
  final Duration globalWindow;

  final Map<String, _FingerprintState> _states = {};
  DateTime? _globalWindowStart;
  int _globalCount = 0;

  ExceptionThrottle({
    this.maxPerFingerprint = defaultMaxPerFingerprint,
    this.resendInterval = defaultResendInterval,
    this.globalLimit = defaultGlobalLimit,
    this.globalWindow = defaultGlobalWindow,
  });

  /// Returns extra event properties if [error] should be reported at [now],
  /// or null if it should be suppressed.
  Map<String, int>? admit(Object error, DateTime now) {
    if (_states.length > _maxTrackedFingerprints) _states.clear();

    final state = _states.putIfAbsent(
      _fingerprint(error),
      _FingerprintState.new,
    );

    // Per-fingerprint check first so suppressed repeats don't consume the
    // global budget needed by other (possibly novel) errors.
    if (state.sent >= maxPerFingerprint &&
        (state.lastSent == null ||
            now.difference(state.lastSent!) < resendInterval)) {
      state.suppressed++;
      return null;
    }

    // Global flood check.
    if (_globalWindowStart == null ||
        now.difference(_globalWindowStart!) >= globalWindow) {
      _globalWindowStart = now;
      _globalCount = 0;
    }
    if (_globalCount >= globalLimit) {
      state.suppressed++;
      return null;
    }

    _globalCount++;
    state.sent++;
    state.lastSent = now;
    final suppressed = state.suppressed;
    state.suppressed = 0;
    return {if (suppressed > 0) 'suppressed_count': suppressed};
  }

  /// Fingerprint = runtime type + first line of the message, truncated.
  /// Matches how humans (and PostHog grouping) identify "the same error"
  /// closely enough for throttling; later lines often carry stack-like
  /// detail that varies per occurrence.
  String _fingerprint(Object error) {
    var message = error.toString();
    final newline = message.indexOf('\n');
    if (newline != -1) message = message.substring(0, newline);
    if (message.length > 200) message = message.substring(0, 200);
    return '${error.runtimeType}:$message';
  }
}

class _FingerprintState {
  int sent = 0;
  int suppressed = 0;
  DateTime? lastSent;
}
