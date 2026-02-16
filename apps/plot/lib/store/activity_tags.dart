part of 'store.dart';

@DataClassName('ActivityTagsRow')
class ActivityTags extends Table with SyncableTable, UuidTable {
  // Empty string means no occurrence (NULL in PostgreSQL)
  TextColumn get occurrence => text().withDefault(const Constant(''))();
  TextColumn get tags => text().nullable().map(const TagsConverter())();
  TextColumn get tagsUpdated =>
      text().nullable().map(const TagUpdatesConverter())();

  @override
  Set<Column> get primaryKey => {id, occurrence};
}

class ActivityTagsBase extends BaseTable {
  ActivityTagsBase({this.priorityPath})
    : super(
        table: 'user_activity_tags',
        syncEndpoint: 'activity-tags',
        name: "activity_tags",
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
  Insertable<ActivityTagsRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    json.remove('sync_depth');
    json.remove('user_id'); // Remove user_id from function result

    // Convert NULL occurrence from PostgreSQL to empty string for SQLite
    if (json['occurrence'] == null) {
      json['occurrence'] = '';
    }

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

    return ActivityTagsRow.fromJson(json);
  }

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);

    // Keep tags_updated for the put method - don't remove it like other base implementations
    // The put method specifically needs this field to know which tags to update

    // Convert empty string occurrence back to NULL for PostgreSQL
    if (json['occurrence'] == '') {
      json['occurrence'] = null;
    }

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

  @override
  Future<void> put(Iterable<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;

    for (final row in rows) {
      final tagsUpdated = row['tags_updated'] as Map<String, dynamic>?;
      if (tagsUpdated == null || tagsUpdated.isEmpty) continue;

      final id = row['id'] as String;
      final updatedBy = row['updated_by'] as int;

      // Update the server via sync API
      try {
        await api.post<dynamic>(
          '/sync/activity-tags/update',
          body: {
            'activity_id': id,
            'actor_id': Base.actorId.toString(),
            'client_id': updatedBy,
            'tag_updates': tagsUpdated,
          },
        );
      } catch (e, stackTrace) {
        log.severe(
          'ActivityTagsBase.put - RPC error for id $id: $e',
          e,
          stackTrace,
        );
        rethrow;
      }

      // After successfully updating the server, clear tagsUpdated in the local database
      await Store.get
          .update(Store.get.activityTags)
          .replace(
            ActivityTagsCompanion(
              id: Value(Uuid.fromString(id)),
              tagsUpdated: const Value(null),
              updatedAt: Value(DateTime.now()),
            ),
          );
    }
  }
}
