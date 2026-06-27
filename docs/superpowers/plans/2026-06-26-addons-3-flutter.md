# Add-ons Plan 3 — Flutter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Flutter app treat connection add-ons as independent + usage-based: no "requires a paid plan" gate, and enabling an add-on connector that's out of headroom runs an explicit one-credit purchase (off-session charge or a Checkout link on web/desktop/Android; the next StoreKit tier on the App Store) instead of a quantity picker.

**Architecture:** Three layers. (1) Plumb the server's 403 `reason` through `ApiException` so the client can distinguish `addon_required`. (2) Add `UpgradeApi.purchaseAddon` and rework `BuyAddonCommand` into a single-credit purchase (App Store: next tier via StoreKit; elsewhere: `POST /upgrade/addons/purchase` → either charged, or open `checkout_url`), guarded against concurrent checkout starts. (3) Simplify the premium gate — delete the "requires a paid plan" (`blocked`) path — and route the server's `addon_required` 403 to the purchase flow. Fix the now-stale copy.

**Tech Stack:** Flutter/Dart, flutter_bloc, forui. `flutter analyze` is the type gate; `flutter test` for pure-logic tests. UI command flows (BuyAddonCommand, the gate) need runtime context + StoreKit, so they are verified by `flutter analyze` + review, not unit tests — only pure logic (`ApiException.reason`, `PremiumUsage`) is unit-tested.

## Global Constraints

- Add-on connectors are `twist.premium = true`. Pricing/UI text: web `$5/mo`; App Store tiers `addon_1/2/3` (cap `kIapMaxAddons = 3`).
- Charging is EXPLICIT and consent-gated: the purchase flow always shows the `SubscriptionDisclosure` confirm before any charge; enabling a connector never charges by itself.
- Add-ons do NOT count toward the plan connection limit; never tell the user they "require a paid plan" or "count as a regular connection".
- Do NOT touch any `apps/site/` files (owned by another agent). Do NOT remove the old `POST /upgrade/addons` endpoint or the server.
- Server contract (already shipped on this branch): enabling out-of-headroom → HTTP 403 `{ code: "plan_limit_exceeded", reason: "addon_required", is_team, is_admin, team_id, ... }`. `POST /upgrade/addons/purchase` body `{ teamId? }` → `{ ok: true, addons }` (charged) or `{ ok: false, checkout_url }` (open in browser).
- Run `cd apps/plot && flutter analyze` (0 issues in changed files) and `flutter test <file>` for added tests. Commit after each task; every commit message ends with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. (No DB / DATABASE_URL needed — this is the Flutter app.)

## File structure

- `apps/plot/lib/api/api_exception.dart` — add `reason` field + `isAddonRequired` getter.
- `apps/plot/lib/api/api.dart` — `_parseErrorFields` extracts `reason`.
- `apps/plot/lib/api/upgrade_api.dart` — add `purchaseAddon({teamId})`; `PremiumUsage` doc tweak.
- `apps/plot/lib/command/upgrade.dart` — rework `BuyAddonCommand`; remove `_pickAddonCount`; update disclosure copy.
- `apps/plot/lib/command/twist.dart` — drop the `blocked` gate path + `_addonNeedsPaidPlanCommand`; route `addon_required` catches to the purchase command.
- `apps/plot/lib/widget/pro_badge.dart` — copy.
- Tests: `apps/plot/test/api/api_exception_test.dart` (new), and any existing `PremiumUsage`/upgrade tests.

---

### Task 1: Plumb the server 403 `reason` through `ApiException`

**Files:**
- Modify: `apps/plot/lib/api/api_exception.dart`, `apps/plot/lib/api/api.dart` (`_parseErrorFields`, ~lines 80–104).
- Test: `apps/plot/test/api/api_exception_test.dart` (new).

**Interfaces:**
- Produces: `ApiException.reason` (`String?`) and `bool get isAddonRequired => code == 'plan_limit_exceeded' && reason == 'addon_required';`.

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/api/api_exception_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/api/api_exception.dart';

void main() {
  test('isAddonRequired is true only for plan_limit_exceeded + addon_required', () {
    expect(
      ApiException('msg', code: 'plan_limit_exceeded', reason: 'addon_required')
          .isAddonRequired,
      isTrue,
    );
    expect(
      ApiException('msg', code: 'plan_limit_exceeded', reason: 'connection_limit')
          .isAddonRequired,
      isFalse,
    );
    expect(ApiException('msg', code: 'plan_limit_exceeded').isAddonRequired, isFalse);
  });
}
```

(Match the real `ApiException` constructor shape — read `api_exception.dart` first; if its constructor is positional/named differently, adapt the test to the real signature while keeping the three assertions.)

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd apps/plot && flutter test test/api/api_exception_test.dart`
Expected: FAIL — `reason` is not a parameter/field yet.

