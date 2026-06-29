import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/iap_api.dart';
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/state/subscription_service.dart';
import 'package:plot/env.dart';
import 'package:plot/logging.dart';
import 'package:plot/state/user.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/confirm_modal.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/list_tile.dart';
import 'package:plot/widget/modal.dart';
import 'package:plot/widget/select_modal.dart';
import 'package:plot/widget/spinner.dart';
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
    : assert(plan != 'core', "Core is dropped — never offer it as a purchase"),
      super(
        title: title ?? _titleFor(plan),
        icon: PlotIcon.sparkles,
        eventObject: EventObject.settings,
        eventAction: EventAction.clicked,
      );

  /// 'pro' (or 'team'). 'core' is dropped — never offered as a new purchase.
  final String plan;

  static String _titleFor(String plan) {
    switch (plan) {
      case 'pro':
        return 'Subscribe to Pro';
      default:
        return 'Subscribe';
    }
  }

  /// StoreKit product for an IAP-buyable plan tier, or null when the plan isn't
  /// purchasable in-app. Only 'pro' has a StoreKit product — 'team' is
  /// Stripe/web-only and 'core' is dropped — so anything else returns null and
  /// the App Store path falls back to the web flow instead of mispurchasing Pro.
  static String? _productIdFor(String plan) =>
      plan == 'pro' ? kIapProductProMonthly : null;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (UpgradeUi.isAppStoreBuild) {
      return _runIap(context);
    }
    return _runWeb(context);
  }

  Future<CommandReturn> _runIap(BuildContext context) async {
    final productId = _productIdFor(plan);
    if (productId == null) {
      // Not an in-app-buyable tier (a stray 'core'/'team' reached the App Store
      // path) — never silently buy Pro; route to the web upgrade flow instead.
      return _runWeb(context);
    }
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

    if (!context.mounted) return const CommandSkipped();
    final result = await _withStoreKitLoading(
      context,
      () => IapService.instance.buy(productId),
    );
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

/// Captures consent for one more connection add-on credit ($5/month).
///
/// - Personal + App Store build: completes a StoreKit purchase up front
///   (Apple constraint — the charge happens at purchase, before auth).
///   Capped at [kIapMaxAddons]. Returns [CommandDone].
/// - Web / DMG / Android, and all team scopes (Stripe): shows the consent
///   disclosure but does NOT charge. Returns [CommandAddonConsented] so the
///   caller proceeds to enable the connection with `consentAddon: true`; the
///   server charges on enable (or returns needs_card to capture a card first).
///   The legacy upfront POST /upgrade/addons/purchase endpoint is no longer
///   used on this path.
class BuyAddonCommand extends Command {
  BuyAddonCommand({this.teamId, this.connectionName})
    : super(
        title: 'Add a connection add-on',
        icon: PlotIcon.connection,
        eventObject: EventObject.settings,
        eventAction: EventAction.clicked,
      );

  /// When set, the add-on is for this team (managed on the web by an admin).
  final String? teamId;

  /// Display name of the connector that needs the add-on (e.g. "LinkedIn"),
  /// when known. On the App Store purchase modal it's surfaced as
  /// "LinkedIn requires a connection add-on." so it's clear which connection the
  /// purchase unlocks. Null on the generic / proactive path.
  final String? connectionName;

  // Guards against starting two StoreKit purchases at once (a 2nd standalone
  // add-on subscription would orphan and bill forever — see Plan 2 review).
  // Only the App Store purchase path needs this; the web path captures consent
  // (no charge) so it doesn't.
  static bool _addonPurchaseInFlight = false;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // App Store personal: StoreKit purchase before auth (Apple constraint).
    if (teamId == null && UpgradeUi.isAppStoreBuild) {
      if (_addonPurchaseInFlight) return const CommandSkipped();
      _addonPurchaseInFlight = true;
      try {
        return await _runIap(context);
      } finally {
        _addonPurchaseInFlight = false;
      }
    }
    // Web / DMG / Android / team: consent only — charge on enable.
    return _consent(context);
  }

  /// Web/Stripe consent path: show the add-on disclosure and, on confirmation,
  /// signal the caller to enable with `consentAddon: true`. No upfront charge.
  Future<CommandReturn> _consent(BuildContext context) async {
    // Use the live price from /usage if available; fall back to $5.
    final price =
        SubscriptionService.instance.usage?.connectionAddonPrice ?? 5;

    final confirmed = await ConfirmModal(
      title: 'Add a connection add-on',
      messageWidget: SubscriptionDisclosure(
        priceLine: 'Connection add-on — \$$price/month',
        note:
            "You'll be billed when the connection is added. Billed separately "
            "from your plan; it does not count toward your plan's connection "
            'limit.',
      ),
      confirmLabel: 'Add for \$$price/month',
    ).run(context);
    if (!context.mounted || !confirmed) return const CommandSkipped();
    return const CommandAddonConsented();
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

    if (current >= kIapMaxAddons) {
      context.showToast(
        message:
            "You've reached the maximum connection add-ons on this device.",
      );
      return const CommandSkipped();
    }

    // Confirm before purchase. Every IAP-triggering screen must carry the
    // auto-renew + Terms/Privacy disclosure (Apple guideline 3.1.2).
    //
    // Show the live StoreKit price for the tier we're about to buy, not the
    // $5 web price: Apple's tiers ($5.99…) differ from the Stripe price, vary
    // by storefront, and would go silently stale if hardcoded. Falls back to a
    // price-less prompt when StoreKit hasn't loaded the product yet (the native
    // sheet still shows the exact amount).
    final productId = kIapAddonProductForCount[current + 1];
    final livePrice =
        productId == null ? null : IapService.instance.productFor(productId)?.price;
    final total = current + 1;
    final isUpgrade = current >= 1;
    const tail = "Billed separately from your plan; it does not count toward "
        "your plan's connection limit.";
    // When a premium connector (LinkedIn/Instagram/WhatsApp) triggered the
    // add-on, lead with "<name> requires a connection add-on." and keep the
    // "Purchase a connection add-on" button. On upgrades, state the increment
    // and the new total so the (live, total) price reads correctly.
    final String note;
    if (connectionName != null) {
      note = isUpgrade
          ? '$connectionName requires a connection add-on. '
                'Adds 1 more ($total total). $tail'
          : '$connectionName requires a connection add-on. $tail';
    } else {
      note = isUpgrade
          ? 'Adds 1 more connection ($total total). $tail'
          : 'Adds 1 connection. $tail';
    }
    final confirmLabel = connectionName != null
        ? 'Purchase a connection add-on'
        : (livePrice == null
              ? 'Add a connection add-on'
              : (isUpgrade
                    ? 'Upgrade to $livePrice/month'
                    : 'Add for $livePrice/month'));
    final confirmed = await ConfirmModal(
      title: 'Add a connection add-on',
      messageWidget: SubscriptionDisclosure(
        priceLine: livePrice == null ? null : 'Connection add-on — $livePrice/month',
        note: note,
      ),
      confirmLabel: confirmLabel,
      // The X / Esc / back already dismiss; drop the redundant Cancel row.
      showCancel: false,
    ).run(context);
    if (!context.mounted || !confirmed) return const CommandSkipped();

    final purchase = await _withStoreKitLoading(
      context,
      () => IapService.instance.buyAddon(current + 1),
    );
    if (!context.mounted) return const CommandSkipped();

    switch (purchase.status) {
      case IapPurchaseStatus.purchased:
        try {
          await SubscriptionService.instance.refresh();
        } catch (e, st) {
          log.warning('addon refresh after purchase failed', e, st);
        }
        if (context.mounted) {
          context.showToast(
            message: 'Connection add-on added — connect again to finish.',
          );
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

}

/// Purchases exactly one more personal twist add-on credit.
///
/// Team-scope twist capacity is managed on the web via the team billing page
/// (team_block_required reason) — this command is personal-only.
///
/// - Personal + App Store build: upgrades to the next StoreKit tier
///   (immediate, Apple prorates). Capped at [kIapMaxTwistAddons].
/// - Personal + non-App-Store (web, Android, DMG): calls
///   POST /upgrade/twist-addons/purchase; on a checkout-required response the
///   user is directed to their browser to complete payment.
class BuyTwistAddonCommand extends Command {
  BuyTwistAddonCommand({this.candidateWeight})
    : super(
        title: 'Add a twist add-on',
        icon: PlotIcon.sparkles,
        eventObject: EventObject.settings,
        eventAction: EventAction.clicked,
      );

  /// Twist-capacity weight of the candidate twist being installed.
  /// Forwarded to the server so it can select the right tier.
  final int? candidateWeight;

  // Guards against starting two twist add-on checkouts at once (a 2nd
  // standalone subscription would orphan and bill forever).
  // Static so the guard is shared across all instances.
  static bool _twistAddonPurchaseInFlight = false;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (_twistAddonPurchaseInFlight) return const CommandSkipped();
    _twistAddonPurchaseInFlight = true;
    try {
      if (UpgradeUi.isAppStoreBuild) {
        return await _runIap(context);
      }
      return await _purchaseViaEndpoint(context);
    } finally {
      _twistAddonPurchaseInFlight = false;
    }
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
        SubscriptionService.instance.usage?.personal.twistAddonCount ?? 0;

    if (current >= kIapMaxTwistAddons) {
      context.showToast(
        message:
            "You've reached the maximum twist add-ons. "
            'Manage your subscriptions in App Store settings.',
      );
      return const CommandSkipped();
    }

    // Show the live StoreKit price for the tier we're about to buy, not the $10
    // web price: Apple's tiers differ from Stripe, vary by storefront, and would
    // go silently stale if hardcoded. Falls back to a price-less prompt when
    // StoreKit hasn't loaded the product yet (the native sheet still shows it).
    final blockSize =
        SubscriptionService.instance.usage?.twistAddonBlockSize ?? 5;
    final blocks = current + 1;
    final total = blocks * blockSize;
    final productId = kIapTwistAddonProductForCount[blocks];
    final livePrice =
        productId == null ? null : IapService.instance.productFor(productId)?.price;
    final isUpgrade = current >= 1;
    final note = isUpgrade
        ? 'Adds $blockSize more twist automations ($total total). '
              'Billed separately from your plan.'
        : 'Adds $blockSize twist automations. Billed separately from your plan.';
    final confirmed = await ConfirmModal(
      title: 'Add a twist add-on',
      messageWidget: SubscriptionDisclosure(
        priceLine: livePrice == null ? null : 'Twist add-on — $livePrice/month',
        note: note,
      ),
      confirmLabel: livePrice == null
          ? 'Add a twist add-on'
          : (isUpgrade ? 'Upgrade to $livePrice/month' : 'Add for $livePrice/month'),
      // The X / Esc / back already dismiss; drop the redundant Cancel row.
      showCancel: false,
    ).run(context);
    if (!context.mounted || !confirmed) return const CommandSkipped();

    final purchase = await _withStoreKitLoading(
      context,
      () => IapService.instance.buyTwistAddon(current + 1),
    );
    if (!context.mounted) return const CommandSkipped();

    switch (purchase.status) {
      case IapPurchaseStatus.purchased:
        try {
          await SubscriptionService.instance.refresh();
        } catch (e, st) {
          log.warning('Twist add-on refresh after purchase failed', e, st);
        }
        if (context.mounted) {
          context.showToast(
            message:
                'Twist add-on added — install the twist again to finish.',
          );
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

  Future<CommandReturn> _purchaseViaEndpoint(BuildContext context) async {
    // Use the live price from /usage if available; fall back to $10.
    final price =
        SubscriptionService.instance.usage?.twistAddonPrice ?? 10;

    // Consent before any charge.
    final confirmed = await ConfirmModal(
      title: 'Add a twist add-on',
      messageWidget: SubscriptionDisclosure(
        priceLine: 'Twist add-on — \$$price/month',
        note: 'Adds +5 twist automations — billed to your card on file, prorated.',
      ),
      confirmLabel: 'Add for \$$price/month',
    ).run(context);
    if (!context.mounted || !confirmed) return const CommandSkipped();

    // Snapshot the prior count so we can tell a real purchase from a no-op.
    // A proactive at-capacity offer (no candidateWeight) can resolve to the
    // server's idempotent branch (target <= current), which returns ok:true
    // without charging or granting — claiming "added" there would mislead.
    final previousCount =
        SubscriptionService.instance.usage?.personal.twistAddonCount ?? 0;

    try {
      final result = await UpgradeApi.purchaseTwistAddon(
        candidateWeight: candidateWeight,
      );
      if (!context.mounted) return const CommandSkipped();
      if (result.ok) {
        try {
          await SubscriptionService.instance.refresh();
        } catch (e, st) {
          log.warning('Twist add-on refresh after purchase failed', e, st);
        }
        // `addons` is the resulting twist-add-on count. If it didn't increase,
        // nothing was charged/granted (the user is already at capacity and we
        // couldn't size the purchase without a specific twist) — guide them to
        // the install path, which carries the real weight and grants capacity.
        final granted = result.addons == null || result.addons! > previousCount;
        if (context.mounted) {
          context.showToast(
            message: granted
                ? 'Twist add-on added — install the twist again to finish.'
                : "You're at your twist capacity. Open the twist you want to "
                      'add and confirm there to buy more.',
          );
        }
        return granted ? const CommandDone() : const CommandSkipped();
      }
      final url = result.checkoutUrl;
      if (url != null) {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        if (context.mounted) {
          context.showToast(
            message:
                'Finish checkout in your browser, then install the twist.',
          );
        }
        return const CommandSkipped();
      }
      return const CommandSkipped();
    } catch (e, st) {
      log.warning('Twist add-on purchase failed', e, st);
      // 4xx responses are expected business rejections (e.g. non-admin team →
      // 403, card-less → 400) and should not be reported to error tracking.
      if (e is! ApiException || e.statusCode >= 500) {
        Tracker.captureException(e, st);
      }
      if (context.mounted) {
        context.showToast(
          message: 'Could not add a twist add-on.',
          isError: true,
        );
      }
      return const CommandSkipped();
    }
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

/// The Pro plan's marketing feature list, shown in the App Store upgrade
/// confirmation so it's clear what the subscription includes. Mirrors the Pro
/// plan on the marketing site (apps/site/app/lib/plans.ts) — keep the two in
/// sync. ("Everything in Free" is intentionally omitted: it only reads clearly
/// next to the Free card on the pricing page, not on its own in a modal.)
const List<String> _kProFeatures = [
  'Unlimited connections',
  'Built-in Plot assistant',
  '10 automations',
  'No-code automation builder',
  'Import 1 year of history from your connections',
];

/// What the user is buying, shown in the App Store "Upgrade your plan"
/// confirmation: the Pro price, a one-line summary, the feature list, and the
/// auto-renew + Terms/Privacy disclosure Apple requires (3.1.2). Replaces the
/// bare price line so the modal makes clear what Pro includes.
class ProUpgradeDetails extends StatelessWidget {
  const ProUpgradeDetails({this.price, super.key});

  /// Live StoreKit price (e.g. "$34.99"), or null when StoreKit hasn't loaded
  /// the product yet (the native sheet still shows the exact amount).
  final String? price;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final body = theme.typography.sm.copyWith(
      color: theme.colors.mutedForeground,
      height: 1.4,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          price == null ? 'Pro' : 'Pro — $price/month',
          style: theme.typography.sm.copyWith(fontWeight: FontWeight.w600),
        ),
        SizedBox(height: theme.spacing.xs),
        Text('Unlimited connections and more automation.', style: body),
        SizedBox(height: theme.spacing.sm),
        for (final feature in _kProFeatures)
          Padding(
            padding: EdgeInsets.only(bottom: theme.spacing.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(top: 3, right: theme.spacing.sm),
                  child: Icon(
                    PlotIcon.done,
                    size: theme.iconSizes.xs,
                    color: theme.colors.primary,
                  ),
                ),
                Expanded(child: Text(feature, style: body)),
              ],
            ),
          ),
        SizedBox(height: theme.spacing.sm),
        const SubscriptionDisclosure(),
      ],
    );
  }
}

/// Runs [buy] (a StoreKit purchase) while keeping a small "Contacting the App
/// Store…" modal on screen, so the modal beneath — e.g. the connections list or
/// the upgrade prompt — doesn't flash into view during the second or two before
/// StoreKit presents its native sheet.
///
/// The loader is pushed synchronously, before [buy]'s first await, so it swaps
/// in during the same frame the confirm modal pops — no flash. StoreKit's native
/// sheet then appears on top of it, and the loader pops itself once [buy]
/// settles (purchased / cancelled / error).
Future<T> _withStoreKitLoading<T>(
  BuildContext context,
  Future<T> Function() buy,
) async {
  final done = Completer<void>();
  void closeLoader() {
    if (!done.isCompleted) done.complete();
  }

  // Normally the loader retires when buy() returns. But on the Ask-to-Buy /
  // deferred path buy()'s future never resolves, so also close once StoreKit's
  // sheet has appeared and then been dismissed — IapService.nativeSheetActive
  // goes true when the sheet shows and false on the first transaction update.
  var sawSheet = false;
  void onSheet() {
    if (IapService.nativeSheetActive.value) {
      sawSheet = true;
    } else if (sawSheet) {
      closeLoader();
    }
  }

  IapService.nativeSheetActive.addListener(onSheet);
  unawaited(
    Modal(
      showCloseButton: false,
      builder: (_) => _StoreKitLoadingContent(done: done.future),
    ).show<void>(context),
  );
  try {
    return await buy();
  } finally {
    IapService.nativeSheetActive.removeListener(onSheet);
    closeLoader();
  }
}

/// Spinner body for the [_withStoreKitLoading] bridge modal. Pops itself when
/// [done] settles; if the user dismisses it first, the late pop is a no-op
/// (guarded by `mounted`).
class _StoreKitLoadingContent extends StatefulWidget {
  const _StoreKitLoadingContent({required this.done});

  final Future<void> done;

  @override
  State<_StoreKitLoadingContent> createState() => _StoreKitLoadingContentState();
}

class _StoreKitLoadingContentState extends State<_StoreKitLoadingContent> {
  @override
  void initState() {
    super.initState();
    widget.done.whenComplete(() {
      if (mounted) Modal.pop<dynamic>(context, Value<dynamic>.absent());
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: Center(child: Spinner.message('Contacting the App Store…')),
    );
  }
}

/// Live StoreKit price for a plan (currently only 'pro'), or null when StoreKit
/// hasn't loaded the product yet. Never hardcode the amount: it varies by
/// storefront, would silently go stale on any price change (no code rollout
/// updates it), and would never match what the native StoreKit sheet actually
/// charges.
String? _livePlanPrice(String plan) =>
    IapService.instance.productFor(kIapProductProMonthly)?.price;

/// Surfaces a plan picker (Pro) then routes to [BuyPlanCommand].
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
  /// Mirrors the gating matrix: free/trial → [pro]; paid/legacy-core → none.
  /// Core is dropped server-side; a user already on a legacy 'core' plan is
  /// treated as paid — no upgrade offered, same as pro/team.
  static List<String> plansFor(SubscriptionInfo sub) {
    if (sub.isPaidStripe || sub.canBuildTwists || sub.isCore) return const [];
    return const ['pro'];
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
            : const ['pro']);

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
      final planName = 'Pro';
      final price = _livePlanPrice(plan);
      final confirmed = await ConfirmModal(
        title: _title,
        // Show what Pro includes (price + feature list + disclosure) so it's
        // clear what the subscription buys, not just the price.
        messageWidget: ProUpgradeDetails(price: price),
        confirmLabel: 'Subscribe to $planName',
        // The X / Esc / back already dismiss; drop the redundant Cancel row.
        showCancel: false,
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
          final price = _livePlanPrice(plan);
          return ListTile(
            title: price == null ? 'Pro' : 'Pro — $price/month',
            icon: PlotIcon.sparkles,
            details: Text(
              'Unlimited connections',
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

/// Handles the "need more connection capacity" offer for a connector that is
/// beyond the plan pool. On the web/Stripe path this captures CONSENT only and
/// returns [CommandAddonConsented] — the caller then enables the connection
/// with `consentAddon: true` and the server charges on enable. On the App
/// Store path [BuyAddonCommand] completes a StoreKit purchase and returns
/// [CommandDone].
///
/// - [isPremium] == true (premium connector — LinkedIn, IG, WhatsApp):
///   Delegate directly to [BuyAddonCommand]. These connectors always require
///   an add-on credit, on both platforms (no "upgrade instead" alternative).
/// - [isPremium] == false + non-App-Store: present a choice — add a $5/month
///   connection add-on OR upgrade to Pro.
/// - [isPremium] == false + App Store: go straight to [ShowUpgradeOptions]
///   (Pro-only). Apple has no connection-capacity add-on tier; addon_1/2/3
///   are reserved for premium connectors.
class ConnectionCapacityOffer extends Command {
  ConnectionCapacityOffer({
    this.teamId,
    required this.isPremium,
    this.connectionName,
  }) : super(
         title: 'Add a connection',
         icon: PlotIcon.connection,
         eventObject: EventObject.settings,
         eventAction: EventAction.clicked,
       );

  final String? teamId;
  final bool isPremium;

  /// Display name of the connector being added (e.g. "LinkedIn"), forwarded to
  /// [BuyAddonCommand] so the App Store add-on modal can say which connection
  /// needs the add-on. Null when unknown.
  final String? connectionName;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Premium connectors always require the add-on on all platforms.
    if (isPremium) {
      return BuyAddonCommand(
        teamId: teamId,
        connectionName: connectionName,
      ).run(context);
    }

    // App Store: no connection-capacity add-on available — go straight to Pro.
    if (UpgradeUi.isAppStoreBuild) {
      return ShowUpgradeOptions(
        title: 'Upgrade to add more connections',
      ).run(context);
    }

    // Web / DMG / Android: offer a choice between the add-on and a plan upgrade.
    // Use the live price from /usage if available; fall back to $5.
    final connPrice =
        SubscriptionService.instance.usage?.connectionAddonPrice ?? 5;

    final result = await SelectModal.open<String>(
      context,
      showFilter: false,
      title: 'Add more connections',
      items: (_) async => [SelectGroup<String>(items: ['addon', 'upgrade'])],
      itemBuilder: (option, _) => Builder(
        builder: (context) {
          if (option == 'addon') {
            return ListTile(
              title: 'Add a connection — \$$connPrice/month',
              icon: PlotIcon.connection,
              details: Text(
                'Billed separately from your plan',
                style: context.theme.typography.sm.copyWith(
                  color: context.theme.plotColors.muted,
                ),
              ),
            );
          }
          return ListTile(
            title: 'Upgrade to Pro',
            icon: PlotIcon.sparkles,
            details: Text(
              'Unlimited connections',
              style: context.theme.typography.sm.copyWith(
                color: context.theme.plotColors.muted,
              ),
            ),
          );
        },
      ),
    );
    if (!context.mounted || !result.present) return const CommandSkipped();
    if (result.value == 'addon') {
      return BuyAddonCommand(
        teamId: teamId,
        connectionName: connectionName,
      ).run(context);
    }
    return ShowUpgradeOptions(
      title: 'Upgrade to add more connections',
    ).run(context);
  }
}

/// Handles the "need more twist capacity" offer when a personal user is at the
/// twist limit.
///
/// Team capacity is managed via the team billing page (team_block_required
/// reason) — this offer is personal-only.
///
/// Unlike [ConnectionCapacityOffer], Apple DOES have twist add-on tiers
/// (twist_addon_1/2/3), so on both platforms the user sees a choice between
/// buying more twist automations capacity and upgrading to Pro.
///
/// - non-App-Store: "Add 5 twist automations — $10/month"
///   (→ [BuyTwistAddonCommand]) OR "Upgrade to Pro" (→ [ShowUpgradeOptions]).
/// - App Store: same two options (Apple supports twist add-on tiers).
class TwistCapacityOffer extends Command {
  TwistCapacityOffer({this.candidateWeight})
    : super(
        title: 'Add more twist automations',
        icon: PlotIcon.sparkles,
        eventObject: EventObject.settings,
        eventAction: EventAction.clicked,
      );

  /// Twist-capacity weight of the candidate twist being installed.
  /// Forwarded to [BuyTwistAddonCommand] so the server can select the right
  /// tier.
  final int? candidateWeight;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final usage = SubscriptionService.instance.usage;
    final blockSize = usage?.twistAddonBlockSize ?? 5;

    // Add-on tile copy. On App Store the add-on is a tiered StoreKit product, so
    // show the live price for the *next* tier (not the $10 web price) and mirror
    // the confirm modal's increment+total framing. On web it's a flat
    // incremental $10/block.
    String addonTitle;
    String addonDetails = 'Billed separately from your plan';
    if (UpgradeUi.isAppStoreBuild) {
      if (!IapService.instance.isReady) {
        await IapService.instance.init();
      }
      if (!context.mounted) return const CommandSkipped();
      final current = usage?.personal.twistAddonCount ?? 0;
      final blocks = current + 1;
      final total = blocks * blockSize;
      final productId = kIapTwistAddonProductForCount[blocks];
      final livePrice = productId == null
          ? null
          : IapService.instance.productFor(productId)?.price;
      final isUpgrade = current >= 1;
      final priceSuffix = livePrice == null ? '' : ' — $livePrice/month';
      addonTitle = isUpgrade
          ? 'Add $blockSize more twist automations$priceSuffix'
          : 'Add $blockSize twist automations$priceSuffix';
      if (isUpgrade) {
        addonDetails = '$total total · billed separately from your plan';
      }
    } else {
      final price = usage?.twistAddonPrice ?? 10;
      addonTitle = 'Add $blockSize twist automations — \$$price/month';
    }

    final result = await SelectModal.open<String>(
      context,
      showFilter: false,
      title: 'Add more twist automations',
      items: (_) async => [SelectGroup<String>(items: ['addon', 'upgrade'])],
      itemBuilder: (option, _) => Builder(
        builder: (context) {
          if (option == 'addon') {
            return ListTile(
              title: addonTitle,
              icon: PlotIcon.twist,
              details: Text(
                addonDetails,
                style: context.theme.typography.sm.copyWith(
                  color: context.theme.plotColors.muted,
                ),
              ),
            );
          }
          return ListTile(
            title: 'Upgrade to Pro',
            icon: PlotIcon.sparkles,
            details: Text(
              // Pro's twist capacity is 3 (PLAN_LIMITS.pro.twistCapacity),
              // not unlimited — don't overpromise.
              '3 twist automations',
              style: context.theme.typography.sm.copyWith(
                color: context.theme.plotColors.muted,
              ),
            ),
          );
        },
      ),
    );
    if (!context.mounted || !result.present) return const CommandSkipped();
    if (result.value == 'addon') {
      return BuyTwistAddonCommand(candidateWeight: candidateWeight).run(context);
    }
    return ShowUpgradeOptions(title: 'Upgrade to add more twist automations').run(context);
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
      final status = await IapService.instance.restorePurchases();
      // A confirmed restore writes entitlement on the server; refresh so the
      // Settings UI reflects the recovered subscription immediately rather than
      // waiting for the next websocket broadcast.
      if (status == IapRestoreStatus.restored) {
        await SubscriptionService.instance.refresh();
      }
      if (!context.mounted) return const CommandDone();
      switch (status) {
        case IapRestoreStatus.restored:
          context.showToast(message: 'Your subscription has been restored.');
          return const CommandDone();
        case IapRestoreStatus.nothingToRestore:
          context.showToast(message: 'No purchases to restore.');
          return const CommandDone();
        case IapRestoreStatus.serverError:
          context.showToast(
            message: "We found a purchase but couldn't confirm it. "
                'Please try again.',
            isError: true,
          );
          return const CommandSkipped();
        case IapRestoreStatus.unavailable:
          context.showToast(
            message: 'In-app purchases are not available right now.',
            isError: true,
          );
          return const CommandSkipped();
      }
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
