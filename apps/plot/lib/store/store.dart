import 'dart:async';

import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:rxdart/rxdart.dart';
import 'package:collection/collection.dart';
import 'package:injector/injector.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'package:stack_trace/stack_trace.dart';
import 'package:remove_markdown/remove_markdown.dart';

import 'package:plot/util/uuid.dart';
import 'package:plot/util/time.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/util/path.dart';
import 'package:plot/util/order.dart';
import 'package:plot/util/list.dart';
import 'package:plot/util/api.dart' as api;
import 'package:plot/util/async.dart';
import 'package:plot/base.dart';
import 'types.dart';
import 'logging.dart';

export 'package:plot/util/value.dart';
export 'package:plot/util/time.dart';
export 'package:plot/util/uuid.dart';
export 'package:plot/util/order.dart';
export 'schedule.dart';

part 'sync.dart';
part 'account.dart';
part 'calendar.dart';
part 'priority.dart';
part 'activity.dart';
part 'event.dart';
part 'session.dart';
part 'balance.dart';

part 'store.g.dart';

mixin SyncableTable on Table {
  DateTimeColumn get updatedAt =>
      dateTime()
          .withDefault(currentDateAndTime)
          .map(const LocalDateTimeConverter())();
}

mixin CreatedTable on Table {
  DateTimeColumn get createdAt =>
      dateTime()
          .withDefault(currentDateAndTime)
          .map(const LocalDateTimeConverter())();
}

mixin DraftTable on Table {
  BoolColumn get draft => boolean().withDefault(const Constant(false))();
}

mixin DeletableTable on Table {
  DateTimeColumn get deletedAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
}

mixin IdTable on Table {
  IntColumn get id => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

mixin UuidTable on Table {
  BlobColumn get id =>
      blob()
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

/// A table in the remote database that can be synced with the local database.
abstract class BaseTable {
  BaseTable({
    required this.table,
    this.writeTable,
    this.order = 'updated_at',
    this.ascending = true,
    this.upsertAsUpdate = false,
    String? name,
    this.filterName,
    this.limit,
  }) : name = name ?? "${table}s";

  final String table;

  /// Override the table for writes.
  final String? writeTable;
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
      DateTime? lastUpdated,
      (String?, String?)? range,
      bool more,
    )
  >
  get({
    (String?, String?)? include,
    (String?, String?)? exclude,
    DateTime? updatedSince,
  }) async {
    var query = Base.client
        .from(table)
        .select()
        .eq("user_id", Base.userId.toString());
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
    if (updatedSince != null) {
      query = query.gt("updated_at", updatedSince);
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
    DateTime lastUpdated;
    if (rows.isEmpty) {
      final localTimestamp = DateTime.now();
      final serverTimestamp = DateTime.parse(
        await Base.client.rpc<String>('server_timestamp'),
      );
      lastUpdated = preQueryTimestamp.add(
        serverTimestamp.difference(localTimestamp),
      );
    } else {
      lastUpdated = rows
          .map((row) {
            return DateTime.parse(row['updated_at'] as String);
          })
          .reduce((value, last) => value.isAfter(last) ? value : last);
    }
    final more = include != null || (limit != null && rows.length < limit!);
    return (rows, lastUpdated, range, more);
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
        await Base.client.from(writeTable ?? table).update(rest).eq('id', id);
      }
    } else if (upsertAsUpdate) {
      await Base.client.from(writeTable ?? table).insert(rows.toList());
    } else {
      await Base.client.from(writeTable ?? table).upsert(rows.toList());
    }
  }
}

@DriftDatabase(
  tables: [
    SyncStates,
    Accounts,
    Calendars,
    Priorities,
    Activities,
    Events,
    Sessions,
    Balances,
  ],
  include: {'priority.drift', 'activity.drift', 'balance.drift'},
)
class Store extends _$Store {
  static Store get get => Injector.appInstance.get<Store>();
  static Future<void> init(User user) async {
    driftRuntimeOptions.defaultSerializer = const CustomSerializer();
    if (Injector.appInstance.exists<Store>()) {
      await get.close();
    }
    Injector.appInstance.registerSingleton<Store>(
      () => Store._(user),
      override: true,
    );
  }

