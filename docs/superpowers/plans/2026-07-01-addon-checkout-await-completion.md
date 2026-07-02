# Add-on Checkout Wait-for-Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a user taps the add-on "$5/month" CTA and we open Stripe Checkout in an external browser, keep an in-app waiting state open until the purchase provisions (detected via the subscription websocket push) and then auto-continue to connect/install — instead of silently dropping back to the setup modal.

**Architecture:** A small server fix makes add-on/twist-addon provisioning emit the existing `subscription` websocket broadcast (today it returns early before notifying). On the client, a reusable `CheckoutWaitingModal` watches `SubscriptionService.instance.notifier` and closes itself when a per-site "completion predicate" flips true; a shared `launchCheckoutAndAwait` helper launches the browser, shows the modal, and maps completion→the site's success `CommandReturn` / dismissal→`CommandSkipped`. All three add-on checkout-launch sites adopt the helper. No polling.

**Tech Stack:** Flutter (Dart, `forui` + `flutter/widgets` only — never `flutter/material`), Drift `Value<T>`, the project `Modal` framework; Cloudflare Workers (TypeScript, Kysely, vitest).

## Global Constraints

- **No polling.** Completion is detected only via `SubscriptionService` refreshes, which are driven by the `subscription` websocket broadcast (`Store.onSubscriptionChanged`) and `AppLifecycleState.resumed`. Do not add timers that call `refresh()` on an interval.
- **No explicit Cancel button** on the waiting modal — the `Modal` framework's back/Esc/scrim dismissal is the only cancel affordance.
- **UI text is sentence case** (capitalize only the first word + proper nouns).
- **Flutter imports:** only `package:flutter/widgets.dart` and `package:forui/forui.dart` for UI — never `package:flutter/material.dart`.
- **Error capture:** an unexpected `catch` reports via `Tracker.captureException` (Flutter) / `tracker.captureException` (workers). Expected failures (a failed `launchUrl`, network blips) log via `log.warning` only — do NOT `captureException` them (matches existing add-on code).
- **Modals** must use the project `Modal` widget / `ModalProvider`; never `showDialog`/`showFDialog`.
- The scope-agnostic connection predicate exists because a completed connection add-on checkout increments exactly one scope's `premium.purchased`; summing across personal + all teams avoids threading owner scope into `_handleNeedsCard`.

---

### Task 1: Server — emit the subscription broadcast when an add-on is provisioned

**Files:**
- Modify: `workers/api/src/stripe/stripe.ts` — add-on branch (`return;` at line 279), twist-addon branch (`return;` at line 299), and the plan-path notify block (~lines 750-765).
- Test: `workers/api/src/stripe/stripe.test.ts` — add-on + twist-addon routing describe blocks.

**Interfaces:**
- Consumes: existing `notifySubscriptionChange(c, userIds: string[])` (stripe.ts:772) and `getOrgMemberUserIds(db, stripeCustomerId)` (stripe.ts:797).
- Produces: `notifySubscriptionChangeForCustomer(c: any, customerId: string): Promise<void>` — resolves the personal user (via `user_subscription`) and any org members (via `getOrgMemberUserIds`) for a Stripe customer and notifies all of them. Called by the add-on branch, the twist-addon branch, and (refactored) the plan path.

Context already in scope in both early-return branches: `c`, `customerId` (`subscription.customer as string`).

- [ ] **Step 1: Write the failing tests**

Add these two tests. Put the first inside the existing `describe.skipIf(!DATABASE_URL)("handleSubscriptionUpdate — add-on subscription routing", …)` block (after the test ending at ~line 466), reusing its `buildFakeContext` + `Rollback` helpers. Put the second inside the `"handleSubscriptionUpdate — twist add-on subscription routing"` block (~line 729).

