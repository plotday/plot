import 'dart:io' show Platform;

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'api.dart' as api;

/// Centralizes platform rules for the App Store distribution channels.
///
/// `isAppStoreBuild` is true when the binary is built for Apple's App
/// Store (iOS App Store or Mac App Store) and subject to guideline 3.1.1.
/// In those builds:
///   - The web upgrade flow (`launchUrl(plot.day/upgrade)`,
///     `/upgrade/checkout`, `/upgrade/portal`) MUST NOT be reachable.
///   - Subscription purchase happens via StoreKit IAP.
///   - The Premium AI add-on and Team plan must not be referenced.
///
/// The flag is driven by:
///   - `Platform.isIOS` at runtime (the Flutter iOS target is App-Store-
///     only — there's no non-store iOS distribution channel).
///   - `--dart-define=APP_STORE_BUILD=true` for macOS, set by Fastlane's
///     `:build_mas` lane. The DMG / direct distribution build omits the
///     flag so direct-distribution users keep the web purchase flow.
///
/// Web is never an App Store build, and must not touch `dart:io`'s
/// `Platform` (which throws on web).
class UpgradeUi {
  const UpgradeUi._();

  static const _appStoreDefine = bool.fromEnvironment("APP_STORE_BUILD");

  /// True when running on an Apple App Store-distributed binary.
  static bool get isAppStoreBuild {
    if (kIsWeb) return false;
    if (Platform.isIOS) return true;
    if (Platform.isMacOS && _appStoreDefine) return true;
    return false;
  }

  /// Whether the app may open external upgrade flows or surface CTAs that
  /// reference subscription purchases purchased elsewhere. False on App
  /// Store builds — those use StoreKit IAP instead.
  static bool get canPromptUpgrade => !isAppStoreBuild;
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

/// Premium-connection policy for a scope, mirroring the backend's
/// `PremiumPolicy` discriminated union.
///
/// - `blocked`: plan does not allow premium connections (Free / Core).
/// - `credits`: plan includes a fixed number of premium slots (+ add-ons).
///   Premium connections do not count against the regular pool.
/// - `weighted`: premium connections share the regular pool but each one
///   consumes `weight` slots from it.
enum PremiumPolicy {
  blocked,
  credits,
  weighted;

  static PremiumPolicy fromJson(String? value) {
    switch (value) {
      case 'credits':
        return PremiumPolicy.credits;
      case 'weighted':
        return PremiumPolicy.weighted;
      case 'blocked':
      default:
        return PremiumPolicy.blocked;
    }
  }
}

class PremiumUsage extends Equatable {
  final PremiumPolicy policy;

  /// Number of premium connections currently in this scope.
  final int count;

  /// Allowed premium count when [policy] is [PremiumPolicy.credits]
  /// (= `included + addons`). Null for `weighted` (no separate limit;
  /// premium shares the regular pool) and `blocked` (none allowed).
  final int? limit;

  /// Plan-default premium slots. Only meaningful when [policy] is
  /// [PremiumPolicy.credits]. Null otherwise.
  final int? included;

  /// Add-on premium slots beyond the plan default. Only meaningful when
  /// [policy] is [PremiumPolicy.credits]. Null otherwise.
  final int? addons;

  /// Per-premium-connection cost in regular pool slots when [policy] is
  /// [PremiumPolicy.weighted]. Null otherwise.
  final int? weight;

  const PremiumUsage({
    required this.policy,
    this.count = 0,
    this.limit,
    this.included,
    this.addons,
    this.weight,
  });

  factory PremiumUsage.fromJson(Map<String, dynamic> json) {
    final policy = PremiumPolicy.fromJson(json['policy'] as String?);
    return PremiumUsage(
      policy: policy,
      count: json['count'] as int? ?? 0,
      limit: json['limit'] as int?,
      included: json['included'] as int?,
      addons: json['addons'] as int?,
      weight: json['weight'] as int?,
    );
  }

  bool get isBlocked => policy == PremiumPolicy.blocked;

