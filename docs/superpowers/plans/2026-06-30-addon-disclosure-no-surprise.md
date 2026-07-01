# Connection add-on no-surprise disclosure — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure a user is never surprised that a premium connector (LinkedIn/Instagram/WhatsApp) requires a paid connection add-on, by showing a passive cost notice before auth and above "Add connection," and charging only at the "Add connection" step via the existing payment modal.

**Architecture:** Replace the conditional *blocking* pre-auth premium gate with a *passive* inline notice shown at two points (before the auth CTA, and above the "Add connection" button). The actual charge/consent stays at the single "Add connection" moment and reuses the existing reactive `addon_required` machinery (`SaveSource._attempt`), which already retries with consent in one flow on web. Flutter-only; no server changes.

**Tech Stack:** Flutter/Dart, forui widgets, Bloc-free command layer (`apps/plot/lib/command/twist.dart`, `upgrade.dart`), `flutter_test`.

## Global Constraints

- **Scope = premium connectors only** (`twist.premium == true`: LinkedIn/Instagram/WhatsApp). Regular-connector-beyond-pool behavior is unchanged.
- **Prices:** web/DMG/Android → `usage.connectionAddonPrice ?? 5` rendered `"$<n>/month"`. **App Store → live StoreKit price** for the next tier via `IapService.instance.productFor(kIapAddonProductForCount[current + 1])?.price`; **never hardcode $5 on App Store.** When the StoreKit price is unavailable, omit the figure (price-less phrasing) — never substitute $5.
- **No blocking modal before auth.** The pre-auth disclosure is passive; "Continue with LinkedIn" must still work with no extra tap.
- **Money-safety unchanged:** the server still charges only on `consentAddon === true` at enable. No server edits.
- forui/Dart house style: import only `flutter/widgets.dart` + `forui/forui.dart` (never `flutter/material.dart`); sentence-case UI text; use `context.theme.typography` / `context.theme.plotColors.muted`.
- Verify with `flutter analyze` (run `flutter pub run build_runner build` first in a worktree so Drift codegen doesn't emit false errors). Do **not** run `dart format` on `twist.dart` (large-file churn).

---

### Task 1: Pure add-on notice copy helper + passive notice widget

Adds the single source of truth for *whether* and *what* the notice says, as a pure `@visibleForTesting` function (unit-testable, no widgets), plus the stateless widget that renders it.

**Files:**
- Modify: `apps/plot/lib/command/twist.dart` (add near the other add-on helpers, ~after `_evaluatePremium` at line 1089)
- Test: `apps/plot/test/command/addon_notice_test.dart` (create)

**Interfaces:**
- Produces:
  - `@visibleForTesting String? addonNoticeText({required bool isPremium, required PremiumUsage? premium, required String connectionName, required String? priceLabel})` — returns the notice sentence, or `null` when no notice should show (not premium).
  - `class _AddonNotice extends StatelessWidget` with `const _AddonNotice({required String text})` — muted info row (icon + text).
  - `String? _connectionAddonPriceLabel(UsageData usage)` — platform-aware price string (`"$5/month"` web; live StoreKit `"$5.99/month"` App Store; `null` when unknown).

- [ ] **Step 1: Write the failing test**

Create `apps/plot/test/command/addon_notice_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/command/twist.dart' show addonNoticeText;

void main() {
  group('addonNoticeText', () {
    test('returns null for a non-premium connector', () {
      expect(
        addonNoticeText(
          isPremium: false,
          premium: const PremiumUsage(allowed: true),
          connectionName: 'Gmail',
          priceLabel: r'$5/month',
        ),
        isNull,
      );
    });

    test('charge copy names the connection and the price', () {
      final text = addonNoticeText(
        isPremium: true,
        premium: const PremiumUsage(allowed: true, count: 0, purchased: 0),
        connectionName: 'LinkedIn',
        priceLabel: r'$5/month',
      );
      expect(text, contains('LinkedIn requires a connection add-on'));
      expect(text, contains(r'$5/month'));
      expect(text, contains("won't be charged until you add"));
    });

    test('omits the figure when the price is unknown (App Store not loaded)', () {
      final text = addonNoticeText(
        isPremium: true,
        premium: const PremiumUsage(allowed: true, count: 0, purchased: 0),
        connectionName: 'LinkedIn',
        priceLabel: null,
      );
      expect(text, contains('requires a connection add-on'));
      expect(text, isNot(contains(r'$')));
    });

    test('spare-credit copy: no additional charge, no price', () {
      final text = addonNoticeText(
        isPremium: true,
        premium: const PremiumUsage(allowed: true, count: 1, purchased: 2),
        connectionName: 'LinkedIn',
        priceLabel: r'$5/month',
      );
      expect(text, contains('uses one of your connection add-ons'));
      expect(text, contains('no additional charge'));
      expect(text, isNot(contains(r'$5/month')));
    });

    test('null premium payload (older server) treated as a charge', () {
      final text = addonNoticeText(
        isPremium: true,
        premium: null,
        connectionName: 'LinkedIn',
        priceLabel: r'$5/month',
      );
      expect(text, contains('requires a connection add-on'));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/plot && flutter test test/command/addon_notice_test.dart`
Expected: FAIL — `addonNoticeText` is not defined / not exported.

- [ ] **Step 3: Add the pure helper, the widget, and the price-label helper**

In `apps/plot/lib/command/twist.dart`, immediately after `_evaluatePremium` (ends ~line 1101), add:

```dart
/// Copy for the passive connection-add-on notice, or null when no notice
/// applies. Pure so it can be unit-tested without a widget pump; the platform
/// price is resolved by the caller via [_connectionAddonPriceLabel] and passed
/// in as [priceLabel].
///
/// - Not premium → null (regular connectors handle their own limit UI).
/// - Spare credit on hand (purchased > count) → "uses one of your add-ons"
///   (enabling consumes an already-paid credit; no new charge).
/// - Otherwise (needs a new add-on, or an older server sent no payload) →
///   the charge notice, naming the connection and the price when known.
@visibleForTesting
String? addonNoticeText({
  required bool isPremium,
  required PremiumUsage? premium,
  required String connectionName,
  required String? priceLabel,
}) {
  if (!isPremium) return null;
  final hasSpareCredit = premium != null && premium.purchased > premium.count;
  if (hasSpareCredit) {
    return '$connectionName uses one of your connection add-ons — '
        'no additional charge.';
  }
  final priceSuffix = priceLabel == null ? '' : ' — $priceLabel';
  return '$connectionName requires a connection add-on$priceSuffix, billed '
      "separately from your plan. You won't be charged until you add the "
      'connection.';
}

/// Platform-aware price string for the connection add-on, or null when the
/// price can't be resolved yet (App Store products not loaded). Web/DMG/Android
/// uses the Stripe price from /usage; App Store uses the live StoreKit tier
/// price (never the $5 web price).
String? _connectionAddonPriceLabel(UsageData usage) {
  if (UpgradeUi.isAppStoreBuild) {
    final current = usage.personal.premium?.purchased ?? 0;
    final productId = kIapAddonProductForCount[current + 1];
    final price = productId == null
        ? null
        : IapService.instance.productFor(productId)?.price;
    return price == null ? null : '$price/month';
  }
  final price = usage.connectionAddonPrice ?? 5;
  return '\$$price/month';
}

/// Passive, non-blocking inline notice that a connection needs a paid add-on.
/// Rendered before the auth CTA and above the "Add connection" button. Purely
/// informational — it never blocks the flow.
class _AddonNotice extends StatelessWidget {
  const _AddonNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final muted = theme.plotColors.muted;
    return Padding(
      padding: EdgeInsets.only(bottom: theme.spacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(FontAwesomeIcons.circleInfo, size: 14, color: muted),
          SizedBox(width: theme.spacing.sm),
          Expanded(
            child: Text(
              text,
              style: theme.typography.sm.copyWith(color: muted, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
```

Add `IapService` and `kIapAddonProductForCount` to the imports if not already resolvable — `iap_api.dart` is already imported via `package:plot/api/upgrade_api.dart`? Verify: add `import 'package:plot/api/iap_api.dart' show IapService, kIapAddonProductForCount;` near the other `package:plot/api/...` imports (top of file ~line 20) if `flutter analyze` reports them undefined. `UpgradeUi` and `PremiumUsage` come from the already-imported `package:plot/api/upgrade_api.dart`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/plot && flutter test test/command/addon_notice_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Analyze**

Run: `cd apps/plot && flutter analyze lib/command/twist.dart test/command/addon_notice_test.dart`
Expected: No issues. (`_AddonNotice` / `_connectionAddonPriceLabel` will report as unused until Tasks 2–3 wire them — acceptable at this checkpoint; if the analyzer errors on unused private elements, proceed to Task 2 before treating it as a failure. `addonNoticeText` is used by the test.)

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/command/twist.dart apps/plot/test/command/addon_notice_test.dart
git commit -m "feat(app): add passive connection add-on notice helper + widget"
```

---

### Task 2: Show the notice before auth; remove the blocking pre-auth premium gate

Deletes the `upgrade_premium_<provider>` button-swap (the `teams.isEmpty` branch that only fired for personal-only users) in **both** the initial-render and refresh provider-mapping blocks, and renders the passive notice above the auth CTA instead. This is what unifies personal and team users and fixes the reported surprise.

**Files:**
- Modify: `apps/plot/lib/command/twist.dart:2578-2599` (initial render) and `:2314-2338` (refresh twin)
- Modify (auth FormInfo builders): `apps/plot/lib/command/twist.dart:2651-2688` (initial) and `:2390-2427` (refresh) — prepend the notice inside the auth item's builder

**Interfaces:**
- Consumes: `addonNoticeText(...)`, `_connectionAddonPriceLabel(usage)`, `_AddonNotice` (Task 1).

- [ ] **Step 1: Remove the premium button-swap (initial block)**

In the initial provider map (~line 2581–2599), delete the premium gate block entirely:

```dart
                // DELETE these lines (2583-2599):
                // Premium gate (see twin block above for the variant flow).
                final premiumGate = teams.isEmpty
                    ? _premiumGateCommand(...)
                    : null;
                if (premiumGate != null) {
                  return FormButton(
                    key: 'upgrade_premium_${provider.provider.name}',
                    isPrimary: true,
                    buildCommand: (_) => premiumGate,
                  );
                }
```

Leave the subsequent regular-connector `initialAtLimit` block (`if (initialAtLimit && !_hasAddonConsent(draftId))`) untouched — regular connectors are out of scope.

- [ ] **Step 2: Render the notice inside the auth FormInfo builder (initial block)**

In the `auth_${provider.provider.name}` `FormInfo` (~line 2651), change the builder's child from the bare `_AuthWithScopeToggles(...)` inside `Padding` to a `Column` that prepends the notice. Compute the notice text once above the `return`:

```dart
                return FormInfo(
                  key: 'auth_${provider.provider.name}',
                  divider: false,
                  builder: (formContext) {
                    final noticeText = addonNoticeText(
                      isPremium: twist.premium,
                      premium: usage.personal.premium,
                      connectionName: twist.name,
                      priceLabel: _connectionAddonPriceLabel(usage),
                    );
                    return Padding(
                      padding: EdgeInsets.only(
                        left: formContext.theme.spacing.xl,
                        right: formContext.theme.spacing.xl,
                        bottom: formContext.theme.spacing.lg,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (noticeText != null)
                            _AddonNotice(text: noticeText),
                          _AuthWithScopeToggles(
                            provider: provider,
                            twistInstanceId: draftId,
                            initialEnabledGroups:
                                scopeGroupSelections[provider.provider.name],
                            onScopeGroupsChanged: (groups) {
                              scopeGroupSelections[provider.provider.name] =
                                  groups;
                            },
                            keepSpinnerOnSuccess: true,
                            onSuccess: () async {
                              await _connectedAfterOAuth(
                                formContext,
                                draftId,
                                twist.name,
                                teams,
                                fallbackOwner: initialOwner,
                              );
                            },
                            // ...preserve all remaining named args exactly as
                            // they exist today (do not drop any).
                          ),
                        ],
                      ),
                    );
                  },
                );