```ts
// In the add-on routing describe block:
it("an addon subscription notifies the customer's user (subscription broadcast)", async () => {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const userId = randomUUID();
  const customerId = `cus_addonnotify_${randomUUID().slice(0, 8)}`;
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);
      await trx
        .insertInto("user_subscription")
        .values({
          user_id: userId,
          plan: "free",
          status: "active",
          origin: "stripe",
          stripe_customer_id: customerId,
          billing_cycle_start: new Date().toISOString(),
          billing_cycle_end: new Date(
            Date.now() + 30 * 24 * 3600 * 1000
          ).toISOString(),
        })
        .execute();

      const fakeC = buildFakeContext(trx);
      await handleSubscriptionUpdate(fakeC, {
        id: "sub_addon_notify",
        customer: customerId,
        status: "active",
        metadata: { type: "addon" },
        trial_end: null,
        items: { data: [{ quantity: 1, price: { lookup_key: "addon_monthly" } }] },
        current_period_start: Math.floor(Date.now() / 1000),
        current_period_end: Math.floor(Date.now() / 1000) + 30 * 24 * 3600,
      } as unknown as Stripe.Subscription);

      const sync = await trx
        .selectFrom("user_sync")
        .select(["user_id", "entity"])
        .where("user_id", "=", userId)
        .where("entity", "=", "subscription")
        .executeTakeFirst();
      expect(sync).toBeDefined();

      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
});
```

```ts
// In the twist add-on routing describe block:
it("a twist-addon subscription notifies the customer's user (subscription broadcast)", async () => {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  const userId = randomUUID();
  const customerId = `cus_twistnotify_${randomUUID().slice(0, 8)}`;
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);
      await trx
        .insertInto("user_subscription")
        .values({
          user_id: userId,
          plan: "pro",
          status: "active",
          origin: "stripe",
          stripe_customer_id: customerId,
          billing_cycle_start: new Date().toISOString(),
          billing_cycle_end: new Date(
            Date.now() + 30 * 24 * 3600 * 1000
          ).toISOString(),
        })
        .execute();

      const fakeC = buildFakeContext(trx);
      await handleSubscriptionUpdate(fakeC, {
        id: "sub_twistaddon_notify",
        customer: customerId,
        status: "active",
        metadata: { type: "twist_addon" },
        trial_end: null,
        items: { data: [{ quantity: 1, price: { lookup_key: "twist_addon_monthly" } }] },
        current_period_start: Math.floor(Date.now() / 1000),
        current_period_end: Math.floor(Date.now() / 1000) + 30 * 24 * 3600,
      } as unknown as Stripe.Subscription);

      const sync = await trx
        .selectFrom("user_sync")
        .select(["user_id", "entity"])
        .where("user_id", "=", userId)
        .where("entity", "=", "subscription")
        .executeTakeFirst();
      expect(sync).toBeDefined();

      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd workers/api && DATABASE_URL="$DATABASE_URL" pnpm vitest run src/stripe/stripe.test.ts -t "notifies the customer"`
Expected: 2 FAIL — no `user_sync` row with entity `subscription` is written (the branches return before notifying).

(If `DATABASE_URL` is unset the DB tests are skipped — start the local DB first, or run in a worktree with `bash scripts/worktree-db` and use its `$DATABASE_URL`.)

- [ ] **Step 3: Add the shared helper**

In `workers/api/src/stripe/stripe.ts`, add this function next to `notifySubscriptionChange` (after it, ~line 793):

```ts
/**
 * Notify every user affected by a Stripe customer's subscription change — the
 * personal owner (via `user_subscription`) and, for a team customer, all org
 * members (via `getOrgMemberUserIds`). Used by the plan, add-on, and
 * twist-addon paths so a provisioning change reaches Flutter clients over the
 * `subscription` websocket broadcast.
 */
async function notifySubscriptionChangeForCustomer(
  c: any,
  customerId: string
): Promise<void> {
  const syncUser = await c.var.db
    .selectFrom("user_subscription")
    .select("user_id")
    .where("stripe_customer_id", "=", customerId)
    .executeTakeFirst();
  if (syncUser) {
    await notifySubscriptionChange(c, [syncUser.user_id]);
  }
  const orgMemberIds = await getOrgMemberUserIds(c.var.db, customerId);
  if (orgMemberIds.length > 0) {
    await notifySubscriptionChange(c, orgMemberIds);
  }
}
```

