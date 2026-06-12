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

/// Subscription disclosure text shown in the upgrade picker. Apple's
/// subscription guidelines require the screen that triggers an IAP to
/// disclose (a) the subscription length, (b) what auto-renew means, and
/// (c) links to Terms of Service and Privacy Policy. StoreKit's native
/// sheet also surfaces price/duration, but having the disclosure in our
/// own screen avoids review pushback.
const String _kSubscriptionDisclosure =
    'Subscriptions auto-renew monthly until canceled. Manage or cancel '
    'anytime in your App Store account.\n'
    'Terms: https://plot.day/terms · '
    'Privacy: https://plot.day/privacy';

/// Surfaces a plan picker (Core vs Pro) then routes to [BuyPlanCommand].
/// Used as the entry point for "Upgrade your plan" and the at-limit toasts.
class ShowUpgradeOptions extends Command {
  ShowUpgradeOptions({String? title, String? subtitle})
    : _title = title ?? 'Upgrade your plan',
      // ignore: prefer_initializing_formals
      _subtitle = subtitle,
      super(
        title: title ?? 'Upgrade your plan',
        icon: PlotIcon.sparkles,
        eventObject: EventObject.settings,
        eventAction: EventAction.opened,
      );

  final String _title;
  final String? _subtitle;

  /// Compose the picker's subtitle. On App Store builds we always append
  /// the subscription disclosure so the screen that triggers IAP carries
  /// the required ToS / Privacy / auto-renew language.
  String? _modalSubtitle() {
    if (!UpgradeUi.isAppStoreBuild) return _subtitle;
    if (_subtitle == null || _subtitle.isEmpty) {
      return _kSubscriptionDisclosure;
    }
    return '$_subtitle\n\n$_kSubscriptionDisclosure';
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Off the App Store, the upgrade flow lives on the web, which presents
    // full plan details and its own picker. Skip the in-app plan modal —
    // it only exists to choose a StoreKit product — and open the page
    // directly. The modal's title/subtitle are App-Store-only from here.
    if (!UpgradeUi.isAppStoreBuild) {
      await openWebUpgrade(context);
      return const CommandSkipped();
    }

    final result = await SelectModal.open<String>(
      context,
      showFilter: false,
      title: _title,
      subtitle: _modalSubtitle(),
      items: (_) async => [
        SelectGroup<String>(items: const ['core', 'pro']),
      ],
      itemBuilder: (plan, _) => Builder(
        builder: (context) {
          final isCore = plan == 'core';
          return ListTile(
            title: isCore ? 'Core — \$14.99/month' : 'Pro — \$24.99/month',
            icon: isCore ? PlotIcon.connection : PlotIcon.sparkles,
            details: Text(
              isCore
                  ? 'Up to five connections'
                  : 'Unlimited connections (including 1 Pro connection)',
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

/// "Manage subscription" entry. On App Store builds, opens Apple's
/// account subscription management. On the web/DMG path, opens the
/// Stripe Customer Portal (existing behavior).
class ManageSubscriptionCommand extends Command {
  ManageSubscriptionCommand({this.appStoreOrigin = false})
    : super(
        title: 'Manage subscription',
        icon: PlotIcon.settings,
        eventObject: EventObject.settings,
        eventAction: EventAction.opened,
      );

  /// True when the active subscription was purchased via StoreKit IAP.
  /// Used by callers that already know the subscription origin so we
  /// route to Apple even from the web build.
  final bool appStoreOrigin;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (UpgradeUi.isAppStoreBuild || appStoreOrigin) {
      final uri = Uri.parse(_appStoreManageSubscriptionsUrl);
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (e, st) {
        log.warning('Failed to open App Store subscriptions URL', e, st);
      }
      return const CommandDone();
    }

    try {
      final url = await UpgradeApi.getPortalUrl();
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      return const CommandDone();
    } catch (e, st) {
      log.warning('Failed to open Stripe portal', e, st);
      if (context.mounted) {
        context.showToast(
          message: 'Could not open billing portal.',
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
