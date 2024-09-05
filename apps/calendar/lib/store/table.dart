import 'package:drift/drift.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final base = Supabase.instance.client;

class StoreTable extends Table {
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get modifiedAt => dateTime()();
}

class IdStoreTable extends StoreTable {
  IntColumn get id => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

class UuidStoreTable extends StoreTable {
  BlobColumn get id => blob()();

  @override
  Set<Column> get primaryKey => {id};
}

abstract class StoreDataClass extends DataClass {
  DateTime get createdAt;
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
    final rows = transform(await query2);
    return (rows, rows.isEmpty ? null : rows.last[order].toString());
  }

  PostgrestFilterBuilder<T2> filter<T2>(PostgrestFilterBuilder<T2> query) {
    return query;
  }

  PostgrestTransformBuilder<T2> sort<T2>(PostgrestTransformBuilder<T2> query) {
    return query.order(order, ascending: ascending);
  }

  List<Map<String, dynamic>> transform(List<Map<String, dynamic>> rows) {
    return rows;
  }

  Future<void> put(Iterable<Map<String, dynamic>> rows) async {
    await (base.from(table).upsert(rows));
  }
}