- [ ] **Step 4: Call it in the add-on branch (before its `return;`)**

In `handleSubscriptionUpdate`, the add-on branch currently ends:

```ts
    if (Number(updated?.numUpdatedRows) === 0) {
      await c.var.db
        .updateTable("team_subscription")
        .set({
          premium_connection_addons: addonQuantity,
          stripe_addon_subscription_id: subscription.id,
          updated_at: sql`now()`,
        })
        .where("stripe_customer_id", "=", customerId)
        .execute();
    }
    return; // never run the plan path for an add-on sub
  }
```

Insert the notify call immediately before `return;`:

```ts
    if (Number(updated?.numUpdatedRows) === 0) {
      await c.var.db
        .updateTable("team_subscription")
        .set({
          premium_connection_addons: addonQuantity,
          stripe_addon_subscription_id: subscription.id,
          updated_at: sql`now()`,
        })
        .where("stripe_customer_id", "=", customerId)
        .execute();
    }
    await notifySubscriptionChangeForCustomer(c, customerId);
    return; // never run the plan path for an add-on sub
  }
```

- [ ] **Step 5: Call it in the twist-addon branch (before its `return;`)**

The twist-addon branch currently ends:

```ts
    // Teams never buy twist add-ons, so there is no team_subscription fallback.
    return; // never run the plan path for a twist add-on sub
  }
```

Insert:

```ts
    // Teams never buy twist add-ons, so there is no team_subscription fallback.
    await notifySubscriptionChangeForCustomer(c, customerId);
    return; // never run the plan path for a twist add-on sub
  }
```

- [ ] **Step 6: Refactor the plan path to use the helper (DRY)**

Find the plan path's notify block (the one containing `const syncUser = await c.var.db.selectFrom("user_subscription")…` followed by `notifySubscriptionChange(c, [syncUser.user_id])` and the `getOrgMemberUserIds` block, ~lines 750-765). Replace that whole block with:

```ts
  // Notify affected users so the Flutter app picks up the plan change.
  await notifySubscriptionChangeForCustomer(c, customerId);
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `cd workers/api && DATABASE_URL="$DATABASE_URL" pnpm vitest run src/stripe/stripe.test.ts`
Expected: all PASS, including the two new tests and the existing add-on/twist-addon/plan routing tests.

- [ ] **Step 8: Lint**

Run: `cd workers/api && pnpm lint`
Expected: no errors.

- [ ] **Step 9: Commit**

```bash
git add workers/api/src/stripe/stripe.ts workers/api/src/stripe/stripe.test.ts
git commit -m "fix(api): broadcast subscription change on add-on/twist-addon provisioning"
```

---

### Task 2: `CheckoutWaitingModal` widget

**Files:**
- Create: `apps/plot/lib/widget/checkout_waiting_modal.dart`
- Test: `apps/plot/test/widget/checkout_waiting_modal_test.dart`

**Interfaces:**
- Consumes: `SubscriptionService.instance.notifier` (`ValueNotifier<SubscriptionSnapshot>`), `SubscriptionSnapshot.usage` (`UsageData?`), `Modal` / `Modal.pop` / `Modal.show`, Drift `Value<T>`, `Spinner.message(String)` (`lib/widget/spinner.dart`).
- Produces: `class CheckoutWaitingModal` with `Future<bool> run(BuildContext)` — resolves `true` when `isComplete(usage)` flipped true (checkout provisioned), `false` on user dismissal or the safety-cap timeout. Constructor:
  `CheckoutWaitingModal({required String message, required bool Function(UsageData usage) isComplete, ValueListenable<SubscriptionSnapshot>? listenable, Duration timeout = const Duration(minutes: 10), Key? key})`.

- [ ] **Step 1: Write the widget (no test yet)**

Create `apps/plot/lib/widget/checkout_waiting_modal.dart`:

```dart
import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:plot/api/upgrade_api.dart';
import 'package:plot/state/subscription_service.dart';
import 'package:plot/util/value.dart';
import 'package:plot/widget/modal.dart';
import 'package:plot/widget/spinner.dart';