```

> Preserve every existing argument to `_AuthWithScopeToggles` verbatim — only wrap it in the `Column` and prepend the notice. Read the current call (lines ~2664-2688) and keep all args.

- [ ] **Step 3: Repeat Steps 1–2 for the refresh twin block**

Apply the identical two changes to the refresh block: delete the `upgrade_premium_*` swap at ~line 2323-2338, and wrap the `auth_${provider}` builder's `_AuthWithScopeToggles` (~line 2390-2427) in the same notice `Column`. In this block the premium/usage source is the same `usage` variable and `refreshed`/`refreshedDefault` are the local names — use `twist.premium`, `usage.personal.premium`, `twist.name`, and `_connectionAddonPriceLabel(usage)` exactly as in Step 2, and keep the existing `_AuthWithScopeToggles` args (which reference `refreshed`/`refreshedDefault`).

- [ ] **Step 4: Analyze**

Run: `cd apps/plot && flutter analyze lib/command/twist.dart`
Expected: No new issues. If `_premiumGateCommand` is now reported unused, that is expected — it is removed in Task 4.

- [ ] **Step 5: Manual smoke (optional but recommended)**

Via the `run-app` skill, open Add connection → LinkedIn as a user who belongs to a team. Confirm: the info notice appears above "Continue with LinkedIn"; tapping "Continue with LinkedIn" proceeds to auth with no blocking modal.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/command/twist.dart
git commit -m "feat(app): show passive add-on notice before auth for all users"
```

