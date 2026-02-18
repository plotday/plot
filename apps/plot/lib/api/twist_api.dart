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
  final TwistPermissions? permissions;
  final String? version;
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
    this.permissions,
    this.version,
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

    return Twist(
      id: id,
      name: json['name'] as String,
      description: json['description'] as String?,
      authorName: json['author_name'] as String?,
      authorEmail: json['author_email'] as String?,
      authorUrl: json['author_url'] as String?,
      tools: tools,
      environment: json['environment'] as String? ?? 'public',
      permissions: json['permissions'] != null
          ? TwistPermissions.fromJson(
              json['permissions'] as Map<String, dynamic>,
            )
          : null,
      version: json['version'] as String?,
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

  /// Assigns priority, activates the draft, and enables selected syncables.
  static Future<void> activateDraft({
    required String draftId,
    required String priorityId,
    required String name,
    List<Map<String, String>>? syncables,
  }) async {
    await api.post<Map<String, dynamic>>(
      '/twist/draft/$draftId/activate',
      body: {
        'priorityId': priorityId,
        'name': name,
        if (syncables != null) 'syncables': syncables,
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
  }) async {
    final response = await api.post<Map<String, dynamic>>(
      '/twist/$priorityTwistId/integrations/auth',
      body: {
        'provider': provider,
        'redirectUri': redirectUri,
        if (platform != null) 'platform': platform,
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

  /// Enable a syncable resource
  static Future<void> enableSyncable({
    required String priorityTwistId,
    required String provider,
    required String syncableId,
  }) async {
    await api.post<Map<String, dynamic>>(
      '/twist/$priorityTwistId/syncables/$provider/$syncableId/enable',
    );
  }

  /// Disable a syncable resource
  static Future<void> disableSyncable({
    required String priorityTwistId,
    required String provider,
    required String syncableId,
  }) async {
    await api.post<Map<String, dynamic>>(
      '/twist/$priorityTwistId/syncables/$provider/$syncableId/disable',
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

/// Integration data for a twist
class TwistIntegrations {
  final List<TwistProvider> providers;
  final List<TwistAccount> accounts;
  final List<TwistSyncable> syncables;

  const TwistIntegrations({
    required this.providers,
    required this.accounts,
    required this.syncables,
  });

  factory TwistIntegrations.fromJson(Map<String, dynamic> json) {
    return TwistIntegrations(
      providers: (json['providers'] as List<dynamic>)
          .map((p) => TwistProvider.fromJson(p as Map<String, dynamic>))
          .toList(),
      accounts: (json['accounts'] as List<dynamic>)
          .map((a) => TwistAccount.fromJson(a as Map<String, dynamic>))
          .toList(),
      syncables: (json['syncables'] as List<dynamic>)
          .map((s) => TwistSyncable.fromJson(s as Map<String, dynamic>))
          .toList(),
    );
  }

  bool get isEmpty => providers.isEmpty;
}

/// A provider configuration for a twist
class TwistProvider extends Equatable {
  final AuthProvider provider;
  final List<String> scopes;

  const TwistProvider({required this.provider, required this.scopes});

  factory TwistProvider.fromJson(Map<String, dynamic> json) {
    return TwistProvider(
      provider: AuthProvider.values.firstWhere(
        (v) => v.name == json['provider'],
        orElse: () => AuthProvider.other,
      ),
      scopes: (json['scopes'] as List<dynamic>).cast<String>(),
    );
  }

  @override
  List<Object?> get props => [provider, scopes];
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

/// A syncable resource for a twist integration
class TwistSyncable extends Equatable {
  final AuthProvider provider;
  final String id;
  final String title;
  final bool enabled;
  final String? enabledBy;
  final bool currentUserHasAccess;

  const TwistSyncable({
    required this.provider,
    required this.id,
    required this.title,
    required this.enabled,
    this.enabledBy,
    required this.currentUserHasAccess,
  });

  factory TwistSyncable.fromJson(Map<String, dynamic> json) {
    return TwistSyncable(
      provider: AuthProvider.values.firstWhere(
        (v) => v.name == json['provider'],
        orElse: () => AuthProvider.other,
      ),
      id: json['id'] as String,
      title: json['title'] as String,
      enabled: json['enabled'] as bool,
      enabledBy: json['enabledBy'] as String?,
      currentUserHasAccess: json['currentUserHasAccess'] as bool,
    );
  }

  @override
  List<Object?> get props => [
    provider,
    id,
    title,
    enabled,
    enabledBy,
    currentUserHasAccess,
  ];
}