  /// True for `credits` plans whose limit is reached. Always false for
  /// `weighted` (the regular pool limit governs) and `blocked` (handled
  /// by [isBlocked] separately).
  bool get isAtLimit =>
      policy == PremiumPolicy.credits && limit != null && count >= limit!;

  @override
  List<Object?> get props => [policy, count, limit, included, addons, weight];
}

/// Usage data for the current user's personal account
class PersonalUsage extends Equatable {
  final ResourceUsage connections;
  final ResourceUsage twists;

  /// Premium-connection policy + usage. Null when the server predates the
  /// premium-connections rollout — treat as blocked for safety.
  final PremiumUsage? premium;

  const PersonalUsage({
    required this.connections,
    required this.twists,
    this.premium,
  });

  factory PersonalUsage.fromJson(Map<String, dynamic> json) {
    return PersonalUsage(
      connections: ResourceUsage.fromJson(
        json['connections'] as Map<String, dynamic>,
      ),
      twists: ResourceUsage.fromJson(json['twists'] as Map<String, dynamic>),
      premium: json['premium'] != null
          ? PremiumUsage.fromJson(json['premium'] as Map<String, dynamic>)
          : null,
    );
  }

  @override
  List<Object?> get props => [connections, twists, premium];
}

/// Usage data for a team the current user belongs to
class TeamUsage extends Equatable {
  final String id;
  final String name;
  final String plan; // 'free' | 'core' | 'pro' | 'team'
  final ResourceUsage connections;

  /// Premium-connection policy + usage for the team scope.
  final PremiumUsage? premium;
  final bool isAdmin;

  const TeamUsage({
    required this.id,
    required this.name,
    this.plan = 'free',
    required this.connections,
    this.premium,
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
      premium: json['premium'] != null
          ? PremiumUsage.fromJson(json['premium'] as Map<String, dynamic>)
          : null,
      isAdmin: json['is_admin'] as bool? ?? false,
    );
  }

  @override
  List<Object?> get props => [id, name, plan, connections, premium, isAdmin];
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

  /// 'stripe' or 'app_store' — where the active personal subscription
  /// was purchased. Null when the user has no paid personal plan.
  /// Used to route "Manage subscription" to the right destination.
  final String? origin;

  /// Personal subscription status: 'active' | 'trialing' | 'canceled' | …
  /// Distinguishes a Stripe free trial (convertible to IAP) from an actively
  /// paid Stripe plan (web-managed).
  final String status;

  const SubscriptionInfo({
    required this.plan,
    required this.effectivePlan,
    required this.effectiveSource,
    this.origin,
    this.status = 'active',
  });

  factory SubscriptionInfo.fromJson(Map<String, dynamic> json) {
    return SubscriptionInfo(
      plan: json['plan'] as String? ?? 'free',
      effectivePlan: json['effective_plan'] as String? ?? 'free',
      effectiveSource: json['effective_source'] as String? ?? 'personal',
      origin: json['origin'] as String?,
      status: json['status'] as String? ?? 'active',
    );
  }

  bool get isFree => effectivePlan == 'free';
  bool get isCore => effectivePlan == 'core';
  bool get canBuildTwists => effectivePlan == 'pro' || effectivePlan == 'team';
  bool get hasPaidPlan => effectivePlan != 'free';

  /// True when the active personal subscription was purchased via App
  /// Store IAP (so management goes through StoreKit, not Stripe portal).
  bool get isAppStoreOrigin => origin == 'app_store';

  /// On the 30-day Stripe Core trial — convertible to IAP on App Store builds.
  bool get isStripeTrial => origin == 'stripe' && status == 'trialing';

  /// Actively paying via Stripe (web) — managed on the web, never offered IAP.
  bool get isPaidStripe =>
      origin == 'stripe' && status == 'active' && effectivePlan != 'free';

  /// Active subscription purchased via App Store IAP.
  bool get isAppStore => origin == 'app_store';

  @override
  List<Object?> get props => [plan, effectivePlan, effectiveSource, origin, status];
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
