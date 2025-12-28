import 'package:equatable/equatable.dart';
import 'package:plot/store/store.dart';
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
          ? TwistPermissions.fromJson(json['permissions'] as Map<String, dynamic>)
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
    print('DEBUG: Fetching twists for priority ${priority.id}');
    final twistsData = await api.get<List<dynamic>>(
      '/twists?priorityId=${priority.id.toString()}',
    );
    print('DEBUG: Received ${twistsData.length} twists from API');
    print('DEBUG: Twists data: $twistsData');
    final twists = twistsData
        .map((json) => Twist.fromJson(json as Map<String, dynamic>))
        .toList();
    print('DEBUG: Parsed ${twists.length} twist objects');
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
}
