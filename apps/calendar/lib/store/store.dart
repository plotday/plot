import 'dart:async';

import 'package:drift/drift.dart';
// import 'package:drift/isolate.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:rxdart/rxdart.dart';
import 'package:collection/collection.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/util/uuid.dart';
import 'package:plot/util/time.dart';
import 'package:plot/util/path.dart';
import 'package:plot/util/order.dart';
import 'package:plot/util/list.dart';
import 'package:plot/util/map.dart';
import 'package:plot/util/api.dart' as api;
import 'package:plot/util/async.dart';
import 'package:plot/base.dart';
import 'types.dart';

export 'package:drift/drift.dart' show Value;
export 'package:plot/util/time.dart';
export 'package:plot/util/uuid.dart';
export 'package:plot/util/order.dart';

part 'sync.dart';
part 'account.dart';
part 'calendar.dart';
part 'activity.dart';
part 'note.dart';
part 'event.dart';
part 'session.dart';
part 'balance.dart';

part 'store.g.dart';

class StoreTable extends Table {
  DateTimeColumn get modifiedAt => dateTime().withDefault(currentDateAndTime)();
}

mixin DraftTable on Table {
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  BoolColumn get draft => boolean().withDefault(const Constant(false))();
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

enum PullType {
  initial, // pull first page on initial pull
  more, // pull the next page
  updates, // pull updates since last pull
  all, // pull all
}

abstract class BaseTable {
  BaseTable({
    required this.table,
    this.order = 'modified_at',
    this.ascending = true,
    this.upsertAsUpdate = false,
    String? name,
    this.filterName,
    this.limit,
  }) : name = name ?? "${table}s";

  final String table;
  final String name;
  final String? filterName;
  String get fullName => "$name${filterName == null ? "" : ":$filterName"}";
  final String order;
  final bool ascending;
  final int? limit;
  final bool upsertAsUpdate;

  Insertable<DataClass> fromBase(Map<String, dynamic> json);
  Map<String, dynamic> toBase(DataClass row) => row.toJson();

  Future<
      (
        Iterable<Map<String, dynamic>> rows,
        DateTime? lastModified,
        (String?, String?)? range,
        bool more,
      )> get({
    (String?, String?)? include,
    (String?, String?)? exclude,
    DateTime? modifiedSince,
  }) async {
    var query =
        base.from(table).select().eq("user_id", base.auth.currentUser!.id);
    if (exclude != null) {
      final (from, to) = exclude;
      if (from != null) {
        if (to != null) {
          query = query.or("$order.lt.$from,$order.gt.$to");
        } else {
          query = query.lt(order, from);
        }
      } else if (to != null) {
        query = query.gt(order, to);
      }
    }
    if (include != null) {
      final (from, to) = include;
      if (from != null) {
        query = query.gte(order, from);
      }
      if (to != null) {
        query = query.lte(order, to);
      }
    }
    if (modifiedSince != null) {
      query = query.gt("modified_at", modifiedSince);
    }
    query = filter(query);
    var query2 = sort(query);
    if (limit != null) {
      query2 = query2.limit(limit!);
    }
    DateTime preQueryTimestamp = DateTime.now();
    final rows = await query2;
    (String?, String?)? range;
    if (include != null && limit == null) {
      range = include;
    } else if (rows.isNotEmpty) {
      range = (rows.first[order].toString(), rows.last[order].toString());
    }
    DateTime lastModified;
    if (rows.isEmpty) {
      final localTimestamp = DateTime.now();
      final serverTimestamp =
          DateTime.parse(await base.rpc<String>('server_timestamp'));
      lastModified =
          preQueryTimestamp.add(serverTimestamp.difference(localTimestamp));
    } else {
      lastModified = rows.map((row) {
        return DateTime.parse(row['modified_at'] as String);
      }).reduce((value, last) => value.isAfter(last) ? value : last);
    }
    final more = include != null || (limit != null && rows.length < limit!);
    return (rows, lastModified, range, more);
  }

  PostgrestFilterBuilder<T2> filter<T2>(PostgrestFilterBuilder<T2> query) {
    return query;
  }

  PostgrestTransformBuilder<T2> sort<T2>(PostgrestTransformBuilder<T2> query) {
    return query.order(order, ascending: ascending);
  }

  Future<void> put(Iterable<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;
    final id = rows.first['id'];
    if (id is int) {
      for (final row in rows) {
        final id = row['id'] as Object;
        final rest = Map<String, dynamic>.from(row)..remove('id');
        await base.from(table).update(rest).eq('id', id);
      }
    } else if (upsertAsUpdate) {
      await base.from(table).insert(rows.toList());
    } else {
      await base.from(table).upsert(rows.toList());
    }
  }
}

@DriftDatabase(tables: [
  SyncStates,
  Accounts,
  Calendars,
  Activities,
  Notes,
  Events,
  Sessions,
  Balances,
])
class Store extends _$Store {
  static Store get get => _store;
  static late final Store _store;

  static void init() async {
    driftRuntimeOptions.defaultSerializer = const CustomSerializer();
    _store = Store._();
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
      print("Error saving ${toString()}");
      print(e);
      rethrow;
    }
  }

  Future<void> save<TABLE extends StoreTable, DATA extends DataClass>(
      TableInfo<TABLE, DATA> table,
      Insertable<DATA> data,
      BaseTable baseTable) async {
    try {
      await add(table, data);
    } catch (e) {
      print("Error saving ${toString()}");
      print(e);
      rethrow;
    }
    push(table, baseTable);
  }

  Future<void> push<TABLE extends StoreTable, DATA extends DataClass>(
    TableInfo<TABLE, DATA> table,
    BaseTable baseTable,
  ) async {
    final entity = baseTable.fullName;
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
    if (storeRows.isNotEmpty) {
      try {
        await baseTable.put(storeRows.map((row) => baseTable.toBase(row)));
      } catch (e) {
        print("Error pushing to ${baseTable.table}");
        print(e);
        rethrow;
      }
      final now = DateTime.now();
      await into(syncStates).insert(
        SyncStatesCompanion.insert(
          entity: entity,
          pushedAt: Value(now),
        ),
        onConflict: DoUpdate(
          (old) =>
              SyncStatesCompanion(entity: Value(entity), pushedAt: Value(now)),
        ),
      );
    }
  }

  Future<bool> pull<TABLE extends StoreTable, DATA extends DataClass>(
    PullType type,
    TableInfo<TABLE, DATA> table,
    BaseTable baseTable, {
    (String, String)? range,
  }) async {
    final paged = [PullType.initial, PullType.more].contains(type);
    if (paged && !hasMore(baseTable)) {
      return false;
    }
    final entity = baseTable.fullName;
    final syncState = await (select(syncStates)
          ..where((row) => row.entity.equals(entity)))
        .getSingleOrNull();
    if (paged && syncState?.more == false) {
      _noMore.add(entity);
      return false;
    }
    if (type == PullType.initial && syncState?.to != null) {
      return true;
    }
    if (type == PullType.updates && syncState?.pulledAt == null) {
      return true;
    }

    var (baseRows, lastModified, newRange, more) = (await baseTable.get(
      include: range ??
          ([PullType.updates, PullType.more].contains(type)
              ? (syncState?.from, syncState?.to)
              : null),
      exclude: type == PullType.more ? (syncState?.from, syncState?.to) : null,
      modifiedSince: type == PullType.more ? null : syncState?.pulledAt,
    ));
    final (from, to) = newRange ?? (null, null);

    final storeRows = baseRows.map(baseTable.fromBase);
    await batch((batch) {
      batch.insertAllOnConflictUpdate(table, storeRows);
    });

    if (!more) {
      _noMore.add(entity);
    }
    await into(syncStates).insert(
      SyncStatesCompanion.insert(
        entity: entity,
        pulledAt: Value(lastModified),
        from: paged ? Value(from) : const Value.absent(),
        to: paged ? Value(to) : const Value.absent(),
        more: Value(paged ? more : false),
        pushedAt: const Value(null),
      ),
      onConflict: DoUpdate(
        (old) => SyncStatesCompanion(
          entity: Value(entity),
          pulledAt: Value(lastModified),
          from: paged ? Value(from) : const Value.absent(),
          to: paged ? Value(to) : const Value.absent(),
          more: paged
              ? Value(more)
              : type == PullType.all
                  ? const Value(false)
                  : const Value.absent(),
        ),
      ),
    );
    // If this is the first pull for the given type, we need to set its pulledAt
    // so updates are synced from that point on.
    if (baseTable.filterName != null) {
      await into(syncStates).insert(
        SyncStatesCompanion.insert(
          entity: baseTable.name,
          pulledAt: Value(lastModified),
          pushedAt: const Value(null),
        ),
        onConflict: DoNothing(),
      );
    }
    return more;
  }

  static final Set<String> _noMore = {};
  bool hasMore(BaseTable baseTable) {
    return !_noMore.contains(baseTable.fullName);
  }

  Future<void> sync() async {
    await Future.wait([
      Account.push().then((_) => Account.pull()),
      Activity.push().then((_) => Activity.pull()),
      Note.push().then((_) => Note.pull()),
      Event.push().then((_) => Event.pull()),
      Balance.pull(),
    ]);
  }

  Store._()
      : super(driftDatabase(
          name: 'plot',
          // native: const DriftNativeOptions(
          //   shareAcrossIsolates: true,
          // ),
        ));

  @override
  int get schemaVersion => 23;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onUpgrade: (Migrator m, int from, int to) async {
        final m = createMigrator();
        for (final table in allTables) {
          await m.deleteTable(table.actualTableName);
          await m.createTable(table);
        }
      },
    );
  }
}

extension ValueExtension<T> on Value<T> {
  bool get notNull => present && value != null;
  T? or(T? fallback) => present ? value : fallback;
  T? get orNull => present ? value : null;
}
