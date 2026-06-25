import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/iap_api.dart';
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/state/subscription_service.dart';
import 'package:plot/env.dart';
import 'package:plot/logging.dart';
import 'package:plot/state/user.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/confirm_modal.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/list_tile.dart';
import 'package:plot/widget/select_modal.dart';
import 'package:plot/widget/toast.dart';
import 'command.dart';

/// Apple's deep link to the user's auto-renewable subscription management
/// screen inside the iOS Settings / Mac App Store app. Required by Apple
/// in lieu of an in-app cancellation flow.
const String _appStoreManageSubscriptionsUrl =
    'https://apps.apple.com/account/subscriptions';

/// Triggers a StoreKit purchase for the given subscription tier on App
/// Store builds. On non-App-Store builds (DMG, web, Android), opens the
/// web upgrade flow.
class BuyPlanCommand extends Command {
  BuyPlanCommand({required this.plan, String? title})
    : super(
        title: title ?? _titleFor(plan),
        icon: PlotIcon.sparkles,
        eventObject: EventObject.settings,
        eventAction: EventAction.clicked,
      );

  /// 'core' or 'pro'.
  final String plan;

  static String _titleFor(String plan) {
    switch (plan) {
      case 'core':
        return 'Subscribe to Core';
      case 'pro':
        return 'Subscribe to Pro';
      default:
        return 'Subscribe';
    }
  }

  static String _productIdFor(String plan) {
    switch (plan) {
      case 'core':
        return kIapProductCoreMonthly;
      case 'pro':
      default:
        return kIapProductProMonthly;
    }
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (UpgradeUi.isAppStoreBuild) {
      return _runIap(context);
    }
    return _runWeb(context);
  }

  Future<CommandReturn> _runIap(BuildContext context) async {
    final productId = _productIdFor(plan);
    if (!IapService.instance.isReady) {
      // Lazy init in case the app hadn't reached the entitlement-aware
      // codepath yet (e.g. first-launch upgrade).
      await IapService.instance.init();
    }
    if (!IapService.instance.isReady) {
      if (context.mounted) {
        context.showToast(
          message: 'In-app purchases are not available right now.',
          isError: true,
        );
      }
      return const CommandSkipped();
    }

    final result = await IapService.instance.buy(productId);
    if (!context.mounted) return const CommandSkipped();

    switch (result.status) {
      case IapPurchaseStatus.purchased:
        // Pull the new entitlement and mark it acknowledged so the refocus
        // toast path does not double up on this inline confirmation.
        await SubscriptionService.instance.refresh();
        SubscriptionService.instance.acknowledgeBaseline();
        if (context.mounted) {
          context.showToast(message: 'Subscription active.');
        }
        return const CommandDone();
      case IapPurchaseStatus.canceled:
        return const CommandSkipped();
      case IapPurchaseStatus.pending:
        context.showToast(message: 'Purchase is pending approval.');
        return const CommandSkipped();
      case IapPurchaseStatus.serverError:
        context.showToast(
          message:
              'Purchase succeeded but we could not confirm it. '
              'Try Restore Purchases in Settings.',
          isError: true,
        );
        return const CommandSkipped();
      case IapPurchaseStatus.storeError:
        context.showToast(
          message: result.message ?? 'Purchase failed.',
          isError: true,
        );
        return const CommandSkipped();
    }
  }

  Future<CommandReturn> _runWeb(BuildContext context) async {
    await openWebUpgrade(context, plan: plan);
    return const CommandSkipped();
  }
}