---

### Task 3: Notice above "Add connection" + single-tap charge via reactive path

Adds the notice above the "Add connection" button in the setup form, and removes the premium pre-check on that button so premium connectors flow into the existing reactive `addon_required` path — which shows the payment modal and, on web, retries the enable with consent in a single tap.

**Files:**
- Modify: `apps/plot/lib/command/twist.dart:1540-1602` (the `StaticFormGroup` holding the "save"/"Add connection" button) — prepend the notice
- Modify: `apps/plot/lib/command/twist.dart:1633-1658` (the save button's `buildCommand`) — remove the premium `_premiumGateCommand` pre-check

**Interfaces:**
- Consumes: `addonNoticeText(...)`, `_connectionAddonPriceLabel(usage)`, `_AddonNotice` (Task 1); the existing `SaveSource` reactive `_offerAddonConsent`/`_attempt(consentAddon: true)` path (`twist.dart:4659-4671`).

- [ ] **Step 1: Prepend the notice to the save-button group**

In `buildActiveGroup` where the `StaticFormGroup(items: [ ... ])` is built (~line 1540), insert a notice item as the **first** entry of `items`, shown only for a newly-activated premium connection. Compute it just before the `return`:

```dart
      final owner = initialTeamId ?? 'personal';
      final saveNoticeText = (isNewlyActivated && integrations.premium)
          ? addonNoticeText(
              isPremium: true,
              premium: owner == 'personal'
                  ? usage.personal.premium
                  : usage.teams
                      .firstWhereOrNull((t) => t.id == owner)
                      ?.premium,
              connectionName: name,
              priceLabel: _connectionAddonPriceLabel(usage),
            )
          : null;

      return [
        // ...existing StaticFormGroup(s) above the button group unchanged...
        StaticFormGroup(
          items: [
            if (saveNoticeText != null)
              FormInfo(
                key: 'addon_notice',
                divider: false,
                builder: (formContext) => Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: formContext.theme.spacing.xl,
                  ),
                  child: _AddonNotice(text: saveNoticeText),
                ),
              ),
            // ...existing composite_reauth FormInfo + FormButton 'save' +
            //    archive button, all unchanged...
          ],
        ),
      ];
```

> Match the exact surrounding structure at line 1540 — only add the leading `if (saveNoticeText != null) FormInfo(...)` item and the `saveNoticeText` computation. `usage`, `name`, `isNewlyActivated`, `initialTeamId`, and `integrations` are already in scope here. `firstWhereOrNull` is available (`package:collection` is imported).

- [ ] **Step 2: Remove the premium pre-check on the save button**

In the save button's `buildCommand` (~line 1633-1658), delete the `_premiumGateCommand` call and its early return so premium connectors fall through to `SaveSource` (which hits the server, gets `addon_required`, and offers+retries in one flow). Keep the regular at-limit `_ConsentGate` branch:

```dart
                if (isNewlyActivated || owner != initialTeamId) {
                  final live = _liveUsage(usage);
                  // DELETE these lines:
                  // final premiumGate = _premiumGateCommand(
                  //   usage: live,
                  //   owner: owner,
                  //   isPremium: integrations.premium,
                  //   draftId: twistInstanceId,
                  //   connectionName: name,
                  // );
                  // if (premiumGate != null) return premiumGate;
                  final team = live.teams.firstWhereOrNull((t) => t.id == owner);
                  final atLimit = team != null
                      ? team.connections.isAtLimit
                      : live.personal.connections.isAtLimit;
                  // Regular connection beyond the pool: offer add-on/Pro and
                  // capture consent before saving (premium relies on the
                  // reactive addon_required path in SaveSource instead).
                  if (atLimit && !_hasAddonConsent(twistInstanceId)) {
                    return _ConsentGate(
                      draftId: twistInstanceId,
                      isPremium: false,
                      teamId: owner == 'personal' ? null : owner,
                    );
                  }
                }
```

- [ ] **Step 3: Analyze**

Run: `cd apps/plot && flutter analyze lib/command/twist.dart`
Expected: No new issues (aside from a now-unused `_premiumGateCommand`, removed in Task 4).

- [ ] **Step 4: Manual verification (recommended — this is the reported bug)**

Via `run-app`, as a **team member** on web/DMG, add LinkedIn: authenticate → on the setup modal confirm the notice sits above "Add connection" → tap "Add connection" → the $5/mo payment modal appears → confirm → the connection is added in one step (no second "Add connection" tap). On an App Store build, confirm the notice/modal show the **live StoreKit price**, not $5.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/command/twist.dart
git commit -m "feat(app): notice above Add connection; single-tap add-on charge on enable"
```

---

### Task 4: Remove dead code, whole-file analyze, and user-facing note

Cleans up the now-unused blocking-gate helper and confirms the whole app analyzes clean; adds a plain-language update fragment.

**Files:**
- Modify: `apps/plot/lib/command/twist.dart` (delete `_premiumGateCommand`; delete `_PremiumGate`/`_evaluatePremium` only if now unused)
- Create: `docs/updates.d/<slug>-<id>.md` (via `pnpm updates:new`)

- [ ] **Step 1: Find remaining references to the removed helpers**

Run:
```bash
cd apps/plot && grep -n "_premiumGateCommand\|_evaluatePremium\|_PremiumGate" lib/command/twist.dart
```
Expected after Tasks 2–3: `_premiumGateCommand` has **no call sites** (only its definition). Note whether `_evaluatePremium` / `_PremiumGate` still have callers.

- [ ] **Step 2: Delete `_premiumGateCommand` (and `_evaluatePremium`/`_PremiumGate` if unused)**

Remove the `_premiumGateCommand` function definition. If Step 1 shows `_evaluatePremium` and the `_PremiumGate` enum now have no other callers, delete them too. If either is still referenced, leave it. (Do not delete `_ConsentGate` — it is still used by the regular at-limit paths.)

- [ ] **Step 3: Whole-project analyze**

Run: `cd apps/plot && flutter pub run build_runner build --delete-conflicting-outputs && flutter analyze`
Expected: No issues (no "unused element" warnings for the removed helpers).

- [ ] **Step 4: Run the focused test again**

Run: `cd apps/plot && flutter test test/command/addon_notice_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Add a user-facing update fragment**

Run: `pnpm updates:new "You now see when a connection needs a paid add-on before you connect it"` and place the bullet under `### Fixes` (or a `### Connections` section if one exists), e.g.:

```markdown
### Fixes

- Connections that need a paid add-on (like LinkedIn) now tell you the cost before you sign in and again before you add them — no more surprises at the last step.
```

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/command/twist.dart docs/updates.d/
git commit -m "chore(app): remove dead premium gate; note add-on disclosure in updates"
```

---

## Self-Review

**Spec coverage**
- Passive notice before auth → Task 2. ✅
- Passive notice above "Add connection" → Task 3 Step 1. ✅
- Remove blocking `teams.isEmpty` pre-auth gate (unify personal + team) → Task 2 Steps 1/3. ✅
- Charge only at "Add connection" via existing payment modal, single continuous flow (web) → Task 3 Step 2 (reactive path). ✅
- Live StoreKit price on App Store, `connectionAddonPrice` on web, price-less fallback → Task 1 `_connectionAddonPriceLabel` + `addonNoticeText`; Global Constraints. ✅
- Spare-credit honest copy → Task 1 `addonNoticeText` + test. ✅
- Flutter-only, no server changes → all tasks; Global Constraints. ✅
- Out of scope (picker badge, regular connectors, extra-channel, move-to-team) → untouched by all tasks. ✅

**Placeholder scan:** No TBD/TODO; all code blocks are concrete; test code is complete.

**Type consistency:** `addonNoticeText` signature identical across Task 1 (def/test) and Tasks 2–3 (calls): `{isPremium, premium: PremiumUsage?, connectionName, priceLabel: String?}`. `_connectionAddonPriceLabel(UsageData)` and `_AddonNotice({text})` consistent across tasks. `PremiumUsage` fields (`allowed`, `count`, `purchased`) match `upgrade_api.dart:83-92`.

**Note on the single-tap decision:** web achieves single-tap via the existing reactive retry; App Store remains two-tap (StoreKit purchase then add) — inherent to Apple's prepaid model and accepted in the spec. If review prefers a single pre-check payment step instead of the reactive path, revisit Task 3 Step 2.
