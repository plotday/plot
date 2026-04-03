import 'package:equatable/equatable.dart';
import 'package:plot/store/store.dart';
import 'package:plot/store/types.dart' show AuthProvider;
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
  final String name;
  final String? description;
  final String? authorName;
  final String? authorEmail;
  final String? authorUrl;
  final List<TwistTool> tools;
  final String environment;
  final bool isSource;
  final TwistPermissions? permissions;
  final Map<String, dynamic>? options;
  final String? version;
  final String? logoUrl;
  final String? logoUrlDark;
  final List<AuthProvider> providers;
  final bool aiRequired;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const Twist({
    required this.id,
    required this.name,
    this.description,
    this.authorName,
    this.authorEmail,
    this.authorUrl,
    required this.tools,
    required this.environment,
    this.isSource = false,
    this.permissions,
    this.options,
    this.version,
    this.logoUrl,
    this.logoUrlDark,
    this.providers = const [],
    this.aiRequired = false,
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
      options: json['options'] as Map<String, dynamic>?,
      version: json['version'] as String?,
      logoUrl: json['logo_url'] as String?,
      logoUrlDark: json['logo_url_dark'] as String?,
      providers: providers,
      aiRequired: aiRequired,
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
  /// Get all available twists for a priority
  static Future<List<Twist>> getAllTwists(Priority priority) async {
    final twistsData = await api.get<List<dynamic>>(
      '/twists?priorityId=${priority.id.toString()}',
    );
    final twists = twistsData
        .map((json) => Twist.fromJson(json as Map<String, dynamic>))
        .toList();
    return twists;
  }

  /// Remove a twist from a priority
  static Future<void> removeTwist(String priorityTwistId) async {
    await api.delete<Map<String, dynamic>>('/twist/$priorityTwistId');
  }

  /// Archive all activities created by a twist and remove the twist
  static Future<void> archiveAndRemoveTwist(String priorityTwistId) async {
    await api.delete<Map<String, dynamic>>(
      '/twist/$priorityTwistId/archive-activities',
    );
  }

  /// Update a twist
  static Future<void> updateTwist({
    required String priorityTwistId,
    String? name,
    Map<String, dynamic>? config,
  }) async {
    await api.patch<Map<String, dynamic>>(
      '/twist/$priorityTwistId',
      body: {
        if (name != null) 'name': name,
        if (config != null) 'config': config,
      },
    );
  }

  /// Add a twist to a priority
  static Future<String> addTwist({
    required String priorityId,
    required String twistId,
    required String twistEnvironment,
    String? name,
    Map<String, dynamic>? config,
  }) async {
    final response = await api.post<Map<String, dynamic>>(
      '/twist',
      body: {
        'priorityId': priorityId,
        'twistId': twistId,
        'twistEnvironment': twistEnvironment,
        if (name != null) 'name': name,
        if (config != null) 'config': config,
      },
    );

    return response['id'].toString();
  }

  /// Creates a draft twist with priority_id = NULL. Returns the draft ID.
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
        if (name != null) 'name': name,
      },
    );
    return response['id'].toString();
  }

  /// Assigns priority, activates the draft, and enables selected channels.
  /// [priorityId] is optional for sources (account-level, no priority needed).
  static Future<void> activateDraft({
    required String draftId,
    String? priorityId,
    required String name,
    Map<String, dynamic>? config,
    List<Map<String, String>>? channels,
  }) async {
    await api.post<Map<String, dynamic>>(
      '/twist/draft/$draftId/activate',
      body: {
        if (priorityId != null) 'priorityId': priorityId,
        'name': name,
        if (config != null) 'config': config,
        if (channels != null) 'syncables': channels,
      },
    );
  }

  /// Deletes a draft twist and cleans up its storage.
  static Future<void> deleteDraft(String draftId) async {
    await api.delete<Map<String, dynamic>>('/twist/draft/$draftId');
  }

  /// Get integration data for the twist edit modal
  static Future<TwistIntegrations> getIntegrations(
    String priorityTwistId,
  ) async {
    final response = await api.get<Map<String, dynamic>>(
      '/twist/$priorityTwistId/integrations',
    );
    return TwistIntegrations.fromJson(response);
  }

  /// Generate an auth URL for a provider
  static Future<TwistAuthUrl> getAuthUrl({
    required String priorityTwistId,
    required String provider,
    required String redirectUri,
    String? platform,
    List<String>? enabledScopeGroups,
  }) async {
    final response = await api.post<Map<String, dynamic>>(
      '/twist/$priorityTwistId/integrations/auth',
      body: {
        'provider': provider,
        'redirectUri': redirectUri,
        if (platform != null) 'platform': platform,
        if (enabledScopeGroups != null)
          'enabledScopeGroups': enabledScopeGroups,
      },
    );
    return TwistAuthUrl.fromJson(response);
  }

  /// Remove an integration account
  static Future<void> removeIntegration({
    required String priorityTwistId,
    required String provider,
    required String actorId,
  }) async {
    await api.delete<Map<String, dynamic>>(
      '/twist/$priorityTwistId/integrations/$provider/$actorId',
    );
  }

  /// Enable a channel resource
  static Future<void> enableChannel({
    required String priorityTwistId,
    required String provider,
    required String channelId,
    String? priorityId,
    String? createThreads,
    Map<String, String>? createThreadsByType,
  }) async {
    await api.post<Map<String, dynamic>>(
      '/twist/$priorityTwistId/syncables/$provider/$channelId/enable',
      body: {
        if (priorityId != null) 'priorityId': priorityId,
        if (createThreads != null) 'createThreads': createThreads,
        if (createThreadsByType != null)
          'createThreadsByType': createThreadsByType,
      },
    );
  }

  /// Disable a channel resource
  static Future<void> disableChannel({
    required String priorityTwistId,
    required String provider,
    required String channelId,
  }) async {
    await api.post<Map<String, dynamic>>(
      '/twist/$priorityTwistId/syncables/$provider/$channelId/disable',
    );
  }

  /// Get available source channels for link observation
  static Future<List<LinkChannel>> getAvailableLinkChannels(
    String priorityTwistId, {
    String? priorityId,
  }) async {
    final query = priorityId != null ? '?priorityId=$priorityId' : '';
    final response = await api.get<List<dynamic>>(
      '/twist/$priorityTwistId/available-link-channels$query',
    );
    return response
        .map((json) => LinkChannel.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Get connected link channels for a twist
  static Future<List<ConnectedLinkChannel>> getLinkChannels(
    String priorityTwistId,
  ) async {
    final response = await api.get<List<dynamic>>(
      '/twist/$priorityTwistId/link-channels',
    );
    return response
        .map(
          (json) => ConnectedLinkChannel.fromJson(json as Map<String, dynamic>),
        )
        .toList();
  }

  /// Update link channel connections for a twist
  static Future<void> updateLinkChannels({
    required String priorityTwistId,
    required List<Map<String, dynamic>> channels,
  }) async {
    await api.put<Map<String, dynamic>>(
      '/twist/$priorityTwistId/link-channels',
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

  /// Update the priority routing for a channel
  /// Update channel config (priority, createThreads, createThreadsByType).
  static Future<void> updateChannel({
    required String priorityTwistId,
    required String provider,
    required String channelId,
    String? priorityId,
    String? createThreads,
    Map<String, String>? createThreadsByType,
  }) async {
    await api.patch<Map<String, dynamic>>(
      '/twist/$priorityTwistId/syncables/$provider/$channelId',
      body: {
        if (priorityId != null) 'priorityId': priorityId,
        if (createThreads != null) 'createThreads': createThreads,
        if (createThreadsByType != null)
          'createThreadsByType': createThreadsByType,
      },
    );
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
    required String priorityTwistId,
    required Map<String, dynamic> options,
  }) async {
    final response = await api.post<Map<String, dynamic>>(
      '/twist/$priorityTwistId/integrations/connect',
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
    required String priorityTwistId,
    required String provider,
  }) async {
    await api.post<Map<String, dynamic>>(
      '/twist/$priorityTwistId/syncables/$provider/refresh',
    );
  }
}

/// Summary of a connected source for the Connections modal list view.
class SourceSummary {
  final String id; // priority_twist_id
  final String name;
  final String? logoUrl;
  final String? logoUrlDark;
  final String? accountName;
  final String? accountEmail;
  final AuthProvider? provider;
  final int enabledCount;

  const SourceSummary({
    required this.id,
    required this.name,
    this.logoUrl,
    this.logoUrlDark,
    this.accountName,
    this.accountEmail,
    this.provider,
    required this.enabledCount,
  });

  factory SourceSummary.fromJson(Map<String, dynamic> json) {
    final providerStr = json['provider'] as String?;
    return SourceSummary(
      id: json['id'] as String,
      name: json['name'] as String,
      logoUrl: json['logo_url'] as String?,
      logoUrlDark: json['logo_url_dark'] as String?,
      accountName: json['account_name'] as String?,
      accountEmail: json['account_email'] as String?,
      provider: providerStr != null
          ? AuthProvider.values.firstWhere(
              (v) => v.name == providerStr,
              orElse: () => AuthProvider.other,
            )
          : null,
      enabledCount: json['enabled_count'] as int? ?? 0,
    );
  }

  /// Display name matching the existing TwistAccount.displayName pattern.
  String? get displayName => accountName ?? accountEmail;
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
  final String sourcePriorityTwistId;
  final String sourceName;
  final String? accountName;
  final String? logoUrl;
  final String? logoUrlDark;

  const LinkChannel({
    required this.channelId,
    required this.title,
    required this.sourcePriorityTwistId,
    required this.sourceName,
    this.accountName,
    this.logoUrl,
    this.logoUrlDark,
  });

  factory LinkChannel.fromJson(Map<String, dynamic> json) {
    return LinkChannel(
      channelId: json['channel_id'] as String,
      title: json['title'] as String,
      sourcePriorityTwistId: json['source_priority_twist_id'] as String,
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
  final String sourcePriorityTwistId;
  final String channelId;
  final bool enabled;
  final String title;
  final String sourceName;
  final String? accountName;

  const ConnectedLinkChannel({
    required this.id,
    required this.sourcePriorityTwistId,
    required this.channelId,
    required this.enabled,
    required this.title,
    required this.sourceName,
    this.accountName,
  });

  factory ConnectedLinkChannel.fromJson(Map<String, dynamic> json) {
    return ConnectedLinkChannel(
      id: json['id'] as int,
      sourcePriorityTwistId: json['source_priority_twist_id'] as String,
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

/// Integration data for a twist
class TwistIntegrations {
  final List<TwistProvider> providers;
  final List<TwistAccount> accounts;
  final List<TwistChannel> channels;

  /// Options schema for no-provider connectors (null for OAuth connectors).
  final Map<String, dynamic>? optionsSchema;

  /// Current option values for no-provider connectors (secure values masked).
  final Map<String, dynamic>? optionsConfig;

  /// When true, this connector has a single implicit channel.
  /// The UI shows channel config inline instead of a channel list.
  final bool singleChannel;

  /// When true, this connector uses a shared credential for all users.
  final bool shared;

  /// The Options field name containing the auth key (for key-based connectors).
  final String? keyOption;

  const TwistIntegrations({
    required this.providers,
    required this.accounts,
    required this.channels,
    this.optionsSchema,
    this.optionsConfig,
    this.singleChannel = false,
    this.shared = false,
    this.keyOption,
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
      singleChannel: json['singleChannel'] as bool? ?? false,
      shared: json['shared'] as bool? ?? false,
      keyOption: json['keyOption'] as String?,
    );
  }

  bool get isEmpty => providers.isEmpty && channels.isEmpty;
}

/// A provider configuration for a twist
class TwistProvider extends Equatable {
  final AuthProvider provider;
  final List<String> scopes;
  final List<OptionalScopeGroup>? optionalScopes;

  const TwistProvider({
    required this.provider,
    required this.scopes,
    this.optionalScopes,
  });

  factory TwistProvider.fromJson(Map<String, dynamic> json) {
    return TwistProvider(
      provider: AuthProvider.values.firstWhere(
        (v) => v.name == json['provider'],
        orElse: () => AuthProvider.other,
      ),
      scopes: (json['scopes'] as List<dynamic>).cast<String>(),
      optionalScopes: (json['optionalScopes'] as List<dynamic>?)
          ?.map((g) => OptionalScopeGroup.fromJson(g as Map<String, dynamic>))
          .toList(),
    );
  }

  @override
  List<Object?> get props => [provider, scopes, optionalScopes];
}

/// A connected account for a twist integration
class TwistAccount extends Equatable {
  final AuthProvider provider;
  final String actorId;
  final String? email;
  final String? name;

  const TwistAccount({
    required this.provider,
    required this.actorId,
    this.email,
    this.name,
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
    );
  }

  String get displayName => name ?? email ?? actorId;

  @override
  List<Object?> get props => [provider, actorId, email, name];
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
  final bool enabled;
  final String? enabledBy;
  final String? priorityId;
  final String createThreads;
  final Map<String, String> createThreadsByType;
  final List<TwistLinkType> linkTypes;
  final bool currentUserHasAccess;
  final List<TwistChannel> children;

  const TwistChannel({
    required this.provider,
    required this.providerKey,
    required this.id,
    required this.title,
    required this.enabled,
    this.enabledBy,
    this.priorityId,
    this.createThreads = 'all',
    this.createThreadsByType = const {},
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
      enabled: json['enabled'] as bool? ?? false,
      enabledBy: json['enabledBy'] as String?,
      priorityId: json['priorityId'] as String?,
      createThreads: json['createThreads'] as String? ?? 'all',
      createThreadsByType: (json['createThreadsByType'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v as String)) ??
          const {},
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
    enabled,
    enabledBy,
    priorityId,
    createThreads,
    createThreadsByType,
    linkTypes,
    currentUserHasAccess,
    children,
  ];
}
