import 'dart:async';

class Clock {
  static final Clock _instance = Clock._init();

  final StreamController<DateTime> _controller = StreamController<DateTime>();
  Timer? _timer;
  int _lastMinute = -1;

  Stream<DateTime> get stream => _controller.stream;

  factory Clock() {
    return _instance;
  }

  Clock._init() {
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);
  }

  void _tick(Timer timer) {
    final now = DateTime.now();
    if (now.minute == _lastMinute) return;
    _lastMinute = now.minute;
    _controller.sink.add(now);
  }

  void dispose() {
    _timer?.cancel();
    _controller.close();
  }
}
