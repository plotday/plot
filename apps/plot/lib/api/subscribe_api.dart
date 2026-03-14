import 'package:equatable/equatable.dart';
import 'api.dart' as api;

/// Usage counts for a single resource type (e.g. connections or twists)
class ResourceUsage extends Equatable {
  final int count;

  /// Null means unlimited (pro/business plan)
  final int? limit;

  const ResourceUsage({required this.count, this.limit});

  factory ResourceUsage.fromJson(Map<String, dynamic> json) {
    return ResourceUsage(
      count: json['count'] as int,
      limit: json['limit'] as int?,
    );
  }

  /// Whether the resource is at or over the limit
  bool get isAtLimit => limit != null && count >= limit!;

  /// Whether the resource has an unlimited plan
  bool get isUnlimited => limit == null;

  @override
  List<Object?> get props => [count, limit];
}

/// Usage data for the current user's personal account
class PersonalUsage extends Equatable {
  final ResourceUsage connections;
  final ResourceUsage twists;

  const PersonalUsage({required this.connections, required this.twists});

  factory PersonalUsage.fromJson(Map<String, dynamic> json) {
    return PersonalUsage(
      connections: ResourceUsage.fromJson(
        json['connections'] as Map<String, dynamic>,
      ),
      twists: ResourceUsage.fromJson(json['twists'] as Map<String, dynamic>),
    );
  }

  @override
  List<Object?> get props => [connections, twists];
}

/// Usage data for an organization the current user belongs to
class OrganizationUsage extends Equatable {
  final String id;
  final String name;
  final ResourceUsage connections;
  final bool isAdmin;

  const OrganizationUsage({
    required this.id,
    required this.name,
    required this.connections,
    required this.isAdmin,
  });

  factory OrganizationUsage.fromJson(Map<String, dynamic> json) {
    return OrganizationUsage(
      id: json['id'] as String,
      name: json['name'] as String,
      connections: ResourceUsage.fromJson(
        json['connections'] as Map<String, dynamic>,
      ),
      isAdmin: json['is_admin'] as bool? ?? false,
    );
  }

  @override
  List<Object?> get props => [id, name, connections, isAdmin];
}

/// Combined usage data for the current user
class UsageData extends Equatable {
  final PersonalUsage personal;
  final List<OrganizationUsage> organizations;

  const UsageData({required this.personal, required this.organizations});

  factory UsageData.fromJson(Map<String, dynamic> json) {
    return UsageData(
      personal: PersonalUsage.fromJson(
        json['personal'] as Map<String, dynamic>,
      ),
      organizations:
          (json['organizations'] as List<dynamic>)
              .map(
                (org) =>
                    OrganizationUsage.fromJson(org as Map<String, dynamic>),
              )
              .toList(),
    );
  }

  @override
  List<Object?> get props => [personal, organizations];
}

/// Subscription info including the effective plan across personal + org
class SubscriptionInfo extends Equatable {
  final String plan;
  final String effectivePlan;
  final String effectiveSource;

  const SubscriptionInfo({
    required this.plan,
    required this.effectivePlan,
    required this.effectiveSource,
  });

  factory SubscriptionInfo.fromJson(Map<String, dynamic> json) {
    return SubscriptionInfo(
      plan: json['plan'] as String? ?? 'free',
      effectivePlan: json['effective_plan'] as String? ?? 'free',
      effectiveSource: json['effective_source'] as String? ?? 'personal',
    );
  }

  bool get isFree => effectivePlan == 'free';

  @override
  List<Object?> get props => [plan, effectivePlan, effectiveSource];
}

/// API methods for subscription and usage
class SubscribeApi {
  /// Fetch current usage counts and limits for the authenticated user
  static Future<UsageData> getUsage() async {
    final response = await api.get<Map<String, dynamic>>('/subscribe/usage');
    return UsageData.fromJson(response);
  }

  /// Fetch subscription status including effective plan
  static Future<SubscriptionInfo> getSubscription() async {
    final response = await api.get<Map<String, dynamic>>('/subscribe');
    return SubscriptionInfo.fromJson(response);
  }

  /// Fetch configured AI provider names (e.g. ['openai', 'anthropic'])
  static Future<List<String>> getAiKeys() async {
    final response = await api.get<List<dynamic>>('/ai-keys');
    return response
        .map((item) => (item as Map<String, dynamic>)['provider'] as String)
        .toList();
  }
}
