part of 'store.dart';

@DataClassName('NoteTagsRow')
class NoteTags extends Table with SyncableTable, UuidTable {
  TextColumn get tags => text().nullable().map(const TagsConverter())();
  TextColumn get tagsUpdated =>
      text().nullable().map(const TagUpdatesConverter())();
}

class NoteTagsBase extends BaseTable {
  NoteTagsBase({this.priorityPath, this.activityId})
    : super(
        table: 'user_note_tags',
        writeTable: 'note_tag',
        name: "note_tags",
        filterName: priorityPath ?? activityId?.toString(),
        order: 'updated_at',
        ascending:
            false, // Get latest items first for reverse chronological sync
      );

  final String? priorityPath;
  final Uuid? activityId;

  @override
  PostgrestFilterBuilder<T2> filter<T2>(PostgrestFilterBuilder<T2> query) {
    query = super.filter(query); // Apply user_id filter

    // Add priority path filtering if priorityPath is provided
    // Use ltree 'cd' operator (contained in / descendant of)
    if (priorityPath != null) {
      query = query.filter('priority_path', 'cd', priorityPath);
    }

    // Add activity filtering if activityId is provided
    // Need to join with note table to filter by activity_id
    // Since the view doesn't expose activity_id directly, we filter via the note table
    if (activityId != null) {
      // The user_note_tags view joins note, so we can filter using note.activity_id
      // We need to use the 'id' column which is the note_id
      // But Supabase doesn't support arbitrary joins in filters, so we use a subquery approach
      // Actually, simpler: just pull all note_tags and let Drift filter locally
      // For now, we'll just use this as a marker in filterName for sync tracking
      // The actual filtering happens client-side based on which notes we have
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
  Insertable<NoteTagsRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    json.remove('user_id'); // Remove user_id from function result

    // Handle the 'at' field from user_note view
    final at = json['at'] != null
        ? DateTimeRange.fromString(json['at'] as String)
        : null;
    json['at'] = at?.toDb();

    // Handle the 'on' field from user_note view
    final on = json['on'] != null
        ? DateTimeRange.fromString(json['on'] as String)
        : null;
    json['on'] = on?.toDb();

    return NoteTagsRow.fromJson(json);
  }

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);

    // Keep tags_updated for the put method - don't remove it like other base implementations
    // The put method specifically needs this field to know which tags to update

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

    log.info('NoteTagsBase.put called with ${rows.length} rows');

    for (final row in rows) {
      log.info(
        'NoteTagsBase.put - processing row: ${row['id']}, tags_updated: ${row['tags_updated']}',
      );

      final tagsUpdated = row['tags_updated'] as Map<String, dynamic>?;
      if (tagsUpdated == null || tagsUpdated.isEmpty) {
        log.info(
          'NoteTagsBase.put - skipping row ${row['id']}: no tags_updated',
        );
        continue;
      }

      final id = row['id'] as String;
      final updatedBy = row['updated_by'] as int;

      log.info('NoteTagsBase.put - updating note tags for id: $id');

      // Update the server
      try {
        await Base.client.rpc<void>(
          'update_note_tags',
          params: {
            'p_note_id': id,
            'p_user_id': Base.userId.toString(),
            'p_client_id': updatedBy,
            'p_tag_updates': tagsUpdated,
          },
        );
        log.info(
          'NoteTagsBase.put - update_note_tags RPC completed successfully',
        );
      } catch (e, stackTrace) {
        log.severe(
          'NoteTagsBase.put - RPC error for id $id: $e',
          e,
          stackTrace,
        );
        rethrow;
      }

      // After successfully updating the server, clear tagsUpdated in the local database
      log.info(
        'NoteTagsBase.put - clearing tagsUpdated in local database for id: $id',
      );
      await Store.get
          .update(Store.get.noteTags)
          .replace(
            NoteTagsCompanion(
              id: Value(Uuid.fromString(id)),
              tagsUpdated: const Value(null),
              updatedAt: Value(DateTime.now()),
            ),
          );
      log.info('NoteTagsBase.put - completed processing row: $id');
    }
  }
}
