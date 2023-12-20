import 'package:flutter/material.dart';
import 'dart:async';

class PomodoroTimer extends StatefulWidget {
  final String title;

  const PomodoroTimer({super.key, required this.title});

  @override
  State<PomodoroTimer> createState() => _PomodoroTimerState();
}

class _PomodoroTimerState extends State<PomodoroTimer> {
  static const Duration _defaultDuration = Duration(minutes: 25);

  Timer? _timer;
  Duration _duration = _defaultDuration;

  @override
  void initState() {
    super.initState();
    _resetTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _resetTimer() {
    setState(() {
      _duration = _defaultDuration;
    });
    _startTimer();
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        if (_duration.inSeconds > 0) {
          _duration -= const Duration(seconds: 1);
        } else {
          timer.cancel();
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Stack(
        children: [
          const Positioned.fill(
            child: CircularProgressIndicator(
              value: 0.92,
            ),
          ),
          AspectRatio(
            aspectRatio: 1,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  widget.title,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                Text(
                  _duration.toString().split('.').first.padLeft(8, "0"),
                  style: Theme.of(context).textTheme.displaySmall,
                ),
                ElevatedButton(
                  onPressed: () {
                    _timer?.cancel();
                    _resetTimer();
                  },
                  child: const Text('Reset Timer'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
