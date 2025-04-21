import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:drift/drift.dart';

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

      final result = map(event);
      controller.add(result.value);

      if (result.expiry != null) {
        final duration = result.expiry!.difference(DateTime.now());
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
/// [query] - The main query that returns your actual data of type T
/// [nextExpiryQuery] - A query that returns the next nullable DateTime when a new row will become valid
///
/// Returns a Stream*lt;T&gt; that updates whenever:
/// 1. The initial query runs
/// 2. A previously future expiry time is reached
/// 3. A new future expiry time is detected
Stream<T> streamWithExpiryRevaluation<T>({
  required Stream<T> Function() query,
  required Stream<DateTime?> Function() nextExpiryQuery,
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
    dataSubscription = query().listen(
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
    expirySubscription = nextExpiryQuery().listen(
      (nextExpiry) {
        if (!isActive) return;
        // Schedule the next evaluation based on the new expiry time received from the stream.
        cancelTimer();
        final now = DateTime.now();
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
