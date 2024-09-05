import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'package:plot/util/uuid.dart';
import 'sync.dart';
import 'context.dart';
import 'note.dart';
import 'account.dart';
import 'table.dart';

part 'store.g.dart';

@DriftDatabase(tables: [SyncStates, Accounts, Contexts, Notes])
class Store extends _$Store {
  static final Store _store = Store._();
  static Store get get => _store;

  Future<void> push<TABLE extends StoreTable, DATA extends DataClass>(
    TableInfo<TABLE, DATA> table,
    BaseTable baseTable,
  ) async {
    final entity = table.actualTableName;
    final syncState = await (select(syncStates)
          ..where((row) => row.entity.equals(entity)))
        .getSingleOrNull();

    final storeQuery = select(table);
    if (syncState?.pushedAt != null) {
      storeQuery.where((row) {
        return row.modifiedAt.isBiggerThanValue(syncState!.pushedAt!);
      });
    }
    storeQuery.orderBy([(t) => OrderingTerm(expression: t.modifiedAt)]);
    final storeRows = await storeQuery.get();
    await baseTable.put(storeRows.map((row) => row.toJson()));
    if (storeRows.isNotEmpty) {
      await into(syncStates).insert(
          SyncStatesCompanion.insert(
            entity: entity,
            pushedAt: Value(DateTime.now()),
            lastPulled: const Value(null),
          ),
          onConflict: DoUpdate(
            (old) => SyncStatesCompanion(
                entity: Value(entity), pushedAt: Value(DateTime.now())),
          ));
    }
  }

  Future<bool> pull<TABLE extends StoreTable, DATA extends DataClass>(
    TableInfo<TABLE, DATA> table,
    BaseTable baseTable,
    Insertable<DATA> Function(Map<String, dynamic> json) fromBase,
  ) async {
    final entity = table.actualTableName;
    final syncState = await (select(syncStates)
          ..where((row) => row.entity.equals(entity)))
        .getSingleOrNull();
    if (syncState?.more == false) return false;

    final (baseRows, last) = (await baseTable.get(syncState?.lastPulled));
    final storeRows = baseRows.map(fromBase);
    await batch((batch) {
      batch.insertAllOnConflictUpdate(table, storeRows);
    });

    final more = baseTable.limit == null || last == null;
    await into(syncStates).insert(
        SyncStatesCompanion.insert(
          entity: entity,
          lastPulled: Value(last),
          pushedAt: const Value(null),
          more: Value(more),
        ),
        onConflict: DoUpdate(
          (old) => SyncStatesCompanion(
            entity: Value(entity),
            lastPulled: Value(last),
            more: Value(more),
          ),
        ));
    return more;
  }

  void sync() async {
    await Future.wait([
      accounts.pull(),
      contexts.pull(),
    ]);
    await Future.wait([
      notes.pullUpdates(),
      contexts.push(),
    ]);
    await Future.wait([
      notes.push(),
    ]);
  }

  Store._() : super(_openConnection());

  @override
  int get schemaVersion => 1;

  static QueryExecutor _openConnection() {
    return driftDatabase(name: 'plot');
  }
}

extension AccountsPushPull on $AccountsTable {
  Future<void> push() async {
    return (attachedDatabase as Store).push(this, AccountsBase());
  }

  Future<bool> pull() async {
    return (attachedDatabase as Store)
        .pull(this, AccountsBase(), Account.fromJson);
  }
}

extension ContextsPushPull on $ContextsTable {
  Future<void> push() async {
    return (attachedDatabase as Store).push(this, ContextsBase());
  }

  Future<bool> pull() async {
    return (attachedDatabase as Store)
        .pull(this, ContextsBase(), Context.fromJson);
  }
}

extension ContextFunctions on Context {
  Future<Context?> get parent async {
    var segments = path.split('.');
    if (segments.length == 1) {
      return null;
    }
    final parentPath = segments.sublist(0, segments.length - 1).join('.');
    return await (Store.get.select(Store.get.contexts)
          ..where((t) => t.path.equals(parentPath)))
        .map((row) => Context.fromJson(row.toJson()))
        .getSingle();
  }

  bool isParent(Context other) =>
      other == this || other.path.startsWith("$path.");
  bool isChild(Context? other) =>
      other == null || path.startsWith("${other.path}.");
}

extension NotesPushPull on $NotesTable {
  Future<void> push() async {
    return (attachedDatabase as Store).push(this, NotesBase());
  }

  Future<bool> pullUpdates() async {
    return (attachedDatabase as Store).pull(this, NotesBase(), Note.fromJson);
  }

  Future<bool> pullContext(String? contextPath) async {
    return (attachedDatabase as Store)
        .pull(this, ContextNotesBase(contextPath), Note.fromJson);
  }

  Future<bool> pullTopic(UUID topicId) async {
    return (attachedDatabase as Store)
        .pull(this, TopicNotesBase(topicId), Note.fromJson);
  }
}
