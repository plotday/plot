import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'sync.dart';
import 'context.dart';
import 'note.dart';
import 'table.dart';

part 'store.g.dart';

final base = Supabase.instance.client;

@DriftDatabase(tables: [PullStates, PushStates, Contexts, Notes])
class Store extends _$Store {
  static final Store _store = Store._();
  static Store get get => _store;

  void sync<TABLE extends StoreTable, ROW extends DataClass>(
      TableInfo<TABLE, ROW> table,
      {String? baseEntity}) async {
    final entity = table.actualTableName;
    baseEntity ??= entity;

    // Pull rows
    final pullState = await (select(pullStates)
          ..where((row) => row.entity.equals(entity)))
        .getSingleOrNull();
    final baseQuery =
        base.from(baseEntity).select().eq("user_id", base.auth.currentUser!.id);
    if (pullState != null) {
      baseQuery.gt('modified_at', pullState.at);
    }
    baseQuery.order('modified_at', ascending: true);
    final baseRows = (await baseQuery).map(Context.fromJson);

    // Push rows
    final pushState = await (select(pushStates)
          ..where((row) => row.entity.equals(entity)))
        .getSingleOrNull();
    final storeQuery = select(table);
    if (pushState != null) {
      storeQuery.where((row) {
        return row.modifiedAt.isBiggerThanValue(pushState.at);
      });
    }
    storeQuery.orderBy([(t) => OrderingTerm(expression: t.modifiedAt)]);
    final storeRows = await storeQuery.get();
    await (base.from(baseEntity).upsert(storeRows.map((row) => row.toJson())));
    if (storeRows.isNotEmpty) {
      await into(pushStates).insert(
          PushStatesCompanion.insert(entity: entity, at: DateTime.now()),
          onConflict: DoUpdate(
            (old) => PushStatesCompanion(
                entity: Value(entity), at: Value(DateTime.now())),
          ));
    }

    if (baseRows.isNotEmpty) {
      final last = baseRows.last.modifiedAt;
      await into(pullStates)
          .insert(PullStatesCompanion.insert(entity: entity, at: last),
              onConflict: DoUpdate(
                (old) =>
                    PullStatesCompanion(entity: Value(entity), at: Value(last)),
              ));
    }
  }

  void syncContexts() async {
    return sync(contexts);
  }

  Store._() : super(_openConnection());

  @override
  int get schemaVersion => 1;

  static QueryExecutor _openConnection() {
    return driftDatabase(name: 'plot');
  }
}
