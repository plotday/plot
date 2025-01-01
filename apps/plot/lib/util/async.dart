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
