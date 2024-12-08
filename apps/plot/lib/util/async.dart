import 'dart:async';
import 'package:flutter/foundation.dart';

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
    var subscriptions = <StreamSubscription<T>>[];
    controller = StreamController<S>(
      onListen: () {
        subscriptions = <StreamSubscription<T>>[
          stream.listen(
            (event) {
              final result = map(event);

              // Emit the mapped value
              controller.add(result.value);

              if (result.expiry != null) {
                // Set up a timer to re-map and emit the value and expiry again
                final duration = result.expiry!.difference(DateTime.now());
                Timer(duration, () {
                  final expiredValueResult = map(event);
                  controller.add(expiredValueResult.value);
                });
              }
            },
            onError: controller.addError,
            onDone: controller.close,
            cancelOnError: false,
          )
        ];
      },
      onCancel: () {
        for (final subscription in subscriptions) {
          subscription.cancel();
        }
      },
    );
    return controller.stream;
  }
}
