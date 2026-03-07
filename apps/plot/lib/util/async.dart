import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:plot/util/time_service.dart';

class StreamListenable<T> {
  final Stream<T> _stream;
  late final ValueNotifier<T?> _notifier;
  late final StreamSubscription<T> _subscription;

  StreamListenable(this._stream) {
    _notifier = ValueNotifier(null);
    _subscription = _stream.listen((value) {
      _notifier.value = value;
    });
  }

  ValueListenable<T?> get listenable => _notifier;

  void dispose() {
    _subscription.cancel();
    _notifier.dispose();
  }
}

class ExpiringResult<S> {
  final S value;
  final DateTime? expiry;

  ExpiringResult({required this.value, this.expiry});
}

class ExpiringStreamTransformer<T, S> extends StreamTransformerBase<T, S> {
  final ExpiringResult<S> Function(T) map;

  ExpiringStreamTransformer(this.map);

  @override
  Stream<S> bind(Stream<T> stream) {
    late StreamController<S> controller;
    StreamSubscription<T>? subscription;
    Timer? timer;

    void handle(T event) {
      timer?.cancel();
      if (controller.isClosed) return;

      final result = map(event);
      controller.add(result.value);

      if (result.expiry != null) {
        final duration = result.expiry!.difference(Time.now());
        timer = Timer(duration, () {
          handle(event);
        });
      }
    }

    controller = StreamController<S>(
      onListen: () {
        subscription = stream.listen(
          handle,
          onError: controller.addError,
          onDone: () {
            timer?.cancel();
            controller.close();
          },
          cancelOnError: false,
        );
      },
      onCancel: () {
        timer?.cancel();
        subscription?.cancel();
      },
    );

    return controller.stream;
  }
}

/// Creates a stream that re-evaluates a query whenever the next expiry time passes.
///
/// [createStream] - The main query that returns your actual data of type T
/// [createExpiryStream] - A query that returns the next nullable DateTime when a new row will become valid
///
/// Returns a Stream*lt;T&gt; that updates whenever:
/// 1. The initial query runs
/// 2. A previously future expiry time is reached
/// 3. A new future expiry time is detected
Stream<T> streamWithExpiryRevaluation<T>({
  required Stream<T> Function() createStream,
  required Stream<DateTime?> Function() createExpiryStream,
}) {
  final controller = StreamController<T>.broadcast();
  Timer? expiryTimer;
  StreamSubscription<DateTime?>? expirySubscription;
  StreamSubscription<T>? dataSubscription;
  bool isActive = true;

  // Function to cancel any pending timer
  void cancelTimer() {
    expiryTimer?.cancel();
    expiryTimer = null;
  }

  // Subscribe to changes in the primary data set.
  void subscribeToData() {
    if (!isActive) return;
    dataSubscription?.cancel();
    dataSubscription = createStream().listen(
      (data) {
        if (!isActive) return;
        controller.add(data);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!isActive) return;
        controller.addError(error, stackTrace);
      },
    );
  }

  // Resubscribe to the expiry stream.
  void subscribeToExpiry() {
    if (!isActive) return;
    subscribeToData();
    expirySubscription?.cancel();
    expirySubscription = createExpiryStream().listen(
      (nextExpiry) {
        if (!isActive) return;
        // Schedule the next evaluation based on the new expiry time received from the stream.
        cancelTimer();
        final now = Time.now();
        if (nextExpiry == null) return;
        if (nextExpiry.isAfter(now)) {
          final delay = nextExpiry.difference(now);
          expiryTimer = Timer(delay, () {
            subscribeToExpiry();
          });
        } else {
          // HACK: Work around clock skew
          expiryTimer = Timer(Duration(milliseconds: 50), () {
            subscribeToExpiry();
          });
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!isActive) return;
        controller.addError(error, stackTrace);
      },
    );
  }

  // Initial subscription to expiry changes
  subscribeToExpiry();

  // Handle cleanup when the stream is closed.
  controller.onCancel = () {
    isActive = false;
    cancelTimer();
    dataSubscription?.cancel();
    expirySubscription?.cancel();
  };

  return controller.stream;
}

