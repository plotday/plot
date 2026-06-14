import 'package:equatable/equatable.dart';
import 'package:plot/store/types.dart' show AuthProvider;
import 'package:plot/util/value.dart';
import 'api.dart' as api;
import 'twist_permission.dart';

/// Represents an twist tool with its identifier
class TwistTool extends Equatable {
  final String id;

  const TwistTool({required this.id});

  factory TwistTool.fromJson(Map<String, dynamic> json) {
    return TwistTool(id: json['id'] as String);
  }

  Map<String, dynamic> toJson() {
    return {'id': id};
  }

  @override
  List<Object> get props => [id];
}

class Twist {
  final String id;
  final String? twistPackageId;
  final String name;
  final String? description;
  final String? authorName;
  final String? authorEmail;
  final String? authorUrl;
  final List<TwistTool> tools;
  final String environment;
  final bool isSource;
  final TwistPermissions? permissions;
  final Map<String, dynamic>? optionsSchema;
  final String? version;
  final String? logoUrl;
  final String? logoUrlDark;
  final List<AuthProvider> providers;

  /// Connector classification used to group connectors in the UI (e.g.
  /// 'messaging', 'calendar'). Null when the connector declares no category.
  final String? category;
  final bool aiRequired;
  final bool multipleInstances;

  /// True for "premium" connectors (Unipile-backed, real per-connection cost).
  /// Metered separately by the API via plan-specific premium policy.
  final bool premium;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const Twist({
    required this.id,
    this.twistPackageId,
    required this.name,
    this.description,
    this.authorName,
    this.authorEmail,
    this.authorUrl,
    required this.tools,
    required this.environment,
    this.isSource = false,
    this.permissions,
    this.optionsSchema,
    this.version,
    this.logoUrl,
    this.logoUrlDark,
    this.providers = const [],
    this.category,
    this.aiRequired = false,
    this.multipleInstances = false,
    this.premium = false,
    this.createdAt,
    this.updatedAt,
  });

  factory Twist.fromJson(Map<String, dynamic> json) {
    List<TwistTool> tools = [];
    final toolsRaw = json['tools'];

    if (toolsRaw != null) {
      if (toolsRaw is Map<String, dynamic>) {
        // Handle tools as map format: {"tool-id": {}}
        tools = toolsRaw.entries
            .map((entry) => TwistTool(id: entry.key))
            .toList();
      } else if (toolsRaw is List<dynamic>) {
        // Handle tools as list format: [{"id": "tool-id"}]
        tools = toolsRaw
            .map((tool) => TwistTool.fromJson(tool as Map<String, dynamic>))
            .toList();
      }
    }

    // Handle id as either int (bigint from database) or String
    final idValue = json['id'];
    final id = idValue is int ? idValue.toString() : idValue as String;

    // Extract metadata from permissions JSON
    final providers = <AuthProvider>[];
    final permsRaw = json['permissions'];
    final aiRequired = permsRaw is Map<String, dynamic>
        ? (permsRaw['_ai_required'] as bool? ?? false)
        : false;
    if (permsRaw is Map<String, dynamic>) {
      final providersRaw = permsRaw['_providers'];
      if (providersRaw is List) {
        for (final p in providersRaw) {
          if (p is Map<String, dynamic>) {
            final name = p['provider'] as String?;
            if (name != null) {
              providers.add(
                AuthProvider.values.firstWhere(
                  (v) => v.name == name,
                  orElse: () => AuthProvider.other,
                ),
              );
            }
          }
        }
      }
    }

    return Twist(
      id: id,
      twistPackageId: json['twist_package_id'] as String?,
      name: json['name'] as String,
      description: json['description'] as String?,
      authorName: json['author_name'] as String?,
      authorEmail: json['author_email'] as String?,
      authorUrl: json['author_url'] as String?,
      tools: tools,
      environment: json['environment'] as String? ?? 'public',
      isSource: json['is_source'] as bool? ?? false,
      permissions: json['permissions'] != null
          ? TwistPermissions.fromJson(
              json['permissions'] as Map<String, dynamic>,
            )
          : null,
      optionsSchema: json['options_schema'] as Map<String, dynamic>?,
      version: json['version'] as String?,
      logoUrl: json['logo_url'] as String?,
      logoUrlDark: json['logo_url_dark'] as String?,
      providers: providers,
      category: json['category'] as String?,
      aiRequired: aiRequired,
      multipleInstances: json['multiple_instances'] as bool? ?? false,
      premium: json['premium'] as bool? ?? false,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : null,
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
          : null,
    );
  }
}

