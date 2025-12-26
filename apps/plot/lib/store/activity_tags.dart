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
        writeTable: 'activity_tag',
        name: "activity_tags",
        filterName: priorityPath,
        order: 'updated_at',
        ascending:
            false, // Get latest items first for reverse chronological sync
      );

  final String? priorityPath;

  @override
  PostgrestFilterBuilder<T2> filter<T2>(
    PostgrestFilterBuilder<T2> query, {
    bool initial = false,
    bool archived = false,
  }) {
    query = super.filter(query, initial: initial, archived: archived);

    // Add priority path filtering if priorityPath is provided
    // Use ltree 'cd' operator (contained in / descendant of)
    if (priorityPath != null) {
      query = query.filter('priority_path', 'cd', priorityPath);
    }

    return query;
  }

  @override
  PostgrestFilterBuilder<T2> filterRange<T2>(
    PostgrestFilterBuilder<T2> query,
    DateTimeRange? range,
  ) {
    if (range != null && range.start != null && range.end != null) {
      final dateRange = '[${range.start!.toDate()},${range.end!.toDate()})';
      final dateTimeRange = '[${range.start!.toDb()},${range.end!.toDb()})';
      query = query.or('range_at.ov."$dateTimeRange",range_on.ov."$dateRange"');
    }
    return query;
  }

  @override
  Insertable<ActivityTagsRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
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

    log.info('ActivityTagsBase.put called with ${rows.length} rows');

    for (final row in rows) {
      log.info(
        'ActivityTagsBase.put - processing row: ${row['id']}, tags_updated: ${row['tags_updated']}',
      );

      final tagsUpdated = row['tags_updated'] as Map<String, dynamic>?;
      if (tagsUpdated == null || tagsUpdated.isEmpty) {
        log.info(
          'ActivityTagsBase.put - skipping row ${row['id']}: no tags_updated',
        );
        continue;
      }

      final id = row['id'] as String;
      final updatedBy = row['updated_by'] as int;

      log.info('ActivityTagsBase.put - updating activity tags for id: $id');

      // Update the server
      try {
        await Base.client.rpc<void>(
          'update_activity_tags',
          params: {
            'p_activity_id': id,
            'p_actor_id': Base.actorId.toString(),
            'p_client_id': updatedBy,
            'p_tag_updates': tagsUpdated,
          },
        );
        log.info(
          'ActivityTagsBase.put - update_activity_tags RPC completed successfully',
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
      log.info(
        'ActivityTagsBase.put - clearing tagsUpdated in local database for id: $id',
      );
      await Store.get
          .update(Store.get.activityTags)
          .replace(
            ActivityTagsCompanion(
              id: Value(Uuid.fromString(id)),
              tagsUpdated: const Value(null),
              updatedAt: Value(DateTime.now()),
            ),
          );
      log.info('ActivityTagsBase.put - completed processing row: $id');
    }
  }
}
