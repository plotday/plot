part of 'store.dart';

@DataClassName('NoteTagsRow')
class NoteTags extends Table with SyncableTable, UuidTable {
  TextColumn get tags => text().nullable().map(const TagsConverter())();
  TextColumn get tagsUpdated =>
      text().nullable().map(const TagUpdatesConverter())();
}

class NoteTagsBase extends BaseTable {
  NoteTagsBase({this.threadId})
    : super(
        table: 'user_note_tags',
        syncEndpoint: 'note-tags',
        name: "note_tags",
        filterName: threadId?.toString(),
        order: 'updated_at',
        ascending:
            false, // Get latest items first for reverse chronological sync
      );

  final Uuid? threadId;

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
  Insertable<NoteTagsRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    json.remove('sync_depth');
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

    for (final row in rows) {
      final tagsUpdated = row['tags_updated'] as Map<String, dynamic>?;
      if (tagsUpdated == null || tagsUpdated.isEmpty) continue;

      final id = row['id'] as String;
      final updatedBy = row['updated_by'] as int;

      // Update the server via sync API
      try {
        await api.post<dynamic>(
          '/sync/note-tags/update',
          body: {
            'note_id': id,
            'actor_id': Base.actorId.toString(),
            'client_id': updatedBy,
            'tag_updates': tagsUpdated,
          },
        );
      } catch (e, stackTrace) {
        log.severe(
          'NoteTagsBase.put - RPC error for id $id: $e',
          e,
          stackTrace,
        );
        rethrow;
      }

      // After successfully updating the server, remove only the pushed keys from
      // tagsUpdated. New keys may have been written while the push was in flight
      // (e.g. user completes for self, then unassigns another user). Clearing
      // unconditionally would wipe out those pending changes.
      final noteId = Uuid.fromString(id);
      final current = await (Store.get.select(Store.get.noteTags)
            ..where((t) => t.id.equalsValue(noteId)))
          .getSingleOrNull();
      final currentUpdates = current?.tagsUpdated;
      if (currentUpdates != null) {
        final remaining = Map<String, bool>.from(currentUpdates)
          ..removeWhere((key, _) => tagsUpdated.containsKey(key));
        await (Store.get.update(Store.get.noteTags)
              ..where((t) => t.id.equalsValue(noteId)))
            .write(NoteTagsCompanion(
              tagsUpdated: Value(remaining.isEmpty ? null : remaining),
              updatedAt: Value(DateTime.now()),
            ));
      }
    }
  }

  @override
  Future<List<Insertable<DataClass>>> processPulledRows(
    Store store,
    Iterable<Insertable<DataClass>> rows,
  ) async {
    final result = <Insertable<DataClass>>[];

    for (final row in rows) {
      final noteTagsRow = row as NoteTagsRow;

      // Check if local has pending tagsUpdated changes
      final local = await (store.select(store.noteTags)
            ..where((t) => t.id.equals(noteTagsRow.id.toBytes())))
          .getSingleOrNull();

      if (local != null &&
          local.tagsUpdated != null &&
          local.tagsUpdated!.isNotEmpty) {
        // Check which pending changes are not yet reflected on server
        final serverTags = noteTagsRow.tags ?? {};
        final pendingChanges = <String, bool>{};

        for (final entry in local.tagsUpdated!.entries) {
          final key = entry.key;
          final wantTagPresent = entry.value;

          // Parse composite key: "tagId" or "tagId:actorId"
          final parts = key.split(':');
          final tagId = int.parse(parts[0]);
          final targetActorId =
              parts.length > 1 ? ActorId.fromString(parts[1]) : Base.actorId;

          final tag = Tag.get(id: tagId);
          if (tag == null) continue; // Unknown tag, skip

          // Check if the specific actor has this tag on the server
          final actorList = serverTags[tag] ?? [];
          final tagPresentOnServer = actorList.contains(targetActorId);

          // Only keep pending changes where server doesn't match desired state
          if (tagPresentOnServer != wantTagPresent) {
            pendingChanges[key] = wantTagPresent;
          }
        }

        if (pendingChanges.isNotEmpty) {
          result.add(noteTagsRow.copyWith(tagsUpdated: Value(pendingChanges)));
        } else {
          result.add(row);
        }
      } else {
        result.add(row);
      }
    }

    return result;
  }
}
