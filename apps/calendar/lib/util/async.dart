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
