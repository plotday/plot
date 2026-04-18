part of 'store.dart';

@DataClassName('GroupRow')
class Groups extends Table with SyncableTable, UuidTable, DeletableTable {
  TextColumn get name => text()();
  TextColumn get type => text()();
  TextColumn get joinPolicy => text()();
  IntColumn get teamId => integer().nullable()();
  BoolColumn get autoMaintained =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get isAdmin => boolean().withDefault(const Constant(false))();
  BoolColumn get isMember => boolean().withDefault(const Constant(false))();
  TextColumn get memberContactIds =>
      text().nullable().map(const UuidListConverter())();
}

class GroupsBase extends BaseTable {
  GroupsBase() : super(table: 'user_group', syncEndpoint: 'groups');

  @override
  Map<String, dynamic> toBase(DataClass row) {
    throw UnsupportedError('Group is read-only');
  }

  @override
  Insertable<GroupRow> fromBase(Map<String, dynamic> json) {
    return GroupRow.fromJson(json);
  }
}

class Group {
  static TableInfo<Groups, GroupRow> get table => Store.get.groups;

  static Future<void> pull() async {
    await Store.get.pull(table, GroupsBase(), initial: true);
    await Store.get.pull(table, GroupsBase());
  }

  /// Fetch a group by id. Returns null if the user can't see the group.
  static Future<GroupRow?> getOne(Uuid id) {
    return (Store.get.select(table)
          ..where((t) => t.id.equals(id.toBytes()))
          ..limit(1))
        .getSingleOrNull();
  }

  /// Watch a group by id. Emits null until the group is synced.
  static Stream<GroupRow?> watchOne(Uuid id) {
    return (Store.get.select(table)
          ..where((t) => t.id.equals(id.toBytes()))
          ..limit(1))
        .watchSingleOrNull();
  }
}