/// Opens the web upgrade flow (`${Env.siteRoot}/upgrade`) in an external
/// browser, optionally preselecting a [plan]. Used on every non-App-Store
/// distribution channel, where the web page presents full plan details and
/// its own picker — so there's no need to make the user pick a plan in-app
/// first.
Future<void> openWebUpgrade(BuildContext context, {String? plan}) async {
  final userState = context.read<UserBloc>().state;
  final email = userState is UserReady ? userState.user.primaryEmail : null;
  final params = <String, String>{};
  if (plan != null) params['plan'] = plan;
  if (email != null) params['email'] = email;
  final uri = Uri.parse(
    '${Env.siteRoot}/upgrade',
  ).replace(queryParameters: params.isEmpty ? null : params);
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Manage $5/mo connection add-ons. On App Store builds this opens a quantity
/// picker (0–[kIapMaxAddons]): choosing more upgrades in-app (immediate,
/// prorated); choosing fewer or none routes to Apple's Manage Subscriptions
/// screen (apps can't downgrade/cancel an auto-renewable sub directly).
/// Elsewhere it opens web add-on management. Team add-ons ([teamId] set) are
/// managed by an admin on the web.
class BuyAddonCommand extends Command {
  BuyAddonCommand({this.teamId})
    : super(
        title: 'Add a connection add-on',
        icon: PlotIcon.connection,
        eventObject: EventObject.settings,
        eventAction: EventAction.clicked,
      );

  /// When set, the add-on is for this team (managed on the web by an admin).
  final String? teamId;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Team add-ons ride the team's Stripe subscription — admin-managed on the
    // web. Personal add-ons off the App Store are managed on the web too.
    if (teamId != null || !UpgradeUi.isAppStoreBuild) {
      await openWebUpgrade(context);
      return const CommandSkipped();
    }
    return _runIap(context);
  }

  Future<CommandReturn> _runIap(BuildContext context) async {
    if (!IapService.instance.isReady) {
      await IapService.instance.init();
    }
    if (!IapService.instance.isReady) {
      if (context.mounted) {
        context.showToast(
          message: 'In-app purchases are not available right now.',
          isError: true,
        );
      }
      return const CommandSkipped();
    }
    if (!context.mounted) return const CommandSkipped();

    final current =
        SubscriptionService.instance.usage?.personal.premium?.purchased ?? 0;

    // Picker of total add-on counts (0 = none). Selecting MORE upgrades in-app
    // (immediate, Apple prorates); selecting FEWER or none routes to Apple's
    // Manage Subscriptions screen — an app can't cancel or downgrade an
    // auto-renewable subscription directly, the system handles that.
    final result = await _pickAddonCount(context, current);
    if (result == null || !context.mounted || result == current) {
      return const CommandSkipped();
    }

    if (result < current) {
      try {
        await launchUrl(
          Uri.parse(_appStoreManageSubscriptionsUrl),
          mode: LaunchMode.externalApplication,
        );
      } catch (e, st) {
        log.warning('Failed to open App Store subscriptions URL', e, st);
      }
      if (context.mounted) {
        context.showToast(
          message: result == 0
              ? 'Cancel your connection add-ons in App Store settings.'
              : 'Reduce your connection add-ons in App Store settings.',
        );
      }
      return const CommandDone();
    }

    // Upgrade or first purchase — in-app.
    final purchase = await IapService.instance.buyAddon(result);
    if (!context.mounted) return const CommandSkipped();

    switch (purchase.status) {
      case IapPurchaseStatus.purchased:
        await SubscriptionService.instance.refresh();
        SubscriptionService.instance.acknowledgeBaseline();
        if (context.mounted) {
          context.showToast(message: 'Connection add-ons updated.');
        }
        return const CommandDone();
      case IapPurchaseStatus.canceled:
        return const CommandSkipped();
      case IapPurchaseStatus.pending:
        context.showToast(message: 'Purchase is pending approval.');
        return const CommandSkipped();
      case IapPurchaseStatus.serverError:
        context.showToast(
          message:
              'Purchase succeeded but we could not confirm it. '
              'Try Restore Purchases in Settings.',
          isError: true,
        );
        return const CommandSkipped();
      case IapPurchaseStatus.storeError:
        context.showToast(
          message: purchase.message ?? 'Purchase failed.',
          isError: true,
        );
        return const CommandSkipped();
    }
  }

  /// The total-quantity picker (0..[kIapMaxAddons]). Returns the chosen count,
  /// or null if dismissed. Prices come live from StoreKit so each storefront
  /// shows its own localized amount.
  Future<int?> _pickAddonCount(BuildContext context, int current) async {
    String? priceFor(int n) =>
        IapService.instance.productFor(kIapAddonProductForCount[n]!)?.price;

    final result = await SelectModal.open<int>(
      context,
      showFilter: false,
      title: 'Connection add-ons',
      // Carries the auto-renew + Terms/Privacy disclosure required on any
      // IAP-triggering screen (3.1.2). Per-tier prices are on the rows.
      subtitleWidget: const SubscriptionDisclosure(
        note:
            'Connection add-ons are provided by a third party and bill on top '
            'of your plan. Each also counts as one of your plan connections.',
      ),
      selectedValue: current,
      items: (_) async => [
        SelectGroup<int>(items: [for (var n = 0; n <= kIapMaxAddons; n++) n]),
      ],
      itemBuilder: (count, _) => Builder(
        builder: (context) {
          final muted = context.theme.typography.sm.copyWith(
            color: context.theme.plotColors.muted,
          );
          if (count == 0) {
            return ListTile(
              title: 'None',
              details: Text(
                count == current ? 'Current' : 'Cancel in App Store settings',
                style: muted,
              ),
            );
          }
          final price = priceFor(count);
          return ListTile(
            title:
                '$count connection add-on${count == 1 ? '' : 's'}'
                '${price == null ? '' : ' — $price/month'}',
            details: count == current ? Text('Current', style: muted) : null,
          );
        },
      ),
    );
    return result.present ? result.value : null;
  }
}