- [ ] **Step 3: Add `reason` + `isAddonRequired` to `ApiException`**

In `api_exception.dart`, add a `final String? reason;` field, accept it in the constructor (named, defaulting null, mirroring how `code` is declared), and add:

```dart
  bool get isAddonRequired =>
      code == 'plan_limit_exceeded' && reason == 'addon_required';
```

- [ ] **Step 4: Extract `reason` in `_parseErrorFields`**

In `api.dart` `_parseErrorFields` (~:85–92), where it reads `code`/`limit_type`/etc. from the body, also read `reason` (`body['reason'] as String?`) and pass it into the `ApiException(...)` it constructs.

- [ ] **Step 5: Run the test to confirm it passes + analyze**

Run: `cd apps/plot && flutter test test/api/api_exception_test.dart` → PASS.
Run: `flutter analyze lib/api/api_exception.dart lib/api/api.dart` → no issues.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/api/api_exception.dart apps/plot/lib/api/api.dart apps/plot/test/api/api_exception_test.dart
git commit -m "feat(app): expose server PlanLimit reason via ApiException.isAddonRequired"
```

---

### Task 2: `UpgradeApi.purchaseAddon` + rework `BuyAddonCommand` into a one-credit purchase

**Files:**
- Modify: `apps/plot/lib/api/upgrade_api.dart` (add `purchaseAddon`).
- Modify: `apps/plot/lib/command/upgrade.dart` (rework `BuyAddonCommand`, remove `_pickAddonCount`, update disclosure copy).

**Interfaces:**
- Consumes: `IapService.instance.buyAddon(int count)` (StoreKit, App Store), `SubscriptionService.instance.usage?.personal.premium?.purchased`, `kIapMaxAddons`.
- Produces: `UpgradeApi.purchaseAddon({String? teamId}) -> Future<({bool ok, int? addons, String? checkoutUrl})>` (or a small result class). `BuyAddonCommand` now purchases exactly ONE more credit and never shows a 0–3 picker.

- [ ] **Step 1: Add `purchaseAddon` to `UpgradeApi`**

In `upgrade_api.dart`, following the `getPortalUrl` POST pattern:

```dart
/// Result of provisioning one more connection add-on credit.
class AddonPurchase {
  const AddonPurchase({required this.ok, this.addons, this.checkoutUrl});
  final bool ok;
  final int? addons;
  final String? checkoutUrl;
}

static Future<AddonPurchase> purchaseAddon({String? teamId}) async {
  final response = await api.post<Map<String, dynamic>>(
    '/upgrade/addons/purchase',
    body: {if (teamId != null) 'teamId': teamId},
  );
  return AddonPurchase(
    ok: response['ok'] == true,
    addons: response['addons'] as int?,
    checkoutUrl: response['checkout_url'] as String?,
  );
}
```

- [ ] **Step 2: Rework `BuyAddonCommand.run`**

Replace the body of `BuyAddonCommand` (`upgrade.dart:153–303`) so it provisions ONE more add-on credit:
- **Team scope** (`teamId != null`): always go through the endpoint (Stripe; the server admin-gates): `_purchaseViaEndpoint(context, teamId)`.
- **Personal + App Store build** (`UpgradeUi.isAppStoreBuild`): buy the NEXT StoreKit tier. Compute `current = SubscriptionService.instance.usage?.personal.premium?.purchased ?? 0`; if `current >= kIapMaxAddons`, toast "You've reached the maximum connection add-ons on this device." and return `CommandSkipped`; else confirm via `ConfirmModal(messageWidget: SubscriptionDisclosure(...))`, then `IapService.instance.buyAddon(current + 1)`, handling the existing `IapPurchaseStatus` switch (on `purchased`: `await SubscriptionService.instance.refresh()`, toast "Connection add-on added.").
- **Personal + non-App-Store**: `_purchaseViaEndpoint(context, null)`.

Add the helper (with a concurrent-checkout guard — the Plan 2 review flagged that two card-less purchases would orphan a 2nd sub):

```dart
// Guards against starting two add-on checkouts at once (a 2nd standalone
// add-on subscription would orphan and bill forever — see Plan 2 review).
bool _addonPurchaseInFlight = false;

