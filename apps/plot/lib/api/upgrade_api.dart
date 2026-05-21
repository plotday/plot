import 'dart:io' show Platform;

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'api.dart' as api;

/// Centralizes platform rules for exposing upgrade UI.
///
/// Apple's App Store guideline 3.1.1 forbids in-app calls-to-action that
/// direct users to an external purchase flow. Gate any "Upgrade", "Manage
/// subscription", or pricing CTA on this flag.
///
/// The rule applies to:
///   - iOS (always — there is no non-store iOS distribution).
///   - The Mac App Store build of the macOS app. The DMG / direct-
///     distribution build is unaffected, so we use a compile-time flag
///     (`--dart-define=APP_STORE_BUILD=true`, set in
///     `apps/plot/macos/fastlane/Fastfile` `build_mas`) to differentiate.
///
/// The web build — even when loaded in iOS Safari — is free to show
/// upgrade UI and must not touch `dart:io`'s `Platform` (which throws
/// on web).
class UpgradeUi {
  const UpgradeUi._();

  /// True only for the macOS Mac App Store build. The DMG / direct-
  /// distribution build leaves this false.
  static const _isMacAppStoreBuild = bool.fromEnvironment("APP_STORE_BUILD");

  static bool get canPromptUpgrade {
    if (kIsWeb) return true;
    if (Platform.isIOS) return false;
    if (Platform.isMacOS && _isMacAppStoreBuild) return false;
    return true;
  }
}

/// Usage counts for a single resource type (e.g. connections or twists)
class ResourceUsage extends Equatable {
  final int count;

  /// Null means unlimited (pro/team plan)
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

/// Usage data for a team the current user belongs to
class TeamUsage extends Equatable {
  final String id;
  final String name;
  final String plan; // 'free' | 'core' | 'pro' | 'team'
  final ResourceUsage connections;
  final bool isAdmin;

  const TeamUsage({
    required this.id,
    required this.name,
    this.plan = 'free',
    required this.connections,
    required this.isAdmin,
  });

  factory TeamUsage.fromJson(Map<String, dynamic> json) {
    return TeamUsage(
      id: json['id'] as String,
      name: json['name'] as String,
      plan: json['plan'] as String? ?? 'free',
      connections: ResourceUsage.fromJson(
        json['connections'] as Map<String, dynamic>,
      ),
      isAdmin: json['is_admin'] as bool? ?? false,
    );
  }

  @override
  List<Object?> get props => [id, name, plan, connections, isAdmin];
}

/// Combined usage data for the current user
class UsageData extends Equatable {
  final PersonalUsage personal;
  final List<TeamUsage> teams;

  const UsageData({required this.personal, required this.teams});

  factory UsageData.fromJson(Map<String, dynamic> json) {
    return UsageData(
      personal: PersonalUsage.fromJson(
        json['personal'] as Map<String, dynamic>,
      ),
      teams:
          (json['teams'] as List<dynamic>)
              .map(
                (org) =>
                    TeamUsage.fromJson(org as Map<String, dynamic>),
              )
              .toList(),
    );
  }

  @override
  List<Object?> get props => [personal, teams];
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
  bool get isCore => effectivePlan == 'core';
  bool get canBuildTwists => effectivePlan == 'pro' || effectivePlan == 'team';
  bool get hasPaidPlan => effectivePlan != 'free';

  @override
  List<Object?> get props => [plan, effectivePlan, effectiveSource];
}

/// API methods for subscription and usage
class UpgradeApi {
  /// Fetch current usage counts and limits for the authenticated user
  static Future<UsageData> getUsage() async {
    final response = await api.get<Map<String, dynamic>>('/upgrade/usage');
    return UsageData.fromJson(response);
  }

  /// Fetch subscription status including effective plan
  static Future<SubscriptionInfo> getSubscription() async {
    final response = await api.get<Map<String, dynamic>>('/upgrade');
    return SubscriptionInfo.fromJson(response);
  }

  /// Create a Stripe Customer Portal session and return its URL
  static Future<String> getPortalUrl() async {
    final response = await api.post<Map<String, dynamic>>('/upgrade/portal');
    return response['url'] as String;
  }

  /// Fetch configured AI provider names (e.g. ['openai', 'anthropic'])
  static Future<List<String>> getAiKeys() async {
    final response = await api.get<List<dynamic>>('/ai-keys');
    return response
        .map((item) => (item as Map<String, dynamic>)['provider'] as String)
        .toList();
  }
}
