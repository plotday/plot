import 'dart:async';

class Clock {
  static final Clock _instance = Clock._init();

  final StreamController<DateTime> _controller = StreamController<DateTime>();

  late Stream<DateTime> seconds;
  late Stream<DateTime> minutes;

  Timer? _timer;
  int _lastMinute = -1;

  factory Clock() {
    return _instance;
  }

  Clock._init() {
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);
    seconds = _controller.stream.asBroadcastStream();
    minutes = seconds.where((DateTime now) {
      if (now.minute == _lastMinute) return false;
      _lastMinute = now.minute;
      return true;
    }).asBroadcastStream();
  }

  void _tick(Timer timer) {
    _controller.sink.add(DateTime.now());
  }

  void dispose() {
    _timer?.cancel();
    _controller.close();
  }
}