/// Shown while the user completes a Stripe Checkout in an external browser.
///
/// Watches subscription state and closes itself — resolving `true` from [run] —
/// the moment [isComplete] becomes true (i.e. the purchase provisioned). If the
/// user dismisses it (back / Esc / scrim) [run] resolves `false`. A safety cap
/// ([timeout]) auto-dismisses so it can never hang if the user never returns.
///
/// Detection is push-driven: [listenable] (the app-wide [SubscriptionService]
/// by default) is refreshed on the `subscription` websocket broadcast and on
/// app resume. There is no polling here.
class CheckoutWaitingModal extends StatefulWidget {
  const CheckoutWaitingModal({
    required this.message,
    required this.isComplete,
    this.listenable,
    this.timeout = const Duration(minutes: 10),
    super.key,
  });

  final String message;
  final bool Function(UsageData usage) isComplete;

  /// Subscription snapshots to watch. Defaults to [SubscriptionService.instance].
  final ValueListenable<SubscriptionSnapshot>? listenable;
  final Duration timeout;

  /// Show the modal. Resolves `true` when checkout completed (provisioned),
  /// `false` when the user dismissed it or the safety cap fired.
  Future<bool> run(BuildContext context) async {
    final result = await Modal(
      showCloseButton: false,
      builder: (_) => this,
    ).show<bool>(context);
    return result.present;
  }

  @override
  State<CheckoutWaitingModal> createState() => _CheckoutWaitingModalState();
}

class _CheckoutWaitingModalState extends State<CheckoutWaitingModal> {
  ValueListenable<SubscriptionSnapshot> get _listenable =>
      widget.listenable ?? SubscriptionService.instance.notifier;

  Timer? _capTimer;
  bool _resolved = false;

  @override
  void initState() {
    super.initState();
    _listenable.addListener(_check);
    _capTimer = Timer(widget.timeout, _timeout);
    // Handle the case where the credit already landed before the modal mounted
    // (a push can arrive between the caller capturing its baseline and here).
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    _listenable.removeListener(_check);
    _capTimer?.cancel();
    super.dispose();
  }

  void _check() {
    if (_resolved || !mounted) return;
    final usage = _listenable.value.usage;
    if (usage != null && widget.isComplete(usage)) {
      _resolved = true;
      Modal.pop<bool>(context, const Value<bool>(true));
    }
  }

