import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:plot/api/upgrade_api.dart';
import 'package:plot/command/base.dart';
import 'package:plot/logging.dart';
import 'package:plot/state/subscription_service.dart';
import 'package:plot/widget/checkout_waiting_modal.dart';

/// Total connection add-on credits across personal + every team. A completed
/// connection add-on checkout increments exactly one scope's
/// [PremiumUsage.purchased], so a rise in this total means the purchase
/// provisioned — without needing to know which scope it was for.
int connectionAddonCreditTotal(UsageData usage) {
  var total = usage.personal.premium?.purchased ?? 0;
  for (final team in usage.teams) {
    total += team.premium?.purchased ?? 0;
  }
  return total;
}

/// Personal twist add-on credit count (twist add-ons are personal-only).
int twistAddonCreditTotal(UsageData usage) => usage.personal.twistAddonCount;

/// Launch [url] (a Stripe Checkout session) in the external browser and keep an
/// in-app waiting modal open until [isComplete] flips true (the purchase
/// provisioned) or the user backs out.
///
/// Returns [onComplete] on completion, [CommandSkipped] on dismissal. Detection
/// is push-driven via [SubscriptionService] — no polling. Card-on-file callers
/// never reach here (they are charged inline upstream); this is the no-card /
/// coupon path only.
Future<CommandReturn> launchCheckoutAndAwait(
  BuildContext context, {
  required String url,
  required String waitingMessage,
  required bool Function(UsageData usage) isComplete,
  required CommandReturn onComplete,
}) async {
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (err, st) {
    // Expected failure (no browser / bad URL) — log, don't capture. The waiting
    // modal still shows so the user isn't left with a dead-end.
    log.warning('Failed to open checkout', err, st);
  }
  if (!context.mounted) return const CommandSkipped();

  final completed = await CheckoutWaitingModal(
    message: waitingMessage,
    isComplete: isComplete,
  ).run(context);
  return completed ? onComplete : const CommandSkipped();
}