Future<CommandReturn> _purchaseViaEndpoint(BuildContext context, String? teamId) async {
  if (_addonPurchaseInFlight) return const CommandSkipped();
  // Consent before any charge.
  final confirmed = await ConfirmModal(
    title: 'Add a connection add-on',
    messageWidget: const SubscriptionDisclosure(
      priceLine: 'Connection add-on — \$5/month',
      note: 'Billed separately from your plan. It does not count toward your '
          'plan\'s connection limit.',
    ),
    confirmLabel: 'Add for \$5/month',
  ).run(context);
  if (!context.mounted || !confirmed) return const CommandSkipped();

  _addonPurchaseInFlight = true;
  try {
    final result = await UpgradeApi.purchaseAddon(teamId: teamId);
    if (!context.mounted) return const CommandSkipped();
    if (result.ok) {
      await SubscriptionService.instance.refresh();
      if (context.mounted) {
        context.showToast(message: 'Connection add-on added.');
      }
      return const CommandDone();
    }
    final url = result.checkoutUrl;
    if (url != null) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (context.mounted) {
        context.showToast(
          message: 'Finish checkout in your browser, then connect again.',
        );
      }
      return const CommandSkipped();
    }
    return const CommandSkipped();
  } catch (e, st) {
    log.warning('Add-on purchase failed', e, st);
    if (context.mounted) {
      context.showToast(message: 'Could not add a connection add-on.', isError: true);
    }
    return const CommandSkipped();
  } finally {
    _addonPurchaseInFlight = false;
  }
}
```

Delete `_pickAddonCount` (no longer used). Keep `SubscriptionDisclosure`.

- [ ] **Step 3: Update the disclosure copy**

In `SubscriptionDisclosure`/the add-on disclosure (`upgrade.dart:272` was the old picker note), ensure no remaining text says add-ons "bill on top of your plan" or "count as one of your plan connections". The add-on purchase note must read like: "Billed separately from your plan. It does not count toward your plan's connection limit." Keep the existing auto-renew + Terms/Privacy disclosure block intact (3.1.2).

- [ ] **Step 4: Analyze**

Run: `cd apps/plot && flutter analyze lib/api/upgrade_api.dart lib/command/upgrade.dart`
Expected: no issues. (`_pickAddonCount` removed cleanly; no unused imports — remove `SelectModal`/`ListTile` imports if they became unused.)

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/api/upgrade_api.dart apps/plot/lib/command/upgrade.dart
git commit -m "feat(app): one-credit add-on purchase (StoreKit tier / Stripe purchase+checkout)"
```

---

### Task 3: Remove the "requires a paid plan" gate + route `addon_required` to the purchase flow + copy

**Files:**
- Modify: `apps/plot/lib/command/twist.dart` (`_evaluatePremium`, `_premiumGateCommand`, delete `_addonNeedsPaidPlanCommand`; the 403 catch sites at `_ActivateNoProviderSource.run` ~:3845, the OAuth activate path, and `SaveSource.run` ~:4309).
- Modify: `apps/plot/lib/widget/pro_badge.dart` (doc/label copy).

**Interfaces:**
- Consumes: `ApiException.isAddonRequired` (Task 1), `BuyAddonCommand` (Task 2).
- Produces: the premium gate has no `blocked`/"requires a paid plan" outcome; out-of-headroom (pre-emptive OR server 403 `addon_required`) routes to `BuyAddonCommand`.

- [ ] **Step 1: Simplify `_evaluatePremium` + `_premiumGateCommand`; delete `_addonNeedsPaidPlanCommand`**

In `twist.dart`:
- `_evaluatePremium` (`:948–961`): remove the `_PremiumGate.blocked` returns. New body: a missing/elapsed payload or having headroom → `allowed`; `premium.needsAddon` → `atLimit`. Concretely:

```dart
_PremiumGate _evaluatePremium({required UsageData usage, required String owner}) {
  final PremiumUsage? premium = owner == 'personal'
      ? usage.personal.premium
      : usage.teams.firstWhereOrNull((t) => t.id == owner)?.premium;
  // Add-ons are available on any plan now; only "out of purchased credits"
  // requires action. A missing payload (older server) is treated as needing a
  // purchase rather than blocking outright.
  if (premium == null) return _PremiumGate.atLimit;
  return premium.needsAddon ? _PremiumGate.atLimit : _PremiumGate.allowed;
}
```

- `_premiumGateCommand` (`:923–937`): drop the `blocked` branch (the `switch` now has only `allowed`→null and `atLimit`→`_addonNeededCommand(owner)`):

