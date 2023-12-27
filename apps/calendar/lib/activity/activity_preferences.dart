import 'dart:math';
import 'package:equatable/equatable.dart';

class ActivityPreferences extends Equatable {
  static const ActivityPreferences _cache = ActivityPreferences();

  static ActivityPreferences get() {
    return _cache;
  }

  static Duration sessionDuration(Duration? available) {
    if (available == null) {
      return get().duration;
    }
    final marginSeconds = max(get().minimumBreak.inSeconds,
        available.inSeconds * get().breakRatio.round());
    return Duration(
        minutes: (min(available.inSeconds - marginSeconds,
                    get().duration.inSeconds) /
                60.0)
            .round());
  }

  const ActivityPreferences(
      {this.duration = const Duration(minutes: 25),
      this.breakRatio = 5.0 / 30,
      this.minimumBreak = const Duration(minutes: 1)});

  ActivityPreferences.fromJson(Map<String, dynamic> json)
      : duration = Duration(seconds: json['duration'] as int),
        breakRatio = json['breakPerMinute'] as double,
        minimumBreak = Duration(seconds: json['duration'] as int);

  final Duration duration;
  final double breakRatio;
  final Duration minimumBreak;

  @override
  List<Object> get props => [duration, breakRatio];

  Map<String, dynamic> toJson() => {
        'duration': duration.inSeconds,
        'breakRatio': breakRatio,
        'minimumBreak': minimumBreak.inSeconds,
      };
}
