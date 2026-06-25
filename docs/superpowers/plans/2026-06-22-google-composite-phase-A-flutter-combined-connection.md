# Phase A — Flutter Combined-Connection UX (gated, contract-first) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Ship the combined-connection UX (one "Google Mail, Calendar, and Tasks" connection: product-grouped setup, post-auth product status, batch re-auth, per-product channel refine) in the Flutter app, **feature-gated** on the frozen contract (spec Part 4) so it is **inert** (falls back to today's exact per-connector flow) until the server returns `products`. Built and unit/widget-tested against **mocked** API responses — no server dependency.

**Architecture:** Add optional `products` + `productStatus` to `TwistIntegrations` (the gate). Branch the existing setup/edit/reauth surfaces (`AddSourceDetail`, `SetupSourceWidget`, `buildReauthGroup` in `lib/command/twist.dart` + `lib/widget/setup_source.dart`) on `integrations.products != null && isNotEmpty`: when set, render new product-grouped widgets; else the current widgets unchanged. Channels are product-namespaced (`<productKey>:<rawId>`); the app groups by the prefix. All existing channel/auth endpoints are reused unchanged.

**Tech Stack:** Flutter (forui only — never `flutter/material.dart`), Bloc, Equatable, the project's `Modal`/`FormModal`/`SelectModal`/`ShowForm` framework, `flutter_test`.

## Global Constraints