  void _timeout() {
    if (_resolved || !mounted) return;
    _resolved = true;
    Modal.pop<bool>(context, const Value<bool>.absent());
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      child: Spinner.message(widget.message),
    );
  }
}
```

- [ ] **Step 2: Write the widget test**

Mirror the harness in `apps/plot/test/widget/modal_pop_for_swap_test.dart` (it wraps content in a `ModalProvider` + test app and drives `Modal`). Create `apps/plot/test/widget/checkout_waiting_modal_test.dart`:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import 'package:plot/api/upgrade_api.dart';
import 'package:plot/state/subscription_service.dart';
import 'package:plot/widget/checkout_waiting_modal.dart';
import 'package:plot/widget/modal.dart';

// Minimal UsageData carrying one personal connection add-on credit count.
UsageData _usageWithConnectionCredits(int purchased) => UsageData.fromJson({
      'personal': {
        'connections': {'count': 0},
        'twists': {'count': 0},
        'premium': {'allowed': true, 'count': 0, 'purchased': purchased},
        'twistAddonCount': 0,
      },
      'teams': <dynamic>[],
      'pricing': {'connectionAddonPrice': 5},
    });

void main() {
  Widget host(Widget child) => FTheme(
        data: FThemes.zinc.light,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: ModalProvider(child: child),
        ),
      );

  testWidgets('resolves true when isComplete flips via the listenable',
      (tester) async {
    final notifier = ValueNotifier<SubscriptionSnapshot>(
      SubscriptionSnapshot(usage: _usageWithConnectionCredits(0)),
    );
    bool? result;
    late BuildContext ctx;
    await tester.pumpWidget(host(Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })));

    final future = CheckoutWaitingModal(
      message: 'Complete checkout in your browser to add the connection.',
      isComplete: (u) => (u.personal.premium?.purchased ?? 0) > 0,
      listenable: notifier,
    ).run(ctx).then((r) => result = r);
    await tester.pump(); // show the modal

    notifier.value =
        SubscriptionSnapshot(usage: _usageWithConnectionCredits(1));
    await tester.pump(); // listener fires -> Modal.pop(true)
    await tester.pumpAndSettle();
    await future;

    expect(result, isTrue);
  });

  testWidgets('resolves false when the safety cap fires', (tester) async {
    final notifier = ValueNotifier<SubscriptionSnapshot>(
      SubscriptionSnapshot(usage: _usageWithConnectionCredits(0)),
    );
    bool? result;
    late BuildContext ctx;
    await tester.pumpWidget(host(Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })));

    final future = CheckoutWaitingModal(
      message: 'Complete checkout in your browser to add the connection.',
      isComplete: (u) => (u.personal.premium?.purchased ?? 0) > 0,
      listenable: notifier,
      timeout: const Duration(milliseconds: 50),
    ).run(ctx).then((r) => result = r);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60)); // cap fires
    await tester.pumpAndSettle();
    await future;

    expect(result, isFalse);
  });
}
```

- [ ] **Step 3: Run the test**

Run: `cd apps/plot && flutter test test/widget/checkout_waiting_modal_test.dart`
Expected: PASS (both cases). If the `FTheme`/`ModalProvider` host differs from `modal_pop_for_swap_test.dart`, copy that file's exact wrapper (it is the source of truth for the modal test harness).

- [ ] **Step 4: Analyze**

Run: `cd apps/plot && flutter analyze lib/widget/checkout_waiting_modal.dart test/widget/checkout_waiting_modal_test.dart`
Expected: no issues.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/widget/checkout_waiting_modal.dart apps/plot/test/widget/checkout_waiting_modal_test.dart
git commit -m "feat(app): CheckoutWaitingModal — in-app wait for external checkout"
```

---

### Task 3: `launchCheckoutAndAwait` helper + completion predicates

**Files:**
- Create: `apps/plot/lib/command/checkout_await.dart`
- Test: `apps/plot/test/command/checkout_await_test.dart`

**Interfaces:**
- Consumes: `CheckoutWaitingModal` (Task 2), `UsageData` / `PersonalUsage` / `TeamUsage` / `PremiumUsage` (`lib/api/upgrade_api.dart`), `CommandReturn`/`CommandSkipped` (`lib/command/base.dart`), `SubscriptionService.instance.usage`, `launchUrl`/`LaunchMode` (`package:url_launcher/url_launcher.dart`), `log` (`lib/logging.dart`).
- Produces:
  - `int connectionAddonCreditTotal(UsageData usage)` — `personal.premium.purchased` + Σ `teams[].premium.purchased`.
  - `int twistAddonCreditTotal(UsageData usage)` — `personal.twistAddonCount`.
  - `Future<CommandReturn> launchCheckoutAndAwait(BuildContext context, {required String url, required String waitingMessage, required bool Function(UsageData usage) isComplete, required CommandReturn onComplete})`.

- [ ] **Step 1: Write the failing predicate tests**

Create `apps/plot/test/command/checkout_await_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';

import 'package:plot/api/upgrade_api.dart';
import 'package:plot/command/checkout_await.dart';