class TwistApi {
  /// Get all available twists
  static Future<List<Twist>> getAllTwists() async {
    final twistsData = await api.get<List<dynamic>>('/twists');
    final twists = twistsData
        .map((json) => Twist.fromJson(json as Map<String, dynamic>))
        .toList();
    return twists;
  }

  /// Remove a twist from a priority
  static Future<void> removeTwist(String twistInstanceId) async {
    await api.delete<Map<String, dynamic>>('/twist/$twistInstanceId');
  }

  /// Archive all activities created by a twist and remove the twist
  static Future<void> archiveAndRemoveTwist(String twistInstanceId) async {
    await api.delete<Map<String, dynamic>>(
      '/twist/$twistInstanceId/archive-activities',
    );
  }

  /// Update a twist.
  ///
  /// `teamId` and `accountLabel` use `Value<String?>` so callers can pick
  /// between "unchanged" (`Value.absent()` — the default) and "set to this
  /// value, possibly null" (`Value(null)` to clear). A plain nullable would
  /// erase the distinction and silently drop clears, which previously left
  /// connections stranded under their old team scope when the user picked
  /// "Personal" in the setup form.
  static Future<void> updateTwist({
    required String twistInstanceId,
    String? name,
    Map<String, dynamic>? config,
    Value<String?> teamId = const Value.absent(),
    Value<String?> accountLabel = const Value.absent(),
  }) async {
    await api.patch<Map<String, dynamic>>(
      '/twist/$twistInstanceId',
      body: {
        'name': ?name,
        'config': ?config,
        if (teamId.present) 'teamId': teamId.value,
        if (accountLabel.present) 'accountLabel': accountLabel.value,
      },
    );
  }

  /// Add a workspace-level twist.
  static Future<String> addTwist({
    required String twistId,
    required String twistEnvironment,
    String? name,
    Map<String, dynamic>? config,
  }) async {
    final response = await api.post<Map<String, dynamic>>(
      '/twist',
      body: {
        'twistId': twistId,
        'twistEnvironment': twistEnvironment,
        'name': ?name,
        'config': ?config,
      },
    );

    return response['id'].toString();
  }

  /// Creates a draft twist. Returns the draft ID.
  static Future<String> createDraft({
    required String twistId,
    required String twistEnvironment,
    String? name,
  }) async {
    final response = await api.post<Map<String, dynamic>>(
      '/twist/draft',
      body: {
        'twistId': twistId,
        'twistEnvironment': twistEnvironment,
        'name': ?name,
      },
    );
    return response['id'].toString();
  }

  /// Activates the draft and enables selected channels.
  static Future<void> activateDraft({
    required String draftId,
    required String name,
    Map<String, dynamic>? config,
    List<Map<String, Object>>? channels,
    String? teamId,
  }) async {
    await api.post<Map<String, dynamic>>(
      '/twist/draft/$draftId/activate',
      body: {
        'name': name,
        'config': ?config,
        'syncables': ?channels,
        'teamId': ?teamId,
      },
    );
  }

  /// Deletes a draft twist and cleans up its storage.
  static Future<void> deleteDraft(String draftId) async {
    await api.delete<Map<String, dynamic>>('/twist/draft/$draftId');
  }

  /// Get integration data for the twist edit modal
  static Future<TwistIntegrations> getIntegrations(
    String twistInstanceId,
  ) async {
    final response = await api.get<Map<String, dynamic>>(
      '/twist/$twistInstanceId/integrations',
    );
    return TwistIntegrations.fromJson(response);
  }

  /// Generate an auth URL for a provider
  static Future<TwistAuthUrl> getAuthUrl({
    required String twistInstanceId,
    required String provider,
    required String redirectUri,
    String? platform,
    bool forceBridge = false,
    List<String>? enabledScopeGroups,
    String? accountHint,
  }) async {
    final response = await api.post<Map<String, dynamic>>(
      '/twist/$twistInstanceId/integrations/auth',
      body: {
        'provider': provider,
        'redirectUri': redirectUri,
        'platform': ?platform,
        if (forceBridge) 'forceBridge': true,
        'enabledScopeGroups': ?enabledScopeGroups,
        'accountHint': ?accountHint,
      },
    );
    return TwistAuthUrl.fromJson(response);
  }