- **Feature gate = zero regression.** Every new path is entered ONLY when `TwistIntegrations.products` is present and non-empty. With it absent (today's servers, and the 3 legacy Google connectors until cutover) the app behaves **byte-identically** to now. New fields parse with `?? null` (mirror `apps/plot/lib/api/twist_api.dart`).
- **Contract is frozen** — implement exactly to spec Part 4 (§4.1–4.7): `products [{key,label,description,icon,scopeGroupId}]`, `productStatus [{key,enabled,reason}]` (`reason` enum + `other` fallback), channel ids `"<productKey>:<rawId>"` (title un-prefixed), Contacts as a single channel, scopes as `optionalScopes` groups (one per product), batch re-auth via existing `enabledScopeGroups`.
- **No server work here.** Tests use mocked `TwistIntegrations` JSON. The new flow cannot be end-to-end verified against prod before submission — that's expected.
- **forui + conventions** (apps/plot/AGENTS.md): forui widgets only; trailing `FSwitch` in a `32×20 FittedBox` for toggles (NO leading checkboxes); all modals via `FormModal`/`SelectModal`/`ShowForm`; sentence case for all labels; desktop cursor (no pointer on rows). `flutter analyze` clean before each commit.
- **All changes in the MAIN repo** (worktree root, branch `google-composite-twister`) under `apps/plot/`. No submodule, no DB, no `pnpm-lock.yaml`.

---

### Task 1: Contract models + product-namespace helper

**Files:**
- Modify: `apps/plot/lib/api/twist_api.dart` (add `ProductInfo`, `ProductStatus`, `ProductStatusReason`; add `products`/`productStatus` to `TwistIntegrations`)
- Create: `apps/plot/lib/util/product_channel.dart` (namespace parse/group helpers — pure)
- Test: `apps/plot/test/util/product_channel_test.dart`, `apps/plot/test/api/twist_integrations_products_test.dart`

**Interfaces:**
- Produces:
  - `class ProductInfo extends Equatable { final String key, label, description, icon, scopeGroupId; }`
  - `enum ProductStatusReason { granted, scopeMissing, locallyOff, noChannels, other }`
  - `class ProductStatus extends Equatable { final String key; final bool enabled; final ProductStatusReason reason; }`
  - `TwistIntegrations.products` → `List<ProductInfo>?`; `TwistIntegrations.productStatus` → `List<ProductStatus>?`; `bool get isComposite => products != null && products!.isNotEmpty;`
  - `productKeyOf(String channelKey) → String?` (prefix before first `:`, else null); `rawChannelId(String channelKey) → String`; `groupChannelsByProduct(List<TwistChannel>) → Map<String, List<TwistChannel>>` keyed by product key.

- [ ] **Step 1: Write the failing tests**

Create `apps/plot/test/util/product_channel_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/util/product_channel.dart';

void main() {
  test('productKeyOf returns prefix before first colon', () {
    expect(productKeyOf('calendar:primary'), 'calendar');
    expect(productKeyOf('mail:Label_42'), 'mail');
    // raw id may itself contain colons — only the first split matters
    expect(productKeyOf('calendar:user@x.com:primary'), 'calendar');
    expect(productKeyOf('nocolon'), isNull);
  });

  test('rawChannelId strips the product prefix (keeps remaining colons)', () {
    expect(rawChannelId('calendar:user@x.com:primary'), 'user@x.com:primary');
    expect(rawChannelId('nocolon'), 'nocolon');
  });
}
```

Create `apps/plot/test/api/twist_integrations_products_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/api/twist_api.dart';

void main() {
  test('TwistIntegrations: products absent => not composite (back-compat)', () {
    final ti = TwistIntegrations.fromJson({'providers': [], 'accounts': [], 'syncables': []});
    expect(ti.products, isNull);
    expect(ti.isComposite, isFalse);
  });

  test('TwistIntegrations: products present => composite + parsed', () {
    final ti = TwistIntegrations.fromJson({
      'providers': [], 'accounts': [], 'syncables': [],
      'products': [
        {'key': 'mail', 'label': 'Mail', 'description': 'Email', 'icon': 'm.svg', 'scopeGroupId': 'mail'},
      ],
      'productStatus': [
        {'key': 'mail', 'enabled': true, 'reason': 'granted'},
        {'key': 'tasks', 'enabled': false, 'reason': 'scope-missing'},
        {'key': 'x', 'enabled': false, 'reason': 'totally-new-reason'},
      ],
    });
    expect(ti.isComposite, isTrue);
    expect(ti.products!.single.key, 'mail');
    expect(ti.productStatus!.firstWhere((s) => s.key == 'mail').enabled, isTrue);
    expect(ti.productStatus!.firstWhere((s) => s.key == 'tasks').reason, ProductStatusReason.scopeMissing);
    // unknown reason falls back to .other (forward-compat)
    expect(ti.productStatus!.firstWhere((s) => s.key == 'x').reason, ProductStatusReason.other);
  });
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd apps/plot && flutter test test/util/product_channel_test.dart test/api/twist_integrations_products_test.dart`
Expected: FAIL — `product_channel.dart` missing; `products`/`isComposite` undefined.

- [ ] **Step 3: Implement the helper**

Create `apps/plot/lib/util/product_channel.dart`:

```dart
/// Channels on a composite connection are namespaced "<productKey>:<rawId>".
/// These helpers parse/group by that prefix; raw ids may themselves contain ':'.
String? productKeyOf(String channelKey) {
  final i = channelKey.indexOf(':');
  return i <= 0 ? null : channelKey.substring(0, i);
}

String rawChannelId(String channelKey) {
  final i = channelKey.indexOf(':');
  return i < 0 ? channelKey : channelKey.substring(i + 1);
}
```

(`groupChannelsByProduct` lives next to the channel rendering — it needs `TwistChannel`; add it here only if you keep `TwistChannel` import-free. Simpler: add the grouping inline in Task 3 using `productKeyOf(channel.id)`. Drop the unused `groupChannelsByProduct` from the interface if not needed — YAGNI.)

- [ ] **Step 4: Implement the models + TwistIntegrations fields**

In `apps/plot/lib/api/twist_api.dart`, add the models (near `OptionalScopeGroup`):

```dart
/// One product within a composite connection (spec Part 4.2).
class ProductInfo extends Equatable {
  final String key;
  final String label;
  final String description;
  final String icon;
  final String scopeGroupId;
  const ProductInfo({required this.key, required this.label, required this.description,
      required this.icon, required this.scopeGroupId});
  factory ProductInfo.fromJson(Map<String, dynamic> json) => ProductInfo(
        key: json['key'] as String,
        label: json['label'] as String,
        description: json['description'] as String? ?? '',
        icon: json['icon'] as String? ?? '',
        scopeGroupId: json['scopeGroupId'] as String? ?? json['key'] as String,
      );
  @override
  List<Object?> get props => [key, label, description, icon, scopeGroupId];
}

enum ProductStatusReason {
  granted, scopeMissing, locallyOff, noChannels, other;
  static ProductStatusReason parse(String? s) => switch (s) {
        'granted' => granted,
        'scope-missing' => scopeMissing,
        'locally-off' => locallyOff,
        'no-channels' => noChannels,
        _ => other,
      };
}

class ProductStatus extends Equatable {
  final String key;
  final bool enabled;
  final ProductStatusReason reason;
  const ProductStatus({required this.key, required this.enabled, required this.reason});
  factory ProductStatus.fromJson(Map<String, dynamic> json) => ProductStatus(
        key: json['key'] as String,
        enabled: json['enabled'] as bool? ?? false,
        reason: ProductStatusReason.parse(json['reason'] as String?),
      );
  @override
  List<Object?> get props => [key, enabled, reason];
}
```

Add fields + parsing to `TwistIntegrations` (mirroring the existing `?? null` idiom): a `final List<ProductInfo>? products;` and `final List<ProductStatus>? productStatus;` in the constructor and `fromJson` (`(json['products'] as List<dynamic>?)?.map((p) => ProductInfo.fromJson(p as Map<String, dynamic>)).toList()`, same for productStatus), and:

```dart
bool get isComposite => products != null && products!.isNotEmpty;
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd apps/plot && flutter test test/util/product_channel_test.dart test/api/twist_integrations_products_test.dart`
Expected: PASS.

- [ ] **Step 6: Analyze + commit**

```bash
cd apps/plot && flutter analyze lib/api/twist_api.dart lib/util/product_channel.dart
cd "$(git rev-parse --show-toplevel)"
git add apps/plot/lib/api/twist_api.dart apps/plot/lib/util/product_channel.dart \
  apps/plot/test/util/product_channel_test.dart apps/plot/test/api/twist_integrations_products_test.dart
git commit -m "feat(app): TwistIntegrations.products/productStatus + product-namespace helpers (gated, additive)"
```

---

### Task 2: Pre-auth product setup screen (gated)

**Files:**
- Create: `apps/plot/lib/widget/product_setup.dart` (`ProductSetupWidget` — informational product rows + one "Continue with Google")
- Modify: `apps/plot/lib/command/twist.dart` (`AddSourceDetail._buildForm`: branch on `integrations.isComposite`)
- Test: `apps/plot/test/widget/product_setup_test.dart`

**Interfaces:**
- Consumes: `TwistIntegrations` (Task 1), `AuthButton.connect` (`enabledScopeGroups`, `provider`, `scopes`, `twistInstanceId`, `onSuccess`), the provider's `optionalScopes`.
- Produces: `ProductSetupWidget({ required TwistProvider provider, required List<ProductInfo> products, required String twistInstanceId, required Future<void> Function() onSuccess })` — renders one informational row per product (icon + label + description, **no toggles**), then `AuthButton.connect(enabledScopeGroups: <all product scopeGroupIds>, ...)`.

- [ ] **Step 1: Write the failing widget test** — pump `ProductSetupWidget` with 3 mocked `ProductInfo`s; assert all three labels render, no `FSwitch`/checkbox is present (informational only), and a single primary action ("Continue with Google") is shown. (Mock `AuthButton` interaction by asserting the button exists; don't hit the network.) Run → FAIL (widget missing).

- [ ] **Step 2: Implement `ProductSetupWidget`** — a `StatelessWidget` (forui): a `Column` of product rows (each: `icon` via the project's network/iconify image widget + `label` + `description` text, sentence case), then the existing `AuthButton.connect` with `enabledScopeGroups` = `products.map((p) => p.scopeGroupId).toList()` and `scopes` = `provider.scopes`. Reuse the `_AuthWithScopeToggles` button styling but WITHOUT the per-group `FSwitch` toggles (products are informational; choice happens on Google's screen per spec §1.2). Copy: header "Plot can sync these from your Google account. You choose what to allow on Google's next screen."

- [ ] **Step 3: Branch in `AddSourceDetail._buildForm`** — at the OAuth-provider render (twist.dart ~2266–2298 and the rebuild ~2069–2089), wrap:

```dart
// integrations resolved for the draft
if (integrations.isComposite) {
  return FormInfo(key: 'product_setup', divider: false, builder: (ctx) => Padding(
    padding: EdgeInsets.only(left: spacing.xl, right: spacing.xl, bottom: spacing.lg),
    child: ProductSetupWidget(
      provider: provider,                 // the single composite provider
      products: integrations.products!,
      twistInstanceId: draftId,
      onSuccess: () async => _connectedAfterOAuth(ctx, draftId, twist.name, teams, fallbackOwner: initialOwner),
    ),
  ));
}
// else: existing _AuthWithScopeToggles block, unchanged.
```

`onSuccess` is identical to today (`_connectedAfterOAuth`), so the post-auth handoff to `EditSource` is unchanged.

- [ ] **Step 4: Run widget test → PASS. Step 5: `flutter analyze` (changed files) → clean. Step 6: commit** `feat(app): composite-connection pre-auth product setup screen (gated)`.

---

### Task 3: Post-auth status + per-product channel grouping & refine (gated)

**Files:**
- Modify: `apps/plot/lib/widget/setup_source.dart` (`SetupSourceWidget`: when composite, render ENABLED/NOT-ENABLED product sections from `productStatus` + group channels by product; trailing toggles; per-product refine)
- Test: `apps/plot/test/widget/setup_source_composite_test.dart`

**Interfaces:**
- Consumes: `TwistIntegrations.products`/`productStatus` (Task 1), `productKeyOf` (Task 1), the existing `_localSelectedChannels` (`"providerKey:channelId"` keys), `_ChannelRow` trailing-toggle, `applyChannelsBatch` via `SaveSource` (unchanged).
- Produces: composite rendering inside `_SetupSourceWidgetState.build` — gated on `widget.initialData.isComposite`; the non-composite path is untouched.

- [ ] **Step 1: Write failing widget tests** (mocked composite `TwistIntegrations`): (a) products with `enabled:true` render under an "Enabled" section showing their channel summary; products with `enabled:false` render under "Not enabled"; (b) channels group under their product (parsed via `productKeyOf(channel.id)`); (c) toggling an enabled product's channel updates `_localSelectedChannels` (reuse the existing `onChanged` assertion pattern); (d) NON-composite data still renders the existing flat flow (regression guard). Run → FAIL.

- [ ] **Step 2: Implement the composite branch** in `_SetupSourceWidgetState.build` (~594–720): when `widget.initialData?.isComposite == true`, build sections from `productStatus`:
  - **Enabled** products: for each, a header row (`product.label` + summary "N {channelNoun.plural}") with a trailing `FSwitch` (on), and `›`-style expansion into that product's channels (`channelsByProduct[product.key]`) reusing `_buildChannelTree`/`_ChannelRow` unchanged. Owned-vs-shared default already flows from each channel's `enabledByDefault` (server-set) + the existing seeding logic.
  - **Not enabled** products (status `scope-missing`/`locally-off`/`no-channels`): a row with a trailing `FSwitch` (off). Toggling it ON **stages re-auth** (Task 4 wires the action) — for this task, record staged keys in a `Set<String> _stagedProducts` and surface them; the Continue-with-Google wiring is Task 4.
  Group channels with `productKeyOf(channel.id)`; channels whose product key isn't in `products` fall back to the existing flat rendering (defensive). The `_localSelectedChannels` key format is unchanged.
- [ ] **Step 3: PASS tests. Step 4: analyze clean (incl. the non-composite regression test). Step 5: commit** `feat(app): composite post-auth product status + per-product channel grouping (gated)`.

---

### Task 4: Batch re-auth for staged products (gated)

**Files:**
- Modify: `apps/plot/lib/command/twist.dart` (`buildReauthGroup` + `EditSource` save path: when composite, a single Continue-with-Google requesting the union of staged + granted scope groups)
- Modify: `apps/plot/lib/widget/setup_source.dart` (surface staged not-enabled products → the reauth CTA; suppress plain Save while staged)
- Test: `apps/plot/test/widget/composite_reauth_test.dart`

**Interfaces:**
- Consumes: `_stagedProducts` (Task 3), `products[].scopeGroupId`, currently-granted groups (derive from enabled `productStatus` → their scopeGroupIds), `AuthButton.connect(enabledScopeGroups: ...)`.
- Produces: when ≥1 product is staged-on, the form shows "⚠ Please reconnect to enable …" + a single `AuthButton.connect` with `enabledScopeGroups` = `{granted product scopeGroupIds} ∪ {staged product scopeGroupIds}`, and the plain Save button is suppressed (per spec §1.4). `onSuccess` = `TwistConnection.pull()` + `FormScope.refresh()` (re-fetch → reconcile from new `productStatus`).

- [ ] **Step 1: failing test** — composite EditSource with one not-enabled product staged ON: assert the Save button is replaced by a single "Continue with Google", and the auth request would carry the staged product's scopeGroupId unioned with the granted ones. Also: composite needing-reauth (a `productStatus` reason that maps to disconnected) renders the same single CTA, not the per-provider loop. Run → FAIL.
- [ ] **Step 2: implement** — in `buildReauthGroup`/`buildAllGroups`, when `integrations.isComposite`, replace the per-provider `_AuthWithScopeToggles` loop with one composite reauth widget that computes the scope-group union and renders one `AuthButton.connect`. In `SaveSource`/the form's primary action, when `_stagedProducts.isNotEmpty`, suppress plain Save and require the Continue-with-Google path. Reconcile on return via re-fetch.
- [ ] **Step 3: PASS. Step 4: analyze clean. Step 5: commit** `feat(app): composite batch re-auth (stage products → one Continue with Google, gated)`.

---

## Self-Review

**Spec coverage (Phase A = spec Part 1 UX + Part 4 contract, client side):**
- §1.1 search aliases → server-set `filterText` on the catalog entry; the app's existing `_AvailableSource.filterText` search already matches (no client change needed) — note in Task 2 context, no task required.
- §1.2 pre-auth no-toggles + one Continue-with-Google → Task 2. ✓
- §1.3 post-auth ENABLED/NOT-ENABLED + trailing toggles → Task 3. ✓
- §1.4 batch re-auth → Task 4. ✓
- §1.5 per-product refine (channels, owned-on/shared-off) → Task 3 (defaults flow from server `enabledByDefault`). ✓
- §1.6 agenda gating → NO client change (server dynamic link types; predicate unchanged) — explicitly out of scope. ✓
- Part 4 gate + models + namespacing → Task 1; reused endpoints unchanged. ✓
- Feature-gate / zero-regression → every task gated on `isComposite`, with a non-composite regression test in Task 3.

**Placeholder scan:** Tasks 2–4 give exact edit points (file + line ranges) and the new widget contracts + key code; the precise forui widget body for the rows follows the cited existing patterns (`_AuthWithScopeToggles` 3798–3929, `_ChannelRow` 1060–1081) rather than re-deriving styling — that's reuse, not a placeholder. No "TODO"/"handle errors".

**Type/name consistency:** `ProductInfo`/`ProductStatus`/`ProductStatusReason`, `isComposite`, `productKeyOf`/`rawChannelId`, `scopeGroupId`↔`OptionalScopeGroup.id`, channel key format `"providerKey:channelId"` (unchanged) are used consistently across tasks and match the frozen contract (spec §4.2–4.4).

**Risk:** the UI can't be e2e-verified against prod before submission (known, accepted). Mitigation: mocked-`TwistIntegrations` widget tests per task + the gate keeps it dormant until the server ships. Before the App Store build, recommend a manual run-app pass driving a **mocked composite integrations response** to eyeball the screens.
