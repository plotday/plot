import 'dart:convert';

class ResponseTimeWindow {
  final List<int> days; // ISO 1=Mon..7=Sun
  final String start; // "HH:MM"
  final String end; // "HH:MM"

  const ResponseTimeWindow({
    required this.days,
    required this.start,
    required this.end,
  });

  factory ResponseTimeWindow.fromJson(Map<String, dynamic> json) {
    return ResponseTimeWindow(
      days: (json['days'] as List).cast<int>(),
      start: json['start'] as String,
      end: json['end'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
    'days': days,
    'start': start,
    'end': end,
  };

  static List<ResponseTimeWindow>? fromJsonString(String? jsonString) {
    if (jsonString == null) return null;
    final list = jsonDecode(jsonString) as List;
    return list.map((e) => ResponseTimeWindow.fromJson(e as Map<String, dynamic>)).toList();
  }

  static String? toJsonString(List<ResponseTimeWindow>? windows) {
    if (windows == null) return null;
    return jsonEncode(windows.map((w) => w.toJson()).toList());
  }

  /// Default business hours: Mon-Fri, 9am-5pm
  static List<ResponseTimeWindow> get defaultBusinessHours => [
    const ResponseTimeWindow(days: [1, 2, 3, 4, 5], start: '09:00', end: '17:00'),
  ];
}

enum TurnaroundUnit {
  hours,
  days,
  workdays;

  String get label {
    switch (this) {
      case TurnaroundUnit.hours:
        return 'hours';
      case TurnaroundUnit.days:
        return 'days';
      case TurnaroundUnit.workdays:
        return 'work days';
    }
  }
}

class TurnaroundTime {
  final int value;
  final TurnaroundUnit unit;

  const TurnaroundTime({
    required this.value,
    required this.unit,
  });

  factory TurnaroundTime.fromJson(Map<String, dynamic> json) {
    return TurnaroundTime(
      value: json['value'] as int,
      unit: TurnaroundUnit.values.firstWhere(
        (u) => u.name == json['unit'],
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'value': value,
    'unit': unit.name,
  };

  static TurnaroundTime? fromJsonString(String? jsonString) {
    if (jsonString == null) return null;
    return TurnaroundTime.fromJson(jsonDecode(jsonString) as Map<String, dynamic>);
  }

  static String? toJsonString(TurnaroundTime? turnaround) {
    if (turnaround == null) return null;
    return jsonEncode(turnaround.toJson());
  }

  String get displayLabel {
    return '$value ${unit.label}';
  }
}