  Future<DATA> add<TABLE extends SyncableTable, DATA extends DataClass>(
    TableInfo<TABLE, DATA> table,
    Insertable<DATA> data,
  ) async {
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

  Future<void> addBatch<TABLE extends SyncableTable, DATA extends DataClass>(
    TableInfo<TABLE, DATA> table,
    Iterable<Insertable<DATA>> data,
  ) async {
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

  Future<void> save<TABLE extends SyncableTable, DATA extends DataClass>(
    TableInfo<TABLE, DATA> table,
    Insertable<DATA> data,
    BaseTable baseTable,
  ) async {
    log.info("Saving", data);
    try {
      await add(table, data);
    } catch (e) {
      print("Error saving ${toString()}");
      print(e);
      rethrow;
    }
    push(table, baseTable);
  }

  Future<void> push<TABLE extends SyncableTable, DATA extends DataClass>(
    TableInfo<TABLE, DATA> table,
    BaseTable baseTable,
  ) async {
    final entity = baseTable.fullName;
    final syncState =
        await (select(syncStates)
          ..where((row) => row.entity.equals(entity))).getSingleOrNull();

    final storeQuery = select(table);
    if (syncState?.pushedAt != null) {
      storeQuery.where((row) {
        return row.updatedAt.isBiggerThanValue(syncState!.pushedAt!);
      });
    }
    storeQuery.orderBy([(t) => OrderingTerm(expression: t.updatedAt)]);
    final storeRows = await storeQuery.get();
    if (storeRows.isNotEmpty) {
      log.info("Pushing ${storeRows.length} rows to ${baseTable.table}");
      try {
        await baseTable.put(storeRows.map((row) => baseTable.toBase(row)));
      } catch (e) {
        log.warning("Batch push failed", e);
        for (final row in storeRows) {
          try {
            await baseTable.put([baseTable.toBase(row)]);
          } catch (e, stackTrace) {
            log.warning(
              "Error pushing ${row.toJsonString()} to ${baseTable.table}",
              e,
              stackTrace,
            );
          }
        }
      }
      final now = DateTime.now();
      await into(syncStates).insert(
        SyncStatesCompanion.insert(entity: entity, pushedAt: Value(now)),
        onConflict: DoUpdate(
          (old) =>
              SyncStatesCompanion(entity: Value(entity), pushedAt: Value(now)),
        ),
      );
    }
  }

  Future<bool> pull<TABLE extends SyncableTable, DATA extends DataClass>(
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
    final syncState =
        await (select(syncStates)
          ..where((row) => row.entity.equals(entity))).getSingleOrNull();
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

    var (baseRows, lastUpdated, newRange, more) = (await baseTable.get(
      include:
          range ??
          ([PullType.updates, PullType.more].contains(type)
              ? (syncState?.from, syncState?.to)
              : null),
      exclude: type == PullType.more ? (syncState?.from, syncState?.to) : null,
      updatedSince: type == PullType.more ? null : syncState?.pulledAt,
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
        pulledAt: Value(lastUpdated),
        from: paged ? Value(from) : const Value.absent(),
        to: paged ? Value(to) : const Value.absent(),
        more: Value(paged ? more : false),
        pushedAt: const Value(null),
      ),
      onConflict: DoUpdate(
        (old) => SyncStatesCompanion(
          entity: Value(entity),
          pulledAt: Value(lastUpdated),
          from: paged ? Value(from) : const Value.absent(),
          to: paged ? Value(to) : const Value.absent(),
          more:
              paged
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
          pulledAt: Value(lastUpdated),
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
      Chain.capture(() => Account.push().then((_) => Account.pull())),
      Chain.capture(() => Calendar.push().then((_) => Calendar.pull())),
      Chain.capture(() => Priority.push().then((_) => Priority.pull())),
      Chain.capture(() => Event.push().then((_) => Event.pull())),
      Chain.capture(() => Session.push().then((_) => Session.pull())),
      Chain.capture(() => Balance.pull()),
    ]);
  }

  Store._(User user)
    : super(
        driftDatabase(
          name: 'plot-${user.id}',
          web: DriftWebOptions(
            sqlite3Wasm: Uri.parse('sqlite3.wasm'),
            driftWorker: Uri.parse('drift_worker.dart.js'),
          ),
        ),
      );

  @override
  int get schemaVersion => 58;

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
