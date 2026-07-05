part of 'store.dart';

@DataClassName('NoteReactionsRow')
class NoteReactions extends Table with SyncableTable, UuidTable {
  TextColumn get reactions => text().nullable().map(const ReactionsConverter())();
  TextColumn get reactionsUpdated =>
      text().nullable().map(const ReactionUpdatesConverter())();
}

class NoteReactionsBase extends BaseTable {
  NoteReactionsBase({this.threadId})
    : super(
        table: 'user_note_reactions',
        syncEndpoint: 'note-reactions',
        name: "note_reactions",
        filterName: threadId?.toString(),
        order: 'updated_at',
        ascending: false,
      );

  final Uuid? threadId;

  @override
  Map<String, String> buildParams({
    DateTime? updatedSince,
    String? lastId,
    String? lastHorizon,
    String? pageSeq,
    String? pageId,
    bool initial = false,
    bool archived = false,
  }) {
    final params = super.buildParams(
      updatedSince: updatedSince,
      lastId: lastId,
      lastHorizon: lastHorizon,
      pageSeq: pageSeq,
      pageId: pageId,
      initial: initial,
      archived: archived,
    );
    if (threadId != null) {
      params['thread_id'] = threadId.toString();
    }
    return params;
  }

  @override
  Map<String, String> buildRangeParams(DateTimeRange range) {
    final params = <String, String>{};
    if (range.start != null) {
      params['range_start'] = toServerTimestamp(range.start!);
    }
    if (range.end != null) {
      params['range_end'] = toServerTimestamp(range.end!);
    }
    return params;
  }

  @override
  Insertable<NoteReactionsRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    json.remove('sync_depth');
    json.remove('user_id');
    return NoteReactionsRow.fromJson(json);
  }

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);
    // Keep reactions_updated for the put method; the server's batch update
    // endpoint consumes it.
    return json;
  }

  @override
  Future<void> put(Iterable<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;

    for (final row in rows) {
      final reactionsUpdated =
          row['reactions_updated'] as Map<String, dynamic>?;
      if (reactionsUpdated == null || reactionsUpdated.isEmpty) continue;

      final id = row['id'] as String;
      final updatedBy = row['updated_by'] as int;

      try {
        await api.post<dynamic>(
          '/sync/note-reactions/update',
          body: {
            'note_id': id,
            'actor_id': Base.actorId.toString(),
            'client_id': updatedBy,
            'reaction_updates': reactionsUpdated,
          },
        );
      } catch (e, stackTrace) {
        log.severe(
          'NoteReactionsBase.put - RPC error for id $id: $e',
          e,
          stackTrace,
        );
        rethrow;
      }

      // Remove only the keys we just pushed; new optimistic edits made while
      // the push was in flight must remain pending.
      final noteId = Uuid.fromString(id);
      final current = await (Store.get.select(Store.get.noteReactions)
            ..where((t) => t.id.equalsValue(noteId)))
          .getSingleOrNull();
      final currentUpdates = current?.reactionsUpdated;
      if (currentUpdates != null) {
        final remaining = Map<String, bool>.from(currentUpdates)
          ..removeWhere((key, _) => reactionsUpdated.containsKey(key));
        await (Store.get.update(Store.get.noteReactions)
              ..where((t) => t.id.equalsValue(noteId)))
            .write(NoteReactionsCompanion(
              reactionsUpdated:
                  Value(remaining.isEmpty ? null : remaining),
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
      final reactionsRow = row as NoteReactionsRow;
      final local = await (store.select(store.noteReactions)
            ..where((t) => t.id.equals(reactionsRow.id.toBytes())))
          .getSingleOrNull();

      if (local != null &&
          local.reactionsUpdated != null &&
          local.reactionsUpdated!.isNotEmpty) {
        // Apply still-pending reaction changes on top of the server's
        // reactions so optimistic local state survives a pull that arrives
        // before the server has processed our push.
        final mergedReactions = <Reaction, List<ActorId>>{
          for (final entry in (reactionsRow.reactions ?? const {}).entries)
            entry.key: List<ActorId>.from(entry.value),
        };
        final pendingChanges = <String, bool>{};
        final canonicalSelf = Actor.canonicalId(Base.actorId);

        for (final entry in local.reactionsUpdated!.entries) {
          final emoji = entry.key;
          final wantPresent = entry.value;

          final actorList = mergedReactions[emoji] ?? const <ActorId>[];
          final presentOnServer = actorList.any(
            (id) => Actor.canonicalId(id) == canonicalSelf,
          );

          if (presentOnServer == wantPresent) {
            // Server already reflects the desired state.
            continue;
          }

          pendingChanges[emoji] = wantPresent;
          if (wantPresent) {
            final list =
                mergedReactions.putIfAbsent(emoji, () => <ActorId>[]);
            if (!list.any((id) => Actor.canonicalId(id) == canonicalSelf)) {
              list.add(canonicalSelf);
            }
          } else {
            final list = mergedReactions[emoji];
            if (list != null) {
              list.removeWhere(
                (id) => Actor.canonicalId(id) == canonicalSelf,
              );
              if (list.isEmpty) mergedReactions.remove(emoji);
            }
          }
        }

        if (pendingChanges.isNotEmpty) {
          result.add(reactionsRow.copyWith(
            reactions:
                Value(mergedReactions.isEmpty ? null : mergedReactions),
            reactionsUpdated: Value(pendingChanges),
          ));
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
