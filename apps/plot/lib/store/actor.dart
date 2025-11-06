part of 'store.dart';

typedef ActorId = Uuid;

@DataClassName('ActorRow')
class Actors extends Table
    with SyncableTable, UuidTable, CreatedTable, DeletableTable {
  TextColumn get type => text().map(const EnumConverter<ActorType>())();
  TextColumn get name => text()();
  TextColumn get email => text().nullable()();
  TextColumn get avatarUrl => text().nullable()();
}

class ActorsBase extends BaseTable {
  ActorsBase() : super(table: 'actor');

  @override
  Map<String, dynamic> toBase(DataClass row) {
    // Actor is read-only, so we don't need to convert to base format
    throw UnsupportedError('Actor is read-only');
  }

  @override
  Insertable<ActorRow> fromBase(Map<String, dynamic> json) {
    return ActorRow.fromJson(json);
  }

  @override
  PostgrestFilterBuilder<T2> filter<T2>(PostgrestFilterBuilder<T2> query) {
    // Don't filter by user_id since actor view handles access control
    return query;
  }
}

class Actor extends ActorRow {
  static TableInfo<Actors, ActorRow> get table => Store.get.actors;

  static Future<void> pull() async =>
      await Store.get.pull(PullType.all, table, ActorsBase());

  static Future<List<Actor>> get({bool? deleted = false}) async {
    return _get(deleted: deleted).get();
  }

  static Stream<List<Actor>> watch({bool? deleted = false}) {
    return _get(deleted: deleted).watch();
  }

  static MultiSelectable<Actor> _get({bool? deleted = false}) {
    return (Store.get.select(table)..where(
          (t) => deleted == null
              ? const Constant(true)
              : deleted
              ? t.archivedAt.isNotNull()
              : t.archivedAt.isNull(),
        ))
        .map((row) => Actor.fromStore(row));
  }

  Actor.fromStore(ActorRow row)
    : super(
        id: row.id,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        archivedAt: row.archivedAt,
        type: row.type,
        name: row.name,
        email: row.email,
        avatarUrl: row.avatarUrl,
      );

  @override
  Actor copyWith({
    ActorId? id,
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<DateTime?> archivedAt = const Value.absent(),
    ActorType? type,
    String? name,
    Value<String?> email = const Value.absent(),
    Value<String?> avatarUrl = const Value.absent(),
    Value<int?> pending = const Value.absent(),
  }) => Actor.fromStore(
    super.copyWith(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      archivedAt: archivedAt,
      type: type,
      name: name,
      email: email,
      avatarUrl: avatarUrl,
      pending: pending,
    ),
  );
}
