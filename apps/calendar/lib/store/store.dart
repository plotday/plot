import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:rxdart/rxdart.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/util/uuid.dart';
import 'package:plot/util/time.dart';
import 'package:plot/util/path.dart';
import 'package:plot/util/order.dart';
import 'package:plot/util/api.dart' as api;
import 'package:plot/base.dart';
import 'types.dart';

export 'package:drift/drift.dart' show Value;
export 'package:plot/util/time.dart';
export 'package:plot/util/uuid.dart';
export 'package:plot/util/order.dart';

part 'sync.dart';
part 'account.dart';
part 'calendar.dart';
part 'context.dart';
part 'note.dart';
part 'event.dart';
part 'budget.dart';
part 'session.dart';
part 'balance.dart';

part 'store.g.dart';

class StoreTable extends Table {
  DateTimeColumn get modifiedAt => dateTime().withDefault(currentDateAndTime)();
}

class IdStoreTable extends StoreTable {
  IntColumn get id => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

class UuidStoreTable extends StoreTable {
  BlobColumn get id => blob()
      .clientDefault(() => Uuid.generate().toBytes())
      .map(const UuidConverter())();

  @override
  Set<Column> get primaryKey => {id};
}

abstract class StoreDataClass extends DataClass {
  DateTime get modifiedAt;
}

abstract class BaseTable {
  BaseTable({
    required this.table,
    this.order = 'modified_at',
    this.ascending = true,
    String? name,
    this.limit,
  }) : name = name ?? "${table}s";

  final String table;
  final String name;
  final String order;
  final bool ascending;
  final int? limit;

  Insertable<DataClass> fromBase(Map<String, dynamic> json);
  Map<String, dynamic> toBase(DataClass row) => row.toJson();

  Future<(Iterable<Map<String, dynamic>>, String?)> get(
      String? lastOrder) async {
    var query =
        base.from(table).select().eq("user_id", base.auth.currentUser!.id);
    if (lastOrder != null) {
      query = query.gt(order, lastOrder);
    }
    query = filter(query);
    var query2 = sort(query);
    if (limit != null) {
      query2 = query2.limit(limit!);
    }
    final rows = await query2;
    return (rows, rows.isEmpty ? null : rows.last[order].toString());
  }

  PostgrestFilterBuilder<T2> filter<T2>(PostgrestFilterBuilder<T2> query) {
    return query;
  }

  PostgrestTransformBuilder<T2> sort<T2>(PostgrestTransformBuilder<T2> query) {
    return query.order(order, ascending: ascending);
  }

  Future<void> put(Iterable<Map<String, dynamic>> rows) async {
    await base.from(table).upsert(rows.toList());
  }
}

@DriftDatabase(tables: [
  SyncStates,
  Accounts,
  Calendars,
  Contexts,
  Notes,
  Events,
  Budgets,
  Sessions,
  Balances,
])
class Store extends _$Store {
  static final Store _store = Store._();
  static Store get get => _store;

  static void init() {
    driftRuntimeOptions.defaultSerializer =
        const ValueSerializer.defaults(serializeDateTimeValuesAsString: true);
  }

  Future<DATA> add<TABLE extends StoreTable, DATA extends DataClass>(
      TableInfo<TABLE, DATA> table, Insertable<DATA> data) async {
    try {
      return await Store.get
          .into(table)
          .insertReturning(data, onConflict: DoUpdate((old) => data));
    } catch (e) {
      print("Error saving ${toString()}");
      print(e);
      rethrow;
    }
  }

  Future<void> addBatch<TABLE extends StoreTable, DATA extends DataClass>(
      TableInfo<TABLE, DATA> table, Iterable<Insertable<DATA>> data) async {
    try {
      await batch((batch) {
        batch.insertAllOnConflictUpdate(table, data);
      });
    } catch (e) {
      print(e);
      rethrow;
    }
  }

  Future<void> save<TABLE extends StoreTable, DATA extends DataClass>(
      TableInfo<TABLE, DATA> table, Insertable<DATA> data) async {
    try {
      await add(table, data);
    } catch (e) {
      print("Error saving ${toString()}");
      print(e);
      rethrow;
    }
  }

  Future<void> push<TABLE extends StoreTable, DATA extends DataClass>(
    TableInfo<TABLE, DATA> table,
    BaseTable baseTable,
  ) async {
    final entity = baseTable.name;
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
    final now = DateTime.now();
    if (storeRows.isNotEmpty) {
      await into(syncStates).insert(
          SyncStatesCompanion.insert(
            entity: entity,
            pushedAt: Value(now),
            lastPulled: const Value(null),
          ),
          onConflict: DoUpdate(
            (old) => SyncStatesCompanion(
                entity: Value(entity), pushedAt: Value(now)),
          ));
    }
  }

  Future<bool> pull<TABLE extends StoreTable, DATA extends DataClass>(
      TableInfo<TABLE, DATA> table, BaseTable baseTable) async {
    if (!hasMore(baseTable)) return false;
    final entity = baseTable.name;
    final syncState = await (select(syncStates)
          ..where((row) => row.entity.equals(entity)))
        .getSingleOrNull();
    if (syncState?.more == false) {
      _noMore.add(entity);
      return false;
    }

    var (baseRows, last) = (await baseTable.get(syncState?.lastPulled));

    final storeRows = baseRows.map(baseTable.fromBase);
    await batch((batch) {
      batch.insertAllOnConflictUpdate(table, storeRows);
    });

    final more = baseTable.limit == null || last == null;
    if (!more) {
      _noMore.add(entity);
    }
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
      ),
    );
    return more;
  }

  static final Set<String> _noMore = {};
  bool hasMore(BaseTable baseTable) {
    return !_noMore.contains(baseTable.name);
  }

  Future<void> sync() async {
    await Future.wait([
      Account.push().then((_) => Account.pull()),
      // TODO add rest
    ]);
  }

  Store._() : super(_openConnection());

  @override
  int get schemaVersion => 1;

  static QueryExecutor _openConnection() {
    return driftDatabase(name: 'plot');
  }
}