UsageData _usage({
  required int personalPurchased,
  int twistAddonCount = 0,
  List<int> teamPurchased = const [],
}) =>
    UsageData.fromJson({
      'personal': {
        'connections': {'count': 0},
        'twists': {'count': 0},
        'premium': {
          'allowed': true,
          'count': 0,
          'purchased': personalPurchased,
        },
        'twistAddonCount': twistAddonCount,
      },
      'teams': [
        for (var i = 0; i < teamPurchased.length; i++)
          {
            'id': 'team$i',
            'name': 'Team $i',
            'plan': 'team',
            'connections': {'count': 0},
            'premium': {
              'allowed': true,
              'count': 0,
              'purchased': teamPurchased[i],
            },
            'is_admin': true,
          },
      ],
      'pricing': {'connectionAddonPrice': 5},
    });

void main() {
  test('connectionAddonCreditTotal sums personal + all teams', () {
    expect(connectionAddonCreditTotal(_usage(personalPurchased: 2)), 2);
    expect(
      connectionAddonCreditTotal(
        _usage(personalPurchased: 1, teamPurchased: [3, 2]),
      ),
      6,
    );
  });

  test('twistAddonCreditTotal reads personal twistAddonCount', () {
    expect(
      twistAddonCreditTotal(_usage(personalPurchased: 0, twistAddonCount: 4)),
      4,
    );
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd apps/plot && flutter test test/command/checkout_await_test.dart`
Expected: FAIL — `checkout_await.dart` / the functions don't exist yet.

- [ ] **Step 3: Write the helper + predicates**

Create `apps/plot/lib/command/checkout_await.dart`:

```dart
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
```

- [ ] **Step 4: Run the predicate tests to verify they pass**

Run: `cd apps/plot && flutter test test/command/checkout_await_test.dart`
Expected: PASS.

- [ ] **Step 5: Analyze**

Run: `cd apps/plot && flutter analyze lib/command/checkout_await.dart test/command/checkout_await_test.dart`
Expected: no issues.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/command/checkout_await.dart apps/plot/test/command/checkout_await_test.dart
git commit -m "feat(app): launchCheckoutAndAwait helper + add-on completion predicates"
```

---

### Task 4: Wire the two purchase sites (`upgrade.dart`)

**Files:**
- Modify: `apps/plot/lib/command/upgrade.dart` — `BuyAddonCommand._consent` (~lines 235-255) and `BuyTwistAddonCommand` (~lines 578-591).

**Interfaces:**
- Consumes: `launchCheckoutAndAwait`, `connectionAddonCreditTotal`, `twistAddonCreditTotal` (Task 3); existing `CommandAddonConsented`, `CommandDone`, `CommandSkipped`.

- [ ] **Step 1: Import the helper**

At the top of `apps/plot/lib/command/upgrade.dart`, add with the other `package:plot/command/...` imports:

```dart
import 'package:plot/command/checkout_await.dart';
```

- [ ] **Step 2: Rewrite the no-card branch of `BuyAddonCommand._consent`**

Find this block (the connection add-on no-card branch):

```dart
      final result = await UpgradeApi.purchaseAddon(teamId: teamId);
      final url = result.checkoutUrl;
      if (!result.ok && url != null) {
        try {
          await launchUrl(
            Uri.parse(url),
            mode: LaunchMode.externalApplication,
          );
        } catch (err, st) {
          log.warning('Failed to open add-on checkout', err, st);
        }
        if (context.mounted) {
          context.showToast(
            message:
                'Add a payment method or coupon in your browser, then connect '
                'again.',
          );
        }
        return const CommandSkipped();
      }
      // Provisioned (or already had an unused credit) — proceed to connect.
      return const CommandAddonConsented();
```

Replace it with:

```dart
      final result = await UpgradeApi.purchaseAddon(teamId: teamId);
      if (!context.mounted) return const CommandSkipped();
      final url = result.checkoutUrl;
      if (!result.ok && url != null) {
        // No card on file → finish the coupon-or-card Checkout in the browser.
        // Keep an in-app waiting state open until the credit provisions, then
        // proceed to connect. Backing out cancels.
        final usage = SubscriptionService.instance.usage;
        final baseline = usage == null ? 0 : connectionAddonCreditTotal(usage);
        return launchCheckoutAndAwait(
          context,
          url: url,
          waitingMessage:
              'Complete checkout in your browser to add the connection.',
          isComplete: (u) => connectionAddonCreditTotal(u) > baseline,
          onComplete: const CommandAddonConsented(),
        );
      }
      // Provisioned (or already had an unused credit) — proceed to connect.
      return const CommandAddonConsented();
```

(Ensure `SubscriptionService` is imported in this file — it already is, used elsewhere in `upgrade.dart`.)

- [ ] **Step 3: Rewrite the no-card branch of `BuyTwistAddonCommand`**

Find the twist add-on checkout branch:

```dart
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
```

Replace with (reusing the `previousCount` already captured earlier in this method as the baseline):

```dart
      final url = result.checkoutUrl;
      if (url != null) {
        // No card on file → finish checkout in the browser; wait for the twist
        // add-on credit to provision, then continue to install.
        return launchCheckoutAndAwait(
          context,
          url: url,
          waitingMessage:
              'Complete checkout in your browser to add the twist add-on.',
          isComplete: (u) => twistAddonCreditTotal(u) > previousCount,
          onComplete: const CommandDone(
            message: 'Twist add-on added — install the twist again to finish.',
          ),
        );
      }
      return const CommandSkipped();
```

- [ ] **Step 4: Analyze**

Run: `cd apps/plot && flutter analyze lib/command/upgrade.dart`
Expected: no issues. (If `launchUrl`/`LaunchMode` are now unused in the file, remove the now-dead `url_launcher` import only if nothing else in the file uses it — several other sites still do, so it should remain.)

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/command/upgrade.dart
git commit -m "feat(app): wait for add-on/twist checkout completion in upgrade commands"
```

---

### Task 5: Wire the needs-card site + its three callers (`twist.dart`)

**Files:**
- Modify: `apps/plot/lib/command/twist.dart` — `_handleNeedsCard` (~lines 957-975) and its three call sites (`e.needsCard` branches at ~3891, ~4225, ~4741).

**Interfaces:**
- Consumes: `launchCheckoutAndAwait`, `connectionAddonCreditTotal` (Task 3); each caller's own `_attempt(context, {consentAddon})` (defined at ~3820, ~4171, ~4594); `CommandAddonConsented`, `CommandSkipped`.

- [ ] **Step 1: Import the helper**

At the top of `apps/plot/lib/command/twist.dart`, add with the other `package:plot/command/...` imports:

```dart
import 'package:plot/command/checkout_await.dart';
```

- [ ] **Step 2: Rewrite `_handleNeedsCard` to wait for completion**

Replace the whole function (currently ~957-975):

```dart
Future<CommandReturn> _handleNeedsCard(
  BuildContext context,
  ApiException e,
) async {
  final url = e.checkoutUrl;
  if (url != null) {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (err, st) {
      log.warning('Failed to open card-setup checkout', err, st);
    }
  }
  if (context.mounted) {
    context.showToast(
      message: 'Add a payment method in your browser, then connect again.',
    );
  }
  return const CommandSkipped();
}
```

with (also update the docstring above it — the URL is now the coupon-or-card Checkout, not a $0 setup session):

```dart
/// After an enable returned needs_card (402, [ApiException.needsCard]): open the
/// coupon-or-card Stripe Checkout and keep an in-app waiting state open until
/// the add-on credit provisions. On completion returns [CommandAddonConsented]
/// so the caller retries the enable (a spare credit now exists); on dismissal
/// returns [CommandSkipped].
Future<CommandReturn> _handleNeedsCard(
  BuildContext context,
  ApiException e,
) async {
  final url = e.checkoutUrl;
  if (url == null) return const CommandSkipped();
  final usage = SubscriptionService.instance.usage;
  final baseline = usage == null ? 0 : connectionAddonCreditTotal(usage);
  return launchCheckoutAndAwait(
    context,
    url: url,
    waitingMessage: 'Complete checkout in your browser to add the connection.',
    isComplete: (u) => connectionAddonCreditTotal(u) > baseline,
    onComplete: const CommandAddonConsented(),
  );
}
```

(`SubscriptionService` is already imported in `twist.dart`.)

- [ ] **Step 3: Make each of the three callers retry the enable on completion**

Each of the three call sites is currently identical:

```dart
      if (e.needsCard) {
        return context.mounted
            ? _handleNeedsCard(context, e)
            : const CommandSkipped();
      }
```

Replace each occurrence (there are three — at ~3891, ~4225, ~4741) with:

```dart
      if (e.needsCard) {
        if (!context.mounted) return const CommandSkipped();
        final result = await _handleNeedsCard(context, e);
        // Checkout completed → a spare credit now exists; retry the enable so
        // the connection actually connects (mirrors the isAddonRequired path).
        return result is CommandAddonConsented && context.mounted
            ? _attempt(context, consentAddon: true)
            : result;
      }
```

Each of the three enclosing functions has its own `_attempt(context, {consentAddon})` in scope (verified: retried identically in the adjacent `isAddonRequired && !consentAddon` branch of each). Use `replace_all: false` and apply to each occurrence individually so you can confirm the surrounding `_attempt` is in scope.

- [ ] **Step 4: Analyze**

Run: `cd apps/plot && flutter analyze lib/command/twist.dart`
Expected: no issues. (If `launchUrl`/`LaunchMode` become unused in `twist.dart`, remove that import; confirm no other site in the file uses it first.)

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/command/twist.dart
git commit -m "feat(app): wait for needs-card checkout then retry the enable"
```

---

### Task 6: Docs fragment + finalize

**Files:**
- Create: `docs/updates.d/<slug>-<id>.md` (via `pnpm updates:new`)
- Verify: repo-wide analyze/lint for the changed packages.

- [ ] **Step 1: Add a user-facing update fragment**

Run: `pnpm updates:new "Adding a paid connection or twist add-on now keeps a clear in-app status while you finish checkout in your browser, and connects automatically when payment goes through."`

Then open the generated `docs/updates.d/*.md` and ensure the bullet sits under a `### Fixes` section (it's a UX fix). Plain language only — no technical detail.

- [ ] **Step 2: Full analyze (Flutter) + lint (worker)**

Run: `cd apps/plot && flutter analyze`
Expected: no new issues.

Run: `cd workers/api && pnpm lint`
Expected: no errors.

- [ ] **Step 3: Run the touched test suites once more**

Run: `cd apps/plot && flutter test test/widget/checkout_waiting_modal_test.dart test/command/checkout_await_test.dart`
Run: `cd workers/api && DATABASE_URL="$DATABASE_URL" pnpm vitest run src/stripe/stripe.test.ts`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add docs/updates.d
git commit -m "docs: update fragment for add-on checkout waiting state"
```

---

## Manual verification (after implementation)

With a no-card scope (e.g. a personal customer without a card):
1. Trigger a premium connection add-on ("Add connection" on LinkedIn) → tap "Add for $5/month".
2. Confirm the app shows the in-app waiting state ("Complete checkout in your browser to add the connection.") instead of dropping back to the setup modal.
3. Complete the Stripe Checkout in the browser (enter the 100%-off coupon or a card) and return to the app → the waiting state should clear and the connection should proceed to connect automatically (no manual "connect again").
4. Repeat but **back out** of the waiting modal → it cancels cleanly, nothing charged/connected.
5. Card-on-file scope: confirm the browser/waiting state never appears (charged inline, proceeds).

## Issue #1 reminder (not part of this plan)

The missing coupon field is a **deploy** matter, not code: #531's worker deploy was skipped (terraform gate failure), so `allow_promotion_codes` isn't live in prod. Re-run a production **Deploy Production** run with the Deploy workers option on `main`, then verify the promo-code box appears on the add-on checkout. See the design spec for the full CI evidence.