  /// Remove an integration account
  static Future<void> removeIntegration({
    required String twistInstanceId,
    required String provider,
    required String actorId,
  }) async {
    await api.delete<Map<String, dynamic>>(
      '/twist/$twistInstanceId/integrations/$provider/$actorId',
    );
  }

  /// Enable a channel resource
  static Future<void> enableChannel({
    required String twistInstanceId,
    required String provider,
    required String channelId,
  }) async {
    await api.post<Map<String, dynamic>>(
      '/twist/$twistInstanceId/syncables/$provider/$channelId/enable',
      body: const <String, dynamic>{},
    );
  }

  /// Disable a channel resource
  static Future<void> disableChannel({
    required String twistInstanceId,
    required String provider,
    required String channelId,
  }) async {
    await api.post<Map<String, dynamic>>(
      '/twist/$twistInstanceId/syncables/$provider/$channelId/disable',
    );
  }

  /// Apply a batch of channel enable/disable operations in a single request.
  /// Server reuses one twist wrapper for the whole batch — avoids per-channel
  /// round-trips and DO spin-ups.
  ///
  /// Each entry is `{ 'provider': ..., 'syncableId': ... }`.
  static Future<void> applyChannelsBatch({
    required String twistInstanceId,
    List<Map<String, String>> enable = const [],
    List<Map<String, String>> disable = const [],
  }) async {
    if (enable.isEmpty && disable.isEmpty) return;
    await api.post<Map<String, dynamic>>(
      '/twist/$twistInstanceId/syncables/batch',
      body: <String, dynamic>{
        if (enable.isNotEmpty) 'enable': enable,
        if (disable.isNotEmpty) 'disable': disable,
      },
    );
  }

  /// Set the per-connection "sync new channels" flag.
  /// When true, channels discovered for the first time during a periodic
  /// refresh are enabled automatically.
  static Future<void> setAutoEnableNewChannels({
    required String twistInstanceId,
    required String provider,
    required String actorId,
    required bool enabled,
  }) async {
    await api.post<Map<String, dynamic>>(
      '/twist/$twistInstanceId/syncables/$provider/auto-enable',
      body: {'actorId': actorId, 'enabled': enabled},
    );
  }

