part of 'store.dart';

@DataClassName('SourceChannelRow')
class SourceChannels extends Table with SyncableTable, CreatedTable {
  Int64Column get id => int64()();
  BlobColumn get priorityTwistId => blob().map(const UuidConverter())();
  TextColumn get channelId => text()();
  TextColumn get title => text()();
  BlobColumn get priorityId =>
      blob().nullable().map(const UuidConverter())();
  BoolColumn get enabled =>
      boolean().withDefault(const Constant(false))();
  TextColumn get createThreads =>
      text().withDefault(const Constant('all'))();

  @override
  Set<Column> get primaryKey => {id};
}

class SourceChannelsBase extends BaseTable {
  SourceChannelsBase()
    : super(
        table: 'user_source_channel',
        syncEndpoint: 'source-channels',
        name: 'source_channels',
        order: 'updated_at',
        ascending: false,
      );

  @override
  Insertable<SourceChannelRow> fromBase(Map<String, dynamic> json) {
    json.remove('user_id');
    return SourceChannelRow.fromJson(json);
  }
}

class SourceChannel extends Equatable {
  static Future<void> pull() async {
    await Store.get.pull(Store.get.sourceChannels, SourceChannelsBase());
  }

  final SourceChannelRow _row;

  const SourceChannel(this._row);

  BigInt get id => _row.id;
  Uuid get priorityTwistId => _row.priorityTwistId;
  String get channelId => _row.channelId;
  String get title => _row.title;
  Uuid? get priorityId => _row.priorityId;
  bool get enabled => _row.enabled;
  String get createThreads => _row.createThreads;
  DateTime get createdAt => _row.createdAt;
  DateTime get updatedAt => _row.updatedAt;

  /// Watch all source channels for a given source account (priority_twist).
  static Stream<List<SourceChannel>> watchForSource(PriorityTwistId ptId) {
    return (Store.get.select(Store.get.sourceChannels)
          ..where((sc) => sc.priorityTwistId.equals(ptId.toBytes()))
          ..orderBy([(sc) => OrderingTerm.asc(sc.title)]))
        .watch()
        .map((rows) => rows.map((row) => SourceChannel(row)).toList());
  }

  /// Get all enabled source channels for a given source account.
  static Future<List<SourceChannel>> getEnabledForSource(
      PriorityTwistId ptId) async {
    final rows = await (Store.get.select(Store.get.sourceChannels)
          ..where((sc) => sc.priorityTwistId.equals(ptId.toBytes()))
          ..where((sc) => sc.enabled.equals(true)))
        .get();
    return rows.map((row) => SourceChannel(row)).toList();
  }

  @override
  List<Object?> get props => [_row];
}
