part of 'store.dart';

typedef ActivityExceptionId = (Uuid, Uuid); // (activityId, exceptionId)

@DataClassName('ActivityExceptionRow')
class ActivityExceptions extends Table with SyncableTable, UuidTable {
  static String formatOccurrence(DateTime dateTime, {bool dateOnly = false}) {
    if (dateOnly) {
      return '${dateTime.year.toString().padLeft(4, '0')}-'
          '${dateTime.month.toString().padLeft(2, '0')}-'
          '${dateTime.day.toString().padLeft(2, '0')}';
    } else {
      return '${dateTime.year.toString().padLeft(4, '0')}-'
          '${dateTime.month.toString().padLeft(2, '0')}-'
          '${dateTime.day.toString().padLeft(2, '0')}T'
          '${dateTime.hour.toString().padLeft(2, '0')}:'
          '${dateTime.minute.toString().padLeft(2, '0')}';
    }
  }

  BlobColumn get activityId => blob().map(const UuidConverter())();
  TextColumn get occurrence => text()();

  DateTimeColumn get startAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  DateTimeColumn get endAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  TextColumn get startOn =>
      text().nullable().nullable().map(const DateConverter())();
  TextColumn get endOn =>
      text().nullable().nullable().map(const DateConverter())();
  IntColumn get duration =>
      integer().nullable().map(const DurationConverter())();
  DateTimeColumn get doneAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  TextColumn get title => text().nullable()();
  TextColumn get preview => text().nullable()();

  @override
  Set<Column> get primaryKey => {activityId, occurrence};
}

class ActivityExceptionsBase extends BaseTable {
  ActivityExceptionsBase({this.priorityPath})
    : super(
        table: 'user_activity_exception',
        syncEndpoint: 'activity-exceptions',
        name: "activity_exceptions",
        filterName: priorityPath,
        order: 'updated_at',
        ascending:
            false, // Get latest items first for reverse chronological sync
      );

  final String? priorityPath;

  @override
  Map<String, String> buildParams({
    DateTime? updatedSince,
    String? lastId,
    bool initial = false,
    bool archived = false,
  }) {
    final params = super.buildParams(
      updatedSince: updatedSince,
      lastId: lastId,
      initial: initial,
      archived: archived,
    );
    if (priorityPath != null) {
      params['priority_path'] = priorityPath!;
    }
    return params;
  }

  @override
  Map<String, String> buildRangeParams(DateTimeRange range) {
    // Calendar overlap filtering via range_start/range_end
    final params = <String, String>{};
    if (range.start != null) {
      params['range_start'] = range.start!.toIso8601String();
    }
    if (range.end != null) {
      params['range_end'] = range.end!.toIso8601String();
    }
    return params;
  }

  @override
  Insertable<ActivityExceptionRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    json.remove('user_id'); // Remove user_id from function result

    // Handle the 'at' field from user_activity_exception_tz function
    final at = json['at'] != null
        ? DateTimeRange.fromString(json['at'] as String)
        : null;
    json['at'] = at?.toDb();

    // Handle the 'on' field from user_activity_exception_tz function
    final on = json['on'] != null
        ? DateTimeRange.fromString(json['on'] as String)
        : null;
    json['on'] = on?.toDb();

    return ActivityExceptionRow.fromJson(json);
  }

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);

    // Convert 'at' field back to database format
    if (json['at'] != null) {
      final at = DateTimeRange.fromString(json['at'] as String);
      json['at'] = at.toDb();
    }

    // Convert 'on' field back to database format
    if (json['on'] != null) {
      final on = DateTimeRange.fromString(json['on'] as String);
      json['on'] = on.toDb();
    }

    return json;
  }
}