  /// Get available source channels for link observation
  static Future<List<LinkChannel>> getAvailableLinkChannels(
    String twistInstanceId,
  ) async {
    final response = await api.get<List<dynamic>>(
      '/twist/$twistInstanceId/available-link-channels',
    );
    return response
        .map((json) => LinkChannel.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Get connected link channels for a twist
  static Future<List<ConnectedLinkChannel>> getLinkChannels(
    String twistInstanceId,
  ) async {
    final response = await api.get<List<dynamic>>(
      '/twist/$twistInstanceId/link-channels',
    );
    return response
        .map(
          (json) => ConnectedLinkChannel.fromJson(json as Map<String, dynamic>),
        )
        .toList();
  }

  /// Update link channel connections for a twist
  static Future<void> updateLinkChannels({
    required String twistInstanceId,
    required List<Map<String, dynamic>> channels,
  }) async {
    await api.put<Map<String, dynamic>>(
      '/twist/$twistInstanceId/link-channels',
      body: channels,
    );
  }

  /// Get all connected sources for the current user
  static Future<List<Map<String, dynamic>>> getUserSources() async {
    final response = await api.get<List<dynamic>>('/sources');
    return response.cast<Map<String, dynamic>>();
  }

  /// Get source summaries with account info and enabled channel counts.
  /// Optimized for the Connections modal list view.
  static Future<List<SourceSummary>> getSourcesSummary() async {
    final response = await api.get<List<dynamic>>('/sources/summary');
    return response
        .cast<Map<String, dynamic>>()
        .map((json) => SourceSummary.fromJson(json))
        .toList();
  }


  /// Get upcoming connections with vote counts
  static Future<
    ({List<UpcomingConnection> connections, Set<String> votedByUser})
  >
  getUpcomingConnections() async {
    final response = await api.get<Map<String, dynamic>>(
      '/connections/upcoming',
    );
    final connections = (response['connections'] as List<dynamic>)
        .map(
          (json) => UpcomingConnection.fromJson(json as Map<String, dynamic>),
        )
        .toList();
    final votedByUser = (response['votedByUser'] as List<dynamic>)
        .cast<String>()
        .toSet();
    return (connections: connections, votedByUser: votedByUser);
  }

  /// Vote for an upcoming connection, returns new vote count
  static Future<int> voteForConnection(String name) async {
    final response = await api.post<Map<String, dynamic>>(
      '/connections/vote',
      body: {'name': name},
    );
    return response['votes'] as int;
  }

  /// Connect a no-provider connector. Saves options and returns channels.
  static Future<TwistConnectResult> connectNoProvider({
    required String twistInstanceId,
    required Map<String, dynamic> options,
  }) async {
    final response = await api.post<Map<String, dynamic>>(
      '/twist/$twistInstanceId/integrations/connect',
      body: {'options': options},
    );

    if (response.containsKey('error')) {
      return TwistConnectResult(error: response['error'] as String);
    }

    final syncables = (response['syncables'] as List<dynamic>)
        .map((s) => TwistChannel.fromJson(s as Map<String, dynamic>))
        .toList();
    final accountName = response['accountName'] as String?;
    return TwistConnectResult(
      syncables: syncables,
      accountName: accountName,
    );
  }

  /// Re-fetch the channel list from the external service for a provider.
  static Future<void> refreshChannels({
    required String twistInstanceId,
    required String provider,
  }) async {
    await api.post<Map<String, dynamic>>(
      '/twist/$twistInstanceId/syncables/$provider/refresh',
    );
  }
}

/// Summary of a connected source for the Connections modal list view.
class SourceSummary {
  final String id; // twist_instance_id
  final String? twistId; // underlying twist.id (nullable for backwards compat)
  final String? twistPackageId; // stable connector package UUID
  final String name;
  final String? twistName;
  final String? logoUrl;
  final String? logoUrlDark;
  final String? accountLabel;
  final AuthProvider? provider;
  final int enabledCount;
  final String? teamId;
  final String? teamName;
  final bool premium;

  const SourceSummary({
    required this.id,
    this.twistId,
    this.twistPackageId,
    required this.name,
    this.twistName,
    this.logoUrl,
    this.logoUrlDark,
    this.accountLabel,
    this.provider,
    required this.enabledCount,
    this.teamId,
    this.teamName,
    this.premium = false,
  });

  factory SourceSummary.fromJson(Map<String, dynamic> json) {
    final providerStr = json['provider'] as String?;
    final twistIdRaw = json['twist_id'];
    return SourceSummary(
      id: json['id'] as String,
      twistId: twistIdRaw is int
          ? twistIdRaw.toString()
          : twistIdRaw as String?,
      twistPackageId: json['twist_package_id'] as String?,
      name: json['name'] as String,
      twistName: json['twist_name'] as String?,
      logoUrl: json['logo_url'] as String?,
      logoUrlDark: json['logo_url_dark'] as String?,
      accountLabel: json['account_label'] as String?,
      provider: providerStr != null
          ? AuthProvider.values.firstWhere(
              (v) => v.name == providerStr,
              orElse: () => AuthProvider.other,
            )
          : null,
      enabledCount: json['enabled_count'] as int? ?? 0,
      teamId: json['team_id'] as String?,
      teamName: json['team_name'] as String?,
      premium: json['premium'] as bool? ?? false,
    );
  }
}

/// An upcoming connection not yet available as a source
class UpcomingConnection {
  final String name;
  final String logo;
  final String? logoDark;
  final String category;
  final List<String> entities;
  final String? description;
  final int votes;

  const UpcomingConnection({
    required this.name,
    required this.logo,
    this.logoDark,
    required this.category,
    required this.entities,
    this.description,
    required this.votes,
  });

  factory UpcomingConnection.fromJson(Map<String, dynamic> json) {
    return UpcomingConnection(
      name: json['name'] as String,
      logo: json['logo'] as String,
      logoDark: json['logoDark'] as String?,
      category: json['category'] as String,
      entities: (json['entities'] as List<dynamic>).cast<String>(),
      description: json['description'] as String?,
      votes: json['votes'] as int? ?? 0,
    );
  }
}

/// A source channel available for link observation
class LinkChannel {
  final String channelId;
  final String title;
  final String sourceTwistInstanceId;
  final String sourceName;
  final String? accountName;
  final String? logoUrl;
  final String? logoUrlDark;

  const LinkChannel({
    required this.channelId,
    required this.title,
    required this.sourceTwistInstanceId,
    required this.sourceName,
    this.accountName,
    this.logoUrl,
    this.logoUrlDark,
  });

  factory LinkChannel.fromJson(Map<String, dynamic> json) {
    return LinkChannel(
      channelId: json['channel_id'] as String,
      title: json['title'] as String,
      sourceTwistInstanceId: json['source_twist_instance_id'] as String,
      sourceName: json['source_name'] as String,
      accountName: json['account_name'] as String?,
      logoUrl: json['logo_url'] as String?,
      logoUrlDark: json['logo_url_dark'] as String?,
    );
  }
}

/// A connected link channel for a twist
class ConnectedLinkChannel {
  final int id;
  final String sourceTwistInstanceId;
  final String channelId;
  final bool enabled;
  final String title;
  final String sourceName;
  final String? accountName;

  const ConnectedLinkChannel({
    required this.id,
    required this.sourceTwistInstanceId,
    required this.channelId,
    required this.enabled,
    required this.title,
    required this.sourceName,
    this.accountName,
  });

  factory ConnectedLinkChannel.fromJson(Map<String, dynamic> json) {
    return ConnectedLinkChannel(
      id: json['id'] as int,
      sourceTwistInstanceId: json['source_twist_instance_id'] as String,
      channelId: json['channel_id'] as String,
      enabled: json['enabled'] as bool,
      title: json['title'] as String,
      sourceName: json['source_name'] as String,
      accountName: json['account_name'] as String?,
    );
  }
}

/// Auth URL result from the integrations auth endpoint
class TwistAuthUrl {
  final String url;
  final String clientId;
  final String state;
  final String callback;

  const TwistAuthUrl({
    required this.url,
    required this.clientId,
    required this.state,
    required this.callback,
  });

  factory TwistAuthUrl.fromJson(Map<String, dynamic> json) {
    return TwistAuthUrl(
      url: json['url'] as String,
      clientId: json['clientId'] as String,
      state: json['state'] as String,
      callback: json['callback'] as String,
    );
  }
}

/// An optional scope group that users can toggle before OAuth.
class OptionalScopeGroup extends Equatable {
  final String id;
  final String label;
  final String? description;
  final List<String> scopes;
  final bool defaultEnabled;

  const OptionalScopeGroup({
    required this.id,
    required this.label,
    this.description,
    required this.scopes,
    required this.defaultEnabled,
  });

  factory OptionalScopeGroup.fromJson(Map<String, dynamic> json) {
    return OptionalScopeGroup(
      id: json['id'] as String,
      label: json['label'] as String,
      description: json['description'] as String?,
      scopes: (json['scopes'] as List<dynamic>).cast<String>(),
      defaultEnabled: json['default'] as bool? ?? false,
    );
  }

  @override
  List<Object?> get props => [id, label, description, scopes, defaultEnabled];
}

/// Result from connecting a no-provider connector
class TwistConnectResult {
  final List<TwistChannel>? syncables;
  final String? accountName;
  final String? error;

  const TwistConnectResult({this.syncables, this.accountName, this.error});

  bool get isError => error != null;
}

/// The user-facing noun a connector uses for its channels (e.g. "folder" /
/// "folders", "project" / "projects"). Falls back to "channel" / "channels"
/// when the connector declares none.
class ChannelNoun extends Equatable {
  final String singular;
  final String plural;

  const ChannelNoun({required this.singular, required this.plural});

  static const ChannelNoun fallback =
      ChannelNoun(singular: 'channel', plural: 'channels');

  static ChannelNoun fromJson(Map<String, dynamic>? json) {
    if (json == null) return fallback;
    final singular = json['singular'] as String?;
    final plural = json['plural'] as String?;
    if (singular == null || plural == null) return fallback;
    return ChannelNoun(singular: singular, plural: plural);
  }

  @override
  List<Object?> get props => [singular, plural];
}

/// Integration data for a twist
class TwistIntegrations {
  final List<TwistProvider> providers;
  final List<TwistAccount> accounts;
  final List<TwistChannel> channels;

  /// Options schema for no-provider connectors (null for OAuth connectors).
  final Map<String, dynamic>? optionsSchema;

  /// Current option values for no-provider connectors (secure values masked).
  final Map<String, dynamic>? optionsConfig;

  /// Plain-language "what you're granting" bullets for credential (no-provider)
  /// connectors. Null for OAuth connectors (those carry it per-provider).
  final List<String>? access;

  /// When true, this connector has a single implicit channel.
  /// The UI shows channel config inline instead of a channel list.
  final bool singleChannel;

  /// The connector's user-facing noun for its channels (folders, projects,
  /// calendars, …). Drives the "Sync new {plural}" copy. Defaults to
  /// "channel" / "channels".
  final ChannelNoun channelNoun;

  /// When true, this connector uses a shared credential for all users.
  final bool shared;

  /// The Options field name containing the auth key (for key-based connectors).
  final String? keyOption;

  /// Maps teamId → list of email domains for that team.
  /// Used for smart channel default suggestions.
  final Map<int, List<String>>? teamDomains;

  /// Per-connection disambiguator from twist_instance.account_label. Fetched
  /// fresh from the server so clients don't depend on local-sync timing when
  /// populating the Label field for a newly activated connection.
  final String? accountLabel;

  /// Name of the team owning this instance (null for personal).
  final String? teamName;

  /// True for "premium" connectors (Unipile-backed). Carried here so the
  /// EditSource form can route to a premium-specific upgrade prompt on save.
  final bool premium;

  const TwistIntegrations({
    required this.providers,
    required this.accounts,
    required this.channels,
    this.optionsSchema,
    this.optionsConfig,
    this.access,
    this.singleChannel = false,
    this.channelNoun = ChannelNoun.fallback,
    this.shared = false,
    this.keyOption,
    this.teamDomains,
    this.accountLabel,
    this.teamName,
    this.premium = false,
  });

  factory TwistIntegrations.fromJson(Map<String, dynamic> json) {
    return TwistIntegrations(
      providers: (json['providers'] as List<dynamic>)
          .map((p) => TwistProvider.fromJson(p as Map<String, dynamic>))
          .toList(),
      accounts: (json['accounts'] as List<dynamic>)
          .map((a) => TwistAccount.fromJson(a as Map<String, dynamic>))
          .toList(),
      channels: (json['syncables'] as List<dynamic>)
          .map((s) => TwistChannel.fromJson(s as Map<String, dynamic>))
          .toList(),
      optionsSchema: json['optionsSchema'] as Map<String, dynamic>?,
      optionsConfig: json['optionsConfig'] as Map<String, dynamic>?,
      access: (json['access'] as List<dynamic>?)?.cast<String>(),
      singleChannel: json['singleChannel'] as bool? ?? false,
      channelNoun: ChannelNoun.fromJson(
        json['channelNoun'] as Map<String, dynamic>?,
      ),
      shared: json['shared'] as bool? ?? false,
      keyOption: json['keyOption'] as String?,
      teamDomains: _parseTeamDomains(
        json['teamDomains'],
      ),
      accountLabel: json['accountLabel'] as String?,
      teamName: json['teamName'] as String?,
      premium: json['premium'] as bool? ?? false,
    );
  }

  bool get isEmpty => providers.isEmpty && channels.isEmpty;

  static Map<int, List<String>>? _parseTeamDomains(dynamic raw) {
    if (raw is! Map) return null;
    final result = <int, List<String>>{};
    for (final entry in raw.entries) {
      final orgId = int.tryParse(entry.key.toString());
      if (orgId == null) continue;
      final domains = (entry.value as List<dynamic>).cast<String>();
      result[orgId] = domains;
    }
    return result.isEmpty ? null : result;
  }
}

/// A provider configuration for a twist
class TwistProvider extends Equatable {
  final AuthProvider provider;
  final List<String> scopes;

  /// Plain-language bullets describing what connecting this service grants.
  final List<String> access;
  final List<OptionalScopeGroup>? optionalScopes;

  const TwistProvider({
    required this.provider,
    required this.scopes,
    this.access = const [],
    this.optionalScopes,
  });

  factory TwistProvider.fromJson(Map<String, dynamic> json) {
    return TwistProvider(
      provider: AuthProvider.values.firstWhere(
        (v) => v.name == json['provider'],
        orElse: () => AuthProvider.other,
      ),
      scopes: (json['scopes'] as List<dynamic>).cast<String>(),
      // Back-compat: older servers send `description`.
      access:
          (json['access'] as List<dynamic>?)?.cast<String>() ??
          (json['description'] as List<dynamic>?)?.cast<String>() ??
          const [],
      optionalScopes: (json['optionalScopes'] as List<dynamic>?)
          ?.map((g) => OptionalScopeGroup.fromJson(g as Map<String, dynamic>))
          .toList(),
    );
  }

  @override
  List<Object?> get props => [provider, scopes, access, optionalScopes];
}

/// A connected account for a twist integration
class TwistAccount extends Equatable {
  final AuthProvider provider;
  final String actorId;
  final String? email;
  final String? name;
  final bool autoEnableNewChannels;

  /// External URL where the user manages app authorization for this provider
  /// (e.g. GitHub's per-app connection page where org access is granted).
  /// Null when no actionable external page exists.
  final String? manageAccessUrl;

  const TwistAccount({
    required this.provider,
    required this.actorId,
    this.email,
    this.name,
    this.autoEnableNewChannels = false,
    this.manageAccessUrl,
  });

  factory TwistAccount.fromJson(Map<String, dynamic> json) {
    return TwistAccount(
      provider: AuthProvider.values.firstWhere(
        (v) => v.name == json['provider'],
        orElse: () => AuthProvider.other,
      ),
      actorId: json['actorId'] as String,
      email: json['email'] as String?,
      name: json['name'] as String?,
      autoEnableNewChannels: json['autoEnableNewChannels'] as bool? ?? false,
      manageAccessUrl: json['manageAccessUrl'] as String?,
    );
  }

  String get displayName => name ?? email ?? actorId;

  @override
  List<Object?> get props =>
      [provider, actorId, email, name, autoEnableNewChannels, manageAccessUrl];
}

/// A channel resource for a twist integration
/// Describes a link type that a connector creates (e.g., "Issue", "Pull Request").
class TwistLinkType extends Equatable {
  final String type;
  final String label;
  final String? defaultCreateThreads;

  const TwistLinkType({
    required this.type,
    required this.label,
    this.defaultCreateThreads,
  });

  factory TwistLinkType.fromJson(Map<String, dynamic> json) {
    return TwistLinkType(
      type: json['type'] as String,
      label: json['label'] as String,
      defaultCreateThreads: json['defaultCreateThreads'] as String?,
    );
  }

  @override
  List<Object?> get props => [type, label, defaultCreateThreads];
}

class TwistChannel extends Equatable {
  final AuthProvider provider;

  /// Raw provider string from the API (e.g., "_options" for no-provider connectors).
  /// Use this for API calls instead of provider.name.
  final String providerKey;

  final String id;
  final String title;

  /// Connector's tri-state hint for whether this channel should be selected by
  /// default when the connection is first added: `true` = pre-select, `false`
  /// = exclude (low-value/irrelevant), `null` = let the client decide. Drives
  /// the setup UI's default selection — see [ChannelDefaultSuggester].
  final bool? enabledByDefault;

  final bool enabled;
  final String? enabledBy;
  final List<TwistLinkType> linkTypes;
  final bool currentUserHasAccess;
  final List<TwistChannel> children;

  const TwistChannel({
    required this.provider,
    required this.providerKey,
    required this.id,
    required this.title,
    this.enabledByDefault,
    required this.enabled,
    this.enabledBy,
    this.linkTypes = const [],
    required this.currentUserHasAccess,
    this.children = const [],
  });

  factory TwistChannel.fromJson(Map<String, dynamic> json) {
    final providerStr = json['provider'] as String? ?? 'other';
    return TwistChannel(
      provider: AuthProvider.values.firstWhere(
        (v) => v.name == providerStr,
        orElse: () => AuthProvider.other,
      ),
      providerKey: providerStr,
      id: json['id'] as String,
      title: json['title'] as String,
      enabledByDefault: json['enabledByDefault'] as bool?,
      enabled: json['enabled'] as bool? ?? false,
      enabledBy: json['enabledBy'] as String?,
      linkTypes: (json['linkTypes'] as List<dynamic>?)
              ?.map(
                (lt) => TwistLinkType.fromJson(lt as Map<String, dynamic>),
              )
              .toList() ??
          const [],
      currentUserHasAccess: json['currentUserHasAccess'] as bool? ?? true,
      children:
          (json['children'] as List<dynamic>?)
              ?.map((c) => TwistChannel.fromJson(c as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }

  bool get hasChildren => children.isNotEmpty;

  @override
  List<Object?> get props => [
    provider,
    providerKey,
    id,
    title,
    enabledByDefault,
    enabled,
    enabledBy,
    linkTypes,
    currentUserHasAccess,
    children,
  ];
}
