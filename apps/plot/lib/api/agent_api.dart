import 'dart:convert';
import 'package:equatable/equatable.dart';
import 'package:http/http.dart' as http;
import 'package:plot/env.dart';
import 'package:plot/store/store.dart';
import 'api.dart' as api;
import 'logging.dart';
import 'agent_permission.dart';

/// Represents an agent tool with its identifier
class AgentTool extends Equatable {
  final String id;

  const AgentTool({required this.id});

  factory AgentTool.fromJson(Map<String, dynamic> json) {
    return AgentTool(id: json['id'] as String);
  }

  Map<String, dynamic> toJson() {
    return {'id': id};
  }

  @override
  List<Object> get props => [id];
}

class Agent {
  final String id;
  final String name;
  final String? description;
  final String? authorName;
  final String? authorEmail;
  final String? authorUrl;
  final List<AgentTool> tools;
  final String environment;
  final AgentPermissions? permissions;
  final String? version;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const Agent({
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

  factory Agent.fromJson(Map<String, dynamic> json) {
    List<AgentTool> tools = [];
    final toolsRaw = json['tools'];

    if (toolsRaw != null) {
      if (toolsRaw is Map<String, dynamic>) {
        // Handle tools as map format: {"tool-id": {}}
        tools = toolsRaw.entries
            .map((entry) => AgentTool(id: entry.key))
            .toList();
      } else if (toolsRaw is List<dynamic>) {
        // Handle tools as list format: [{"id": "tool-id"}]
        tools = toolsRaw
            .map((tool) => AgentTool.fromJson(tool as Map<String, dynamic>))
            .toList();
      }
    }

    return Agent(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      authorName: json['author_name'] as String?,
      authorEmail: json['author_email'] as String?,
      authorUrl: json['author_url'] as String?,
      tools: tools,
      environment: json['environment'] as String? ?? 'public',
      permissions: json['permissions'] != null
          ? AgentPermissions.fromJson(json['permissions'] as Map<String, dynamic>)
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

class PriorityAgent {
  final String id;
  final String priorityId;
  final String agentId;
  final String agentEnvironment;
  final String name;
  final Map<String, dynamic> config;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? archivedAt;
  final List<AgentTool>? tools;
  final AgentPermissions? permissions;

  const PriorityAgent({
    required this.id,
    required this.priorityId,
    required this.agentId,
    required this.agentEnvironment,
    required this.name,
    required this.config,
    this.createdAt,
    this.updatedAt,
    this.archivedAt,
    this.tools,
    this.permissions,
  });

  factory PriorityAgent.fromJson(Map<String, dynamic> json) {
    List<AgentTool>? tools;
    if (json['tools'] != null) {
      final toolsRaw = json['tools'];
      if (toolsRaw is Map<String, dynamic>) {
        // Handle tools as map format: {"tool-id": {}}
        tools = toolsRaw.entries
            .map((entry) => AgentTool(id: entry.key))
            .toList();
      } else if (toolsRaw is List<dynamic>) {
        // Handle tools as list format: [{"id": "tool-id"}]
        tools = toolsRaw
            .map((tool) => AgentTool.fromJson(tool as Map<String, dynamic>))
            .toList();
      }
    }

    // Extract permissions from nested agent data if available
    AgentPermissions? permissions;
    if (json['agent'] != null) {
      final agentData = json['agent'] as Map<String, dynamic>;
      if (agentData['permissions'] != null) {
        permissions = AgentPermissions.fromJson(
            agentData['permissions'] as Map<String, dynamic>);
      }
    }

    return PriorityAgent(
      id: json['id'] as String,
      priorityId: json['priority_id'] as String,
      agentId: json['agent_id'] as String,
      agentEnvironment: json['agent_environment'] as String? ?? 'public',
      name: json['name'] as String,
      config: json['config'] as Map<String, dynamic>? ?? {},
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : null,
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
          : null,
      archivedAt: json['archived_at'] != null
          ? DateTime.parse(json['archived_at'] as String)
          : null,
      tools: tools,
      permissions: permissions,
    );
  }
}

class AgentApi {
  /// Get all available agents for a priority
  static Future<List<Agent>> getAllAgents(Priority priority) async {
    final agentsData = await api.get<List<dynamic>>(
      '/agents?priorityId=${priority.id.toString()}',
    );
    return agentsData
        .map((json) => Agent.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Get agents active for a priority (including ancestors)
  static Future<List<PriorityAgent>> getAgentsForPriority(
    Priority priority,
  ) async {
    final agentsData = await api.get<List<dynamic>>(
      '/agent?priorityId=${priority.id.toString()}',
    );
    log.info('Agents for priority: $agentsData ');
    final ret = agentsData
        .map((json) => PriorityAgent.fromJson(json as Map<String, dynamic>))
        .toList();
    return ret;
  }

  /// Remove an agent from a priority
  static Future<void> removeAgent(String priorityAgentId) async {
    await api.delete<Map<String, dynamic>>('/agent/$priorityAgentId');
  }

  /// Add an agent to a priority
  static Future<String> addAgent({
    required String priorityId,
    required String agentId,
    required String agentEnvironment,
    String? name,
    Map<String, dynamic>? config,
  }) async {
    // Use custom HTTP call since server returns a string, not an object
    final response = await http.post(
      Uri.parse('${Env.apiRoot}/agent'),
      headers: api.getHeaders(),
      body: jsonEncode({
        'priorityId': priorityId,
        'agentId': agentId,
        'agentEnvironment': agentEnvironment,
        if (name != null) 'name': name,
        if (config != null) 'config': config,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('${response.statusCode} /agent ${response.body}');
    }

    // Server returns the priority agent ID as a JSON-encoded string
    final decodedResponse = jsonDecode(response.body);
    return decodedResponse.toString();
  }

  /// Update an agent
  static Future<PriorityAgent> updateAgent(
    String priorityAgentId,
    Map<String, dynamic> updates,
  ) async {
    final response = await api.patch<Map<String, dynamic>>(
      '/agent/$priorityAgentId',
      body: {'agent': updates},
    );
    return PriorityAgent.fromJson(response);
  }

  /// Get agent by priority agent ID
  static Future<PriorityAgent> getAgentById(String priorityAgentId) async {
    final response = await api.get<Map<String, dynamic>>(
      '/agent/$priorityAgentId',
    );
    return PriorityAgent.fromJson(response);
  }
}