/// Creates a stream that re-evaluates a query whenever the next expiry time passes.
///
/// [stream] - A stream that emits ExpiringResult&lt;T> containing both data and expiry time
///
/// Returns a Stream&lt;T> that updates whenever:
/// 1. The source stream emits a new value
/// 2. A previously future expiry time is reached
Stream<T> streamWithExpiry<T>(
  Stream<ExpiringResult<T>> Function() createStream,
) {
  final controller = StreamController<T>.broadcast();
  Timer? expiryTimer;
  StreamSubscription<ExpiringResult<T>>? subscription;
  bool isActive = true;

  // Function to cancel any pending timer
  void cancelTimer() {
    expiryTimer?.cancel();
    expiryTimer = null;
  }

  // Subscribe to the stream
  void subscribe() {
    if (!isActive) return;
    subscription?.cancel();
    subscription = createStream().listen(
      (result) {
        if (!isActive) return;

        // Add the value to the output stream
        controller.add(result.value);

        // Schedule next evaluation based on expiry time
        cancelTimer();
        final now = Time.now();
        final nextExpiry = result.expiry;

        if (nextExpiry != null && nextExpiry.isAfter(now)) {
          final delay = nextExpiry.difference(now);
          expiryTimer = Timer(delay, () {
            subscribe();
          });
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!isActive) return;
        controller.addError(error, stackTrace);
      },
    );
  }

  // Initial subscription
  subscribe();

  // Handle cleanup when the stream is closed
  controller.onCancel = () {
    isActive = false;
    cancelTimer();
    subscription?.cancel();
  };

  return controller.stream;
}

/// Adaptive batch debouncer with three configurable timing parameters.
///
/// Batches rapid function calls with adaptive timing:
/// - First batch fires quickly (maxInitialMs)
/// - Subsequent batches fire with longer delay (maxSubsequentMs)
/// - Waits for quiet period (waitMs) between calls before firing
///
/// Example: BatchDebouncer(200, 500, 250) with calls at [80, 100, 220, 320, 450]ms:
/// - Batch 1: [80, 100] → fires at 280ms (80 + 200 max initial)
/// - Batch 2: [220, 320, 450] → fires at 720ms (220 + 500 max subsequent)
class BatchDebouncer<T> {
  final int maxInitialMs;
  final int maxSubsequentMs;
  final int waitMs;
  final void Function(T key) onBatch;

  final Map<T, Timer> _timers = {};
  final Map<T, DateTime> _batchStartTimes = {};

  BatchDebouncer({
    required this.maxInitialMs,
    required this.maxSubsequentMs,
    required this.waitMs,
    required this.onBatch,
  });

  void call(T key) {
    final now = DateTime.now();
    final existingBatchStartTime = _batchStartTimes[key];

    // Cancel existing timer
    _timers[key]?.cancel();

    // Calculate appropriate delay based on whether this is first call in batch
    final int delay;
    if (existingBatchStartTime == null) {
      // First call in batch
      _batchStartTimes[key] = now;
      delay = maxInitialMs < waitMs ? maxInitialMs : waitMs;
    } else {
      // Subsequent call in batch
      final int elapsed = now.difference(existingBatchStartTime).inMilliseconds;
      final int remainingTime = maxSubsequentMs - elapsed;
      delay = remainingTime < waitMs ? remainingTime : waitMs;
    }

    // Start new timer
    _timers[key] = Timer(Duration(milliseconds: delay), () {
      _executeBatch(key);
    });
  }

  void _executeBatch(T key) {
    _timers.remove(key);
    _batchStartTimes.remove(key);
    onBatch(key);
  }

  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _batchStartTimes.clear();
  }
}