```dart
Command? _premiumGateCommand({required UsageData usage, required String owner, required bool isPremium}) {
  if (!isPremium) return null;
  switch (_evaluatePremium(usage: usage, owner: owner)) {
    case _PremiumGate.allowed:  return null;
    case _PremiumGate.atLimit:  return _addonNeededCommand(owner: owner);
  }
}
```

- Delete `_addonNeedsPaidPlanCommand` (`:906–910`) and remove `_PremiumGate.blocked` from the `enum _PremiumGate { allowed, atLimit }`. (The 6 `_premiumGateCommand` call sites are unchanged.)

- [ ] **Step 2: Route server `addon_required` 403s to the purchase command**

At each `isPlanLimitExceeded` catch that handles a CONNECTION enable (the `_ActivateNoProviderSource.run` toast path ~:3845, the `AddSourceDetail` OAuth-activate toast path, and `SaveSource.run` ~:4309): before the existing connection-limit handling, add:

```dart
      if (e.isAddonRequired) {
        return BuyAddonCommand(
          teamId: e.isTeam == true ? e.teamId : null,
        ).run(context);
      }
```

So an add-on-headroom 403 opens the one-credit purchase instead of the generic "you've reached your connection limit" toast/upgrade picker. Leave the non-add-on connection-limit handling exactly as-is for the `else` path. (Confirm `BuyAddonCommand`/`ApiException` are imported in `twist.dart`; `BuyAddonCommand` is already imported per the file header.)

- [ ] **Step 3: Fix copy**

- `pro_badge.dart`: update the doc comment "Enabling one needs a purchased $5/mo add-on and counts as a regular connection." → "Enabling one needs a purchased $5/mo connection add-on; it does not count toward your plan's connection limit." (Badge label text `'Add-on'` unchanged.)
- Grep `twist.dart` for any remaining "require a paid plan" / "counts as a regular connection" / "one of your plan connections" strings and remove/reword (the only one should have been `_addonNeedsPaidPlanCommand`, now deleted).

- [ ] **Step 4: Analyze**

Run: `cd apps/plot && flutter analyze lib/command/twist.dart lib/widget/pro_badge.dart`
Expected: no issues. In particular the `_PremiumGate` enum no longer has `blocked` (switches are exhaustive) and `_addonNeedsPaidPlanCommand` has no remaining references.

- [ ] **Step 5: Full analyze of the app**

Run: `cd apps/plot && flutter analyze` → no NEW issues in the files this plan touched. (A clean run is ideal; if pre-existing unrelated issues exist, confirm none are in `api*.dart`, `command/upgrade.dart`, `command/twist.dart`, `widget/pro_badge.dart`.)

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/command/twist.dart apps/plot/lib/widget/pro_badge.dart
git commit -m "feat(app): drop add-on paid-plan gate; route addon_required to one-credit purchase"
```

---

## Self-Review

**Spec coverage (Plan 3 slice):** gate "requires a paid plan" removed (T3); `PremiumUsage.allowed` is read from the server (now always true) and the `blocked` path no longer consulted (T3); `BuyAddonCommand` reframed to a per-connection one-credit purchase, App Store next-tier vs Stripe purchase+checkout, no manual quantity picker (T2); `addon_required` distinguished + routed to purchase both pre-emptively (gate) and reactively (403 catch) (T1+T3); concurrent-checkout guard added (T2, addresses the Plan 2 review's orphan-sub risk); copy fixed (T2+T3). The "regular X of N count excludes add-ons" requirement is already satisfied server-side (Plan 1) and the `_usageSuffix` "Add-ons: X of Y" line still renders (gated on `purchased > 0`).

**Testing reality:** Only pure logic is unit-tested (`ApiException.isAddonRequired`, T1). `_evaluatePremium`/`_premiumGateCommand` are private and `BuyAddonCommand` needs runtime context + StoreKit, so they're verified via `flutter analyze` (exhaustive-switch + reference checks) and review. A device/TestFlight pass is required to validate the actual purchase + enable round-trip (note for the human; out of automated scope).

**Out of scope (Plan 4 — another agent):** the site `/upgrade` page handling the Checkout `?addon=` return, the pricing copy/footnote, removing the old `/upgrade/addons` endpoint. This plan only opens `checkout_url` in the browser.

**Type consistency:** `AddonPurchase {ok, addons, checkoutUrl}` (T2) is the return of `UpgradeApi.purchaseAddon` and is consumed only in `_purchaseViaEndpoint`. `ApiException.reason`/`isAddonRequired` (T1) are consumed at the T3 catch sites. `_PremiumGate` loses `blocked` in T3 and no code references it afterward.
