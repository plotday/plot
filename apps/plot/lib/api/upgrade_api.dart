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
///   - `--dart-define=APP_STORE_BUILD=true` for macOS, passed to the
///     `shorebird release macos` / `shorebird patch macos` builds in
///     `release.yml` / `patch.yml` (the Mac App Store binary). The DMG /
///     direct distribution build omits the flag so direct-distribution
///     users keep the web purchase flow.
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

/// Connection add-on usage for a scope, mirroring the backend's add-on model.
///
/// An "connection add-on" (LinkedIn / Instagram / WhatsApp) costs $5/mo and is
/// available on every plan. It requires a purchased add-on credit and does NOT
/// consume a regular connection slot — it is billed and counted separately.
///
/// - [allowed]: whether add-ons are available on this scope's plan. Kept for
///   back-compat; always true on current server responses.
/// - [count]: connection add-ons currently enabled in this scope.
/// - [purchased]: add-on credits purchased ($5/mo each).
class PremiumUsage extends Equatable {
  final bool allowed;
  final int count;
  final int purchased;

  const PremiumUsage({
    this.allowed = false,
    this.count = 0,
    this.purchased = 0,
  });

  factory PremiumUsage.fromJson(Map<String, dynamic> json) {
    return PremiumUsage(
      // Defensive: an older server returning the legacy union shape has no
      // `allowed`, so this reads false — treated as "no add-ons" (safe).
      allowed: json['allowed'] as bool? ?? false,
      count: json['count'] as int? ?? 0,
      purchased: json['purchased'] as int? ?? 0,
    );
  }

  /// Vestigial — [allowed] is always true on current server responses
  /// (add-ons are available on every plan). Kept for back-compat with callers
  /// that check [isBlocked] before offering the add-on purchase flow.
  bool get isBlocked => !allowed;

  /// On a paid plan, but every purchased add-on credit is already in use — the
  /// user must buy another add-on to enable one more.
  bool get needsAddon => allowed && count >= purchased;

  @override
  List<Object?> get props => [allowed, count, purchased];
}

/// Usage data for the current user's personal account
class PersonalUsage extends Equatable {
  final ResourceUsage connections;
  final ResourceUsage twists;

  /// Premium-connection policy + usage. Null when the server predates the
  /// premium-connections rollout — treat as needing a purchase for safety.
  final PremiumUsage? premium;

  /// Number of purchased twist add-on blocks (each adds +20 twist capacity).
  /// Defaults to 0 when the server predates the twist add-on rollout.
  final int twistAddonCount;

  const PersonalUsage({
    required this.connections,
    required this.twists,
    this.premium,
    this.twistAddonCount = 0,
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
      twistAddonCount: json['twistAddonCount'] as int? ?? 0,
    );
  }

  @override
  List<Object?> get props => [connections, twists, premium, twistAddonCount];
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

/// Result of provisioning one more connection add-on credit.
class AddonPurchase {
  const AddonPurchase({required this.ok, this.addons, this.checkoutUrl});
  final bool ok;
  final int? addons;
  final String? checkoutUrl;
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

  /// Purchase one more connection add-on credit.
  ///
  /// Personal (non-App-Store) and team purchases go through this endpoint.
  /// Returns [AddonPurchase.ok] true when the add-on was provisioned
  /// immediately (Stripe customer with a payment method on file), or
  /// [AddonPurchase.checkoutUrl] when the server needs a new Stripe Checkout
  /// session to collect payment.
  static Future<AddonPurchase> purchaseAddon({String? teamId}) async {
    final response = await api.post<Map<String, dynamic>>(
      '/upgrade/addons/purchase',
      body: {'teamId': ?teamId},
    );
    return AddonPurchase(
      ok: response['ok'] == true,
      addons: response['addons'] as int?,
      checkoutUrl: response['checkout_url'] as String?,
    );
  }

  /// Purchase one more twist add-on credit.
  ///
  /// Personal (non-App-Store) and team purchases go through this endpoint.
  /// Returns [AddonPurchase.ok] true when the add-on was provisioned
  /// immediately (Stripe customer with a payment method on file), or
  /// [AddonPurchase.checkoutUrl] when the server needs a new Stripe Checkout
  /// session to collect payment.
  ///
  /// [candidateWeight] is the automation-capacity weight of the twist being
  /// installed, forwarded to the server so it can select the right tier.
  static Future<AddonPurchase> purchaseTwistAddon({
    String? teamId,
    int? candidateWeight,
  }) async {
    final response = await api.post<Map<String, dynamic>>(
      '/upgrade/twist-addons/purchase',
      body: {'teamId': ?teamId, 'candidateWeight': ?candidateWeight},
    );
    return AddonPurchase(
      ok: response['ok'] == true,
      addons: response['twist_addons'] as int?,
      checkoutUrl: response['checkout_url'] as String?,
    );
  }

}
