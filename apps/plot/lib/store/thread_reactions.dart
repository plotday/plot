part of 'store.dart';

@DataClassName('ThreadReactionsRow')
class ThreadReactions extends Table with SyncableTable, UuidTable {
  // Empty string means no occurrence (NULL in PostgreSQL); mirrors ThreadTags.
  TextColumn get occurrence => text().withDefault(const Constant(''))();
  TextColumn get reactions => text().nullable().map(const ReactionsConverter())();
  TextColumn get reactionsUpdated =>
      text().nullable().map(const ReactionUpdatesConverter())();

  @override
  Set<Column> get primaryKey => {id, occurrence};
}

class ThreadReactionsBase extends BaseTable {
  ThreadReactionsBase({this.priorityId})
    : super(
        table: 'user_thread_reactions',
        syncEndpoint: 'thread-reactions',
        name: "thread_reactions",
        filterName: priorityId?.toString(),
        order: 'updated_at',
        ascending: false,
      );

  final PriorityId? priorityId;

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
    if (priorityId != null) {
      params['priority_id'] = priorityId.toString();
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
  Insertable<ThreadReactionsRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    json.remove('sync_depth');
    json.remove('user_id');
    if (json['occurrence'] == null) {
      json['occurrence'] = '';
    }
    return ThreadReactionsRow.fromJson(json);
  }

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);
    if (json['occurrence'] == '') {
      json['occurrence'] = null;
    }
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
          '/sync/thread-reactions/update',
          body: {
            'thread_id': id,
            'actor_id': Base.actorId.toString(),
            'client_id': updatedBy,
            'reaction_updates': reactionsUpdated,
          },
        );
      } catch (e, stackTrace) {
        log.severe(
          'ThreadReactionsBase.put - RPC error for id $id: $e',
          e,
          stackTrace,
        );
        rethrow;
      }

      await Store.get
          .update(Store.get.threadReactions)
          .replace(
            ThreadReactionsCompanion(
              id: Value(Uuid.fromString(id)),
              reactionsUpdated: const Value(null),
              updatedAt: Value(DateTime.now()),
            ),
          );
    }
  }
}
