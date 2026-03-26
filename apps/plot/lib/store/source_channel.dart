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
  TextColumn get linkTypes => text().nullable()();

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
    // Drift's default serializer can't cast int to BigInt; convert explicitly
    if (json['id'] is int) {
      json['id'] = BigInt.from(json['id'] as int);
    }
    // Serialize link_types JSON to string for text column storage
    if (json['link_types'] != null && json['link_types'] is! String) {
      json['link_types'] = jsonEncode(json['link_types']);
    }
    return SourceChannelRow.fromJson(json);
  }
}

class SourceChannel extends Equatable {
  /// Cache for looking up source channels by (priorityTwistId, channelId).
  /// Populated during sync.
  static final Map<String, SourceChannel> _cache = {};

  /// Build a cache key from priorityTwistId + channelId.
  static String _cacheKey(Uuid ptId, String channelId) =>
      '${ptId.toString()}:$channelId';

  /// Look up a source channel by priorityTwistId and channelId.
  static SourceChannel? findByChannel(Uuid ptId, String channelId) =>
      _cache[_cacheKey(ptId, channelId)];

  /// Find any source channel for a given source account that has linkTypes.
  /// Used when a link doesn't have a channelId (legacy links synced before
  /// channel-level linkTypes were added).
  static SourceChannel? findBySource(Uuid ptId) {
    final prefix = '${ptId.toString()}:';
    for (final entry in _cache.entries) {
      if (entry.key.startsWith(prefix) && entry.value.rawLinkTypes != null) {
        return entry.value;
      }
    }
    return null;
  }

  /// Populate the cache from a list of source channels.
  static void populateCache(List<SourceChannel> channels) {
    for (final sc in channels) {
      _cache[_cacheKey(sc.priorityTwistId, sc.channelId)] = sc;
    }
  }

  static Future<void> pull() async {
    await Store.get.pull(Store.get.sourceChannels, SourceChannelsBase());
    // Refresh cache after pull
    final rows = await Store.get.select(Store.get.sourceChannels).get();
    _cache.clear();
    populateCache(rows.map((row) => SourceChannel(row)).toList());
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
  String? get rawLinkTypes => _row.linkTypes;
  DateTime get createdAt => _row.createdAt;
  DateTime get updatedAt => _row.updatedAt;

  /// Parse the linkTypes JSON string into a list of LinkTypeConfig.
  List<LinkTypeConfig>? get parsedLinkTypes {
    final raw = rawLinkTypes;
    if (raw == null) return null;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => LinkTypeConfig.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// Watch all source channels for a given source account (priority_twist).
  static Stream<List<SourceChannel>> watchForSource(PriorityTwistId ptId) {
    return (Store.get.select(Store.get.sourceChannels)
          ..where((sc) => sc.priorityTwistId.equals(ptId.toBytes()))
          ..orderBy([(sc) => OrderingTerm.asc(sc.title)]))
        .watch()
        .map((rows) {
          final channels = rows.map((row) => SourceChannel(row)).toList();
          populateCache(channels);
          return channels;
        });
  }

  /// Get all enabled source channels for a given source account.
  static Future<List<SourceChannel>> getEnabledForSource(
      PriorityTwistId ptId) async {
    final rows = await (Store.get.select(Store.get.sourceChannels)
          ..where((sc) => sc.priorityTwistId.equals(ptId.toBytes()))
          ..where((sc) => sc.enabled.equals(true)))
        .get();
    final channels = rows.map((row) => SourceChannel(row)).toList();
    populateCache(channels);
    return channels;
  }

  @override
  List<Object?> get props => [_row];
}
