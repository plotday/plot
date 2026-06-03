part of 'store.dart';

@DataClassName('ChannelRow')
class Channels extends Table with SyncableTable, CreatedTable {
  Int64Column get id => int64()();
  BlobColumn get twistInstanceId => blob().map(const UuidConverter())();
  TextColumn get channelId => text()();
  TextColumn get title => text()();
  BoolColumn get enabled =>
      boolean().withDefault(const Constant(false))();
  TextColumn get linkTypes => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class ChannelsBase extends BaseTable {
  ChannelsBase()
    : super(
        table: 'user_channel',
        syncEndpoint: 'channels',
        name: 'channels',
        order: 'updated_at',
        ascending: false,
      );

  @override
  Insertable<ChannelRow> fromBase(Map<String, dynamic> json) {
    json.remove('user_id');
    // Drift's default serializer can't cast int to BigInt; convert explicitly
    if (json['id'] is int) {
      json['id'] = BigInt.from(json['id'] as int);
    }
    // Serialize link_types JSON to string for text column storage
    if (json['link_types'] != null && json['link_types'] is! String) {
      json['link_types'] = jsonEncode(json['link_types']);
    }
    return ChannelRow.fromJson(json);
  }

  @override
  Future<List<Insertable<DataClass>>> processPulledRows(
    Store store,
    Iterable<Insertable<DataClass>> rows,
  ) async {
    // When a channel transitions to disabled, purge that channel's connector
    // links locally (the server hard-deleted them; channel.enabled is the
    // delete signal).
    final toPurge = <({Uuid instanceId, String channelId})>[];
    final result = <Insertable<DataClass>>[];
    for (final row in rows) {
      final ch = row as ChannelRow;
      if (!ch.enabled) {
        final local = await (store.select(store.channels)
              ..where((c) => c.id.equals(ch.id)))
            .getSingleOrNull();
        if (local == null || local.enabled) {
          toPurge.add((instanceId: ch.twistInstanceId, channelId: ch.channelId));
        }
      }
      result.add(row);
    }
    for (final p in toPurge) {
      await Link.hardDeleteForChannel(store, p.instanceId, p.channelId);
    }
    return result;
  }
}

class Channel extends Equatable {
  /// Cache for looking up channels by (twistInstanceId, channelId).
  /// Populated during sync.
  static final Map<String, Channel> _cache = {};

  /// Build a cache key from twistInstanceId + channelId.
  static String _cacheKey(Uuid ptId, String channelId) =>
      '${ptId.toString()}:$channelId';

  /// Look up a channel by twistInstanceId and channelId.
  static Channel? findByChannel(Uuid ptId, String channelId) =>
      _cache[_cacheKey(ptId, channelId)];

  /// Find any channel for a given connection account that has linkTypes.
  /// Used when a link doesn't have a channelId (legacy links synced before
  /// channel-level linkTypes were added).
  static Channel? findBySource(Uuid ptId) {
    final prefix = '${ptId.toString()}:';
    for (final entry in _cache.entries) {
      if (entry.key.startsWith(prefix) && entry.value.rawLinkTypes != null) {
        return entry.value;
      }
    }
    return null;
  }

  /// Populate the cache from a list of channels.
  static void populateCache(List<Channel> channels) {
    for (final sc in channels) {
      _cache[_cacheKey(sc.twistInstanceId, sc.channelId)] = sc;
    }
  }

  static Future<void> pull() async {
    // Without the update pull, Store.pull(initial: true) short-circuits
    // after the first run and new/updated channels never reach the client.
    await Store.get.pull(Store.get.channels, ChannelsBase(), initial: true);
    await Store.get.pull(Store.get.channels, ChannelsBase());
    // Refresh cache after pull
    final rows = await Store.get.select(Store.get.channels).get();
    _cache.clear();
    populateCache(rows.map((row) => Channel(row)).toList());
  }

  final ChannelRow _row;

  const Channel(this._row);

  BigInt get id => _row.id;
  Uuid get twistInstanceId => _row.twistInstanceId;
  String get channelId => _row.channelId;
  String get title => _row.title;
  bool get enabled => _row.enabled;
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

  /// Watch all source channels for a given source account (twist_instance).
  static Stream<List<Channel>> watchForSource(TwistInstanceId ptId) {
    return (Store.get.select(Store.get.channels)
          ..where((sc) => sc.twistInstanceId.equals(ptId.toBytes()))
          ..orderBy([(sc) => OrderingTerm.asc(sc.title)]))
        .watch()
        .map((rows) {
          final channels = rows.map((row) => Channel(row)).toList();
          populateCache(channels);
          return channels;
        });
  }

  /// Get all enabled source channels for a given source account.
  static Future<List<Channel>> getEnabledForSource(
      TwistInstanceId ptId) async {
    final rows = await (Store.get.select(Store.get.channels)
          ..where((sc) => sc.twistInstanceId.equals(ptId.toBytes()))
          ..where((sc) => sc.enabled.equals(true)))
        .get();
    final channels = rows.map((row) => Channel(row)).toList();
    populateCache(channels);
    return channels;
  }

  /// Get every enabled channel across all connections for the current user.
  /// Ordered by connection title then channel title for stable picker display.
  static Future<List<Channel>> getAllEnabled() async {
    final rows = await (Store.get.select(Store.get.channels)
          ..where((sc) => sc.enabled.equals(true))
          ..orderBy([(sc) => OrderingTerm.asc(sc.title)]))
        .get();
    final channels = rows.map((row) => Channel(row)).toList();
    populateCache(channels);
    return channels;
  }

  @override
  List<Object?> get props => [_row];
}
