part of 'store.dart';

@DataClassName('TopicRow')
class Topics extends Table with SyncableTable, UuidTable, DeletableTable {
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

class TopicsBase extends BaseTable {
  TopicsBase() : super(table: 'user_topic', syncEndpoint: 'topics');

  @override
  Map<String, dynamic> toBase(DataClass row) {
    throw UnsupportedError('Topic is read-only');
  }

  @override
  Insertable<TopicRow> fromBase(Map<String, dynamic> json) {
    return TopicRow.fromJson(json);
  }
}

class Topic {
  static TableInfo<Topics, TopicRow> get table => Store.get.topics;

  static Future<void> pull() async {
    await Store.get.pull(table, TopicsBase(), initial: true);
    await Store.get.pull(table, TopicsBase());
  }
}