/// (Public for the App Store review-screenshot harness in
/// test/screenshot/addon_review_screenshot_test.dart.)
/// Subscription disclosure shown on every screen that can trigger a StoreKit
/// purchase. Apple's subscription guidelines (3.1.2) require the purchase
/// screen to disclose (a) the subscription length, (b) that it auto-renews,
/// and (c) functional links to the Terms of Service and Privacy Policy.
/// StoreKit's native sheet also surfaces price/duration, but carrying the
/// disclosure on our own screen avoids review pushback.
///
/// Rendered with the theme's body typography (not a raw [TextStyle]) so the
/// copy reads like body text elsewhere, with the Terms / Privacy links shown
/// as tappable accent-coloured links instead of inline raw URLs.
class SubscriptionDisclosure extends StatelessWidget {
  const SubscriptionDisclosure({this.priceLine, this.note, super.key});

  /// Optional bold price line shown above the disclosure. Used on the
  /// single-plan confirmation path, where there's no plan tile to carry the
  /// price.
  final String? priceLine;

  /// Optional lead-in line supplied by the caller (e.g. a custom upgrade
  /// prompt). No call site sets this today; it preserves the prior
  /// `subtitle`-prefix behaviour.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final body = context.theme.typography.sm.copyWith(
      color: context.theme.colors.mutedForeground,
      height: 1.4,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (priceLine != null) ...[
          Text(
            priceLine!,
            style: context.theme.typography.sm.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: context.theme.spacing.sm),
        ],
        if (note != null && note!.isNotEmpty) ...[
          Text(note!, style: body),
          SizedBox(height: context.theme.spacing.sm),
        ],
        DefaultTextStyle(
          style: body,
          child: Text.rich(
            TextSpan(
              children: [
                const TextSpan(
                  text:
                      'Subscriptions auto-renew monthly until canceled. '
                      'Manage or cancel anytime in your App Store account. ',
                ),
                _link(context, 'Terms of Service', 'https://plot.day/terms'),
                const TextSpan(text: ' · '),
                _link(context, 'Privacy Policy', 'https://plot.day/privacy'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// A tappable disclosure link in the accent [FColors.primary] colour, which
  /// signals it's clickable on touch where there's no hover to reveal it. The
  /// pointer cursor marks it as a true external link on desktop. The link text
  /// carries the same `height: 1.4` as the surrounding body so the line it sits
  /// on isn't taller than the others — keeping the paragraph's line spacing
  /// even (no vertical padding, which would inflate that line).
  WidgetSpan _link(BuildContext context, String label, String url) {
    return WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () =>
              launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
          child: Text(
            label,
            style: context.theme.typography.sm.copyWith(
              color: context.theme.colors.primary,
              height: 1.4,
            ),
          ),
        ),
      ),
    );
  }
}

/// Live StoreKit price for a plan ('core'/'pro'), or null when StoreKit hasn't
/// loaded the product yet. Never hardcode the amount: it varies by storefront,
/// would silently go stale on any price change (no code rollout updates it),
/// and would never match what the native StoreKit sheet actually charges.
String? _livePlanPrice(String plan) => IapService.instance
    .productFor(plan == 'pro' ? kIapProductProMonthly : kIapProductCoreMonthly)
    ?.price;

/// Surfaces a plan picker (Core vs Pro) then routes to [BuyPlanCommand].
/// Used as the entry point for "Upgrade your plan" and the at-limit toasts.
///
/// When [availablePlans] is omitted the plan list is resolved at [run] time
/// from [SubscriptionService.instance.subscription] so call sites that don't
/// have the subscription at construction time (e.g. twist.dart, onboarding)
/// are automatically gated correctly.
class ShowUpgradeOptions extends Command {
  ShowUpgradeOptions({
    String? title,
    String? subtitle,
    List<String>? availablePlans,
  }) : _title = title ?? 'Upgrade your plan',
       // ignore: prefer_initializing_formals
       _subtitle = subtitle,
       // ignore: prefer_initializing_formals
       _availablePlans = availablePlans,
       super(
         title: title ?? 'Upgrade your plan',
         icon: PlotIcon.sparkles,
         eventObject: EventObject.settings,
         eventAction: EventAction.opened,
       );

  final String _title;
  final String? _subtitle;
  // Nullable: when null, the plan list is resolved at run() time from the
  // live subscription so callers that don't pass an explicit list are still
  // gated correctly (e.g. they won't offer IAP to a paid-Stripe user).
  final List<String>? _availablePlans;

  /// Which tiers to offer for [sub]'s current state on App Store builds.
  /// Mirrors the gating matrix: free/trial → both; app_store-core → pro only;
  /// paid Stripe / pro / team → none.
  static List<String> plansFor(SubscriptionInfo sub) {
    if (sub.isPaidStripe || sub.canBuildTwists) return const [];
    if (sub.isAppStore && sub.isCore) return const ['pro'];
    return const ['core', 'pro'];
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Off the App Store, the upgrade flow lives on the web, which presents
    // full plan details and its own picker. Skip the in-app plan modal —
    // it only exists to choose a StoreKit product — and open the page
    // directly.
    if (!UpgradeUi.isAppStoreBuild) {
      // When the caller attached explanatory context (today only the
      // connection-add-on gate: "subscribe first, then add the add-on"),
      // surface it in-app before bouncing to the external upgrade page —
      // otherwise the browser opens cold with no hint of why the user is here
      // or what to do when they come back. On the App Store the plan picker
      // below shows the same note inline, so this keeps the two environments
      // at parity.
      final subtitle = _subtitle;
      if (subtitle != null) {
        final proceed = await ConfirmModal(
          title: _title,
          message: subtitle,
          confirmLabel: 'Continue',
        ).run(context);
        if (!context.mounted || !proceed) return const CommandSkipped();
      }
      await openWebUpgrade(context);
      return const CommandSkipped();
    }

    // Resolve the plan list. When the caller passed an explicit list (e.g.
    // from subscriptionCommandsFor via ShowUpgradeOptions.plansFor), use it
    // directly. When omitted, derive it from the live subscription so this
    // command self-gates correctly at any call site.
    final sub = SubscriptionService.instance.subscription;
    final plans =
        _availablePlans ??
        (sub != null
            ? ShowUpgradeOptions.plansFor(sub)
            : const ['core', 'pro']);

    if (plans.isEmpty) {
      // The user is already on a paid plan with no upgradeable tiers.
      // If they somehow reached this command (e.g. a paid Stripe user on
      // the App Store build hitting an old entry point), route them to web
      // subscription management instead of silently doing nothing.
      if (sub != null && sub.isPaidStripe) {
        return ManageSubscriptionCommand(appStoreOrigin: false).run(context);
      }
      return const CommandSkipped();
    }
    if (plans.length == 1) {
      final plan = plans.first;
      // On App Store builds the screen that triggers an IAP must carry the
      // auto-renew + Terms/Privacy disclosure. The multi-plan picker shows it
      // in its subtitle; the single-plan upgrade path would otherwise jump
      // straight to StoreKit, so surface the disclosure in a confirmation
      // first (keeps every IAP-triggering screen compliant with 3.1.2).
      final planName = plan == 'pro' ? 'Pro' : 'Core';
      final price = _livePlanPrice(plan);
      final confirmed = await ConfirmModal(
        title: _title,
        messageWidget: SubscriptionDisclosure(
          priceLine: price == null ? null : '$planName — $price/month',
        ),
        confirmLabel: 'Subscribe to $planName',
      ).run(context);
      if (!context.mounted || !confirmed) return const CommandSkipped();
      return BuyPlanCommand(plan: plan).run(context);
    }

    final result = await SelectModal.open<String>(
      context,
      showFilter: false,
      title: _title,
      // Reached only on App Store builds (the web flow returns early above),
      // so the IAP-triggering screen always carries the required disclosure.
      subtitleWidget: SubscriptionDisclosure(note: _subtitle),
      items: (_) async => [SelectGroup<String>(items: plans)],
      itemBuilder: (plan, _) => Builder(
        builder: (context) {
          final isCore = plan == 'core';
          final name = isCore ? 'Core' : 'Pro';
          final price = _livePlanPrice(plan);
          return ListTile(
            title: price == null ? name : '$name — $price/month',
            icon: isCore ? PlotIcon.connection : PlotIcon.sparkles,
            details: Text(
              isCore
                  ? 'Up to five connections'
                  : 'Unlimited connections',
              style: context.theme.typography.sm.copyWith(
                color: context.theme.plotColors.muted,
              ),
            ),
          );
        },
      ),
    );

    if (!context.mounted || !result.present) return const CommandSkipped();
    final plan = result.value;
    return BuyPlanCommand(plan: plan).run(context);
  }
}

/// "Manage subscription" entry. On App Store builds where the subscription
/// was purchased via StoreKit, opens Apple's account subscription management.
/// When the active subscription is Stripe-origin (even on App Store builds),
/// opens the Stripe Customer Portal — this is 3.1.1-safe because managing an
/// existing subscription is distinct from a new purchase.
class ManageSubscriptionCommand extends Command {
  ManageSubscriptionCommand({this.appStoreOrigin = false})
    : super(
        title: 'Manage your subscription',
        icon: PlotIcon.settings,
        eventObject: EventObject.settings,
        eventAction: EventAction.opened,
      );

  /// True when the active subscription was purchased via StoreKit IAP. When
  /// false on an App Store build, the active sub is Stripe-origin, so we route
  /// to web management (3.1.1-safe: managing an existing sub, not a new purchase).
  final bool appStoreOrigin;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (appStoreOrigin) {
      final uri = Uri.parse(_appStoreManageSubscriptionsUrl);
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (e, st) {
        log.warning('Failed to open App Store subscriptions URL', e, st);
      }
      return const CommandDone();
    }
    // Stripe-origin (incl. on App Store builds): manage on the web.
    try {
      final url = await UpgradeApi.getPortalUrl();
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      return const CommandDone();
    } catch (e, st) {
      log.warning('Failed to open billing management', e, st);
      if (context.mounted) {
        context.showToast(
          message: 'Could not open subscription management.',
          isError: true,
        );
      }
      return const CommandSkipped();
    }
  }
}

/// Calls StoreKit's restorePurchases. Apple requires every app with
/// auto-renewable subscriptions to surface a user-accessible "Restore
/// Purchases" entry.
class RestorePurchasesCommand extends Command {
  RestorePurchasesCommand()
    : super(
        title: 'Restore purchases',
        icon: PlotIcon.sync,
        eventObject: EventObject.settings,
        eventAction: EventAction.clicked,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (!UpgradeUi.isAppStoreBuild) {
      return const CommandSkipped();
    }
    try {
      await IapService.instance.restorePurchases();
      if (context.mounted) {
        context.showToast(message: 'Restored from App Store.');
      }
      return const CommandDone();
    } catch (e, st) {
      log.warning('IAP: restorePurchases failed', e, st);
      if (context.mounted) {
        context.showToast(
          message: 'Could not restore purchases.',
          isError: true,
        );
      }
      return const CommandSkipped();
    }
  }
}
