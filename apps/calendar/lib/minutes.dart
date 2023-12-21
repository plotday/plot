import 'dart:async';

class Minutes {
  final StreamController<int> _controller = StreamController<int>();
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _timer;
  int _extraMinutes = 0;
  int _lastMinute = -1;

  Stream<int> get stream => _controller.stream;

  Minutes();

  void _tick(Timer timer) {
    if (_stopwatch.elapsed.inMinutes == _lastMinute) return;
    _lastMinute = _stopwatch.elapsed.inMinutes;
    _controller.sink.add(_extraMinutes + _lastMinute);
  }

  void start() {
    _stopwatch.reset();
    _stopwatch.start();
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);
  }

  void pause() {
    _extraMinutes += _stopwatch.elapsed.inMinutes;
    _stopwatch.stop();
    _timer?.cancel();
  }

  void resume() {
    _stopwatch.start();
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);
  }

  void dispose() {
    _timer?.cancel();
    _controller.close();
  }
}
