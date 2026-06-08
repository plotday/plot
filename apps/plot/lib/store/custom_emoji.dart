part of 'store.dart';

/// Local cache of workspace-custom emoji discovered on chat platforms
/// (e.g. Slack `:party_parrot:`, Google Chat workspace emoji). One row per
/// custom emoji; the `id` mirrors the server format
/// `<provider>:<workspace_id>/<name>` so reactions in [Reactions] can refer
/// to it directly.
///
/// Strictly a client-side cache populated by `/sync/custom-emoji` — clients
/// never write to this table.
@DataClassName('CustomEmojiRow')
class CustomEmojis extends Table with SyncableTable, DeletableTable {
  TextColumn get id => text()();
  TextColumn get provider => text()();
  TextColumn get workspaceId => text()();
  TextColumn get name => text()();
  TextColumn get imageUrl => text()();
  TextColumn get aliasOf => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class CustomEmojisBase extends BaseTable {
  CustomEmojisBase()
    : super(
        table: 'custom_emoji',
        syncEndpoint: 'custom-emoji',
        name: 'custom_emoji',
        order: 'updated_at',
        ascending: false,
      );

  @override
  Insertable<CustomEmojiRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    json.remove('sync_depth');
    json.remove('seq');
    return CustomEmojiRow.fromJson(json);
  }
}

/// Query helpers for the [CustomEmojis] cache.
class CustomEmoji {
  CustomEmoji._();

  /// Non-archived custom emoji belonging to a connection's opaque scope token
  /// (their `id` is `<scope>/<name>`). The scope is treated as an opaque
  /// prefix — no provider/workspace parsing. Used by the reaction picker to
  /// offer "this connection's custom emoji".
  static Future<List<CustomEmojiRow>> forScope(String scope) async {
    if (!Store.isAvailable) return const [];
    return (Store.get.select(Store.get.customEmojis)
          ..where((t) => t.id.like('$scope/%') & t.archivedAt.isNull()))
        .get();
  }
}
