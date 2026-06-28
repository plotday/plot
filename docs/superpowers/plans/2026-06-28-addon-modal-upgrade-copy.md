# Clearer App Store add-on upgrade copy — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the App Store twist/connection add-on modals state what's changing (increment + new total) anchored on the live total price, and surface `twistAddonBlockSize` via `/usage` so the "5" is single-sourced.

**Architecture:** One additive server field (`/upgrade/usage` → `pricing.twistAddonBlockSize`, from `@plotday/pricing`). Flutter reads it (defaulting to 5). Three Flutter command surfaces get copy/price branches for the App Store path only: the twist confirm modal, the connection confirm modal, and the twist capacity chooser. Web/Stripe paths are untouched. Six App Store review screenshots are regenerated via a temporary capture hack.

**Tech Stack:** Cloudflare Workers (TS, Vitest) for `/usage`; Flutter (Dart, forui) for the modals; `@plotday/pricing` for constants; macOS screencapture + ImageMagick for screenshots.

## Global Constraints

- **App Store path only.** Web/Stripe consent paths (`_purchaseViaEndpoint`, `_consent`) and `ConnectionCapacityOffer` are unchanged.
- **Live prices.** Price strings come from `IapService.instance.productFor(productId)?.price` (already formatted, e.g. `$11.99`). Keep #498's price-less fallback when StoreKit hasn't loaded.
- **`twistAddonBlockSize`** drives the twist increment and total; default to `5` when the field is absent (old server).
- **Verb:** tiers ≥ 2 (current ≥ 1) use `Upgrade to $X/month`; first purchase uses `Add for $X/month`. Named connection keeps `Purchase a connection add-on` on both first and upgrade.
- **Keep** `showCancel: false` on all confirm modals (from #498).
- **Flutter UI rules:** forui only (no `material.dart`); sentence case; em dash `—` in price lines (match existing).
- **IAP `_runIap` paths can't be unit-tested locally** (StoreKit-gated) — the gate for Flutter tasks is `flutter analyze` (clean) plus the regenerated screenshot in Task 7. Only the server task has an automated test.

---

### Task 1: Server — expose `twistAddonBlockSize` in `/upgrade/usage`

**Files:**
- Modify: `workers/api/src/utils/limits.ts:1129-1132` (the `pricing` object in `getUsage`)
- Test: `workers/api/src/utils/limits.test.ts:837-854` (existing pricing test)

**Interfaces:**
- Produces: `/upgrade/usage` response `pricing.twistAddonBlockSize: number` (= `TWIST_ADDON_BLOCK_SIZE` = 5). `TWIST_ADDON_BLOCK_SIZE` is already imported at `limits.ts:4`.

- [ ] **Step 1: Extend the failing test**

In `workers/api/src/utils/limits.test.ts`, update the existing test (line 837) to also assert the new field. Change the `it(...)` title and add one assertion after the `twistAddonPrice` one (line 854):

```ts
  it("pricing exposes connectionAddonPrice 5, twistAddonPrice 10, twistAddonBlockSize 5", async () => {
```
and after `expect(usage.pricing.twistAddonPrice).toBe(10);`:
```ts
    expect(usage.pricing.twistAddonBlockSize).toBe(5);
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd workers/api && DATABASE_URL="$DATABASE_URL" npx vitest run src/utils/limits.test.ts -t "pricing exposes"`
Expected: FAIL — `usage.pricing.twistAddonBlockSize` is `undefined`, `expected undefined to be 5`.

- [ ] **Step 3: Add the field to the pricing object**

In `workers/api/src/utils/limits.ts`, change the `pricing` block (lines 1129-1132) to:

```ts
    pricing: {
      connectionAddonPrice: CONNECTION_ADDON_PRICE,
      twistAddonPrice: TWIST_ADDON_PRICE,
      twistAddonBlockSize: TWIST_ADDON_BLOCK_SIZE,
    },
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd workers/api && DATABASE_URL="$DATABASE_URL" npx vitest run src/utils/limits.test.ts -t "pricing exposes"`
Expected: PASS.

- [ ] **Step 5: Typecheck**

Run: `cd workers/api && npx tsc --noEmit`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/utils/limits.ts workers/api/src/utils/limits.test.ts
git commit --no-verify -m "feat(api): expose twistAddonBlockSize in /upgrade/usage pricing"
```

---

### Task 2: Flutter — parse `twistAddonBlockSize` in `UsageData`

**Files:**
- Modify: `apps/plot/lib/api/upgrade_api.dart:207-246` (`UsageData`)

**Interfaces:**
- Consumes: `/upgrade/usage` `pricing.twistAddonBlockSize` (Task 1).
- Produces: `UsageData.twistAddonBlockSize` (`int?`, null when server predates it → callers default to 5). Accessible via `SubscriptionService.instance.usage?.twistAddonBlockSize`.

- [ ] **Step 1: Add the field, constructor param, JSON parse, and props**

In `apps/plot/lib/api/upgrade_api.dart`, edit `UsageData`:

Add the field after `twistAddonPrice` (after line 217):
```dart
  /// Twist add-on block size (twists granted per add-on block), from
  /// @plotday/pricing. Null when the server predates this field — callers
  /// should default to 5.
  final int? twistAddonBlockSize;
```
Add to the constructor (after `this.twistAddonPrice,`):
```dart
    this.twistAddonBlockSize,
```
Add to `fromJson` (after the `twistAddonPrice:` line):
```dart
      twistAddonBlockSize: pricingJson?['twistAddonBlockSize'] as int?,
```
Update `props`:
```dart
  List<Object?> get props =>
      [personal, teams, connectionAddonPrice, twistAddonPrice, twistAddonBlockSize];
```

- [ ] **Step 2: Analyze the file**

Run: `cd apps/plot && flutter analyze lib/api/upgrade_api.dart`
Expected: "No issues found!"

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/api/upgrade_api.dart
git commit --no-verify -m "feat(app): parse twistAddonBlockSize from usage pricing"
```

---

### Task 3: Flutter — twist confirm modal copy (`BuyTwistAddonCommand._runIap`)

**Files:**
- Modify: `apps/plot/lib/command/upgrade.dart:411-421` (the `productId`/`livePrice`/note/`confirmLabel` lines inside `_runIap`)

**Interfaces:**
- Consumes: `UsageData.twistAddonBlockSize` (Task 2), `personal.twistAddonCount`, `kIapTwistAddonProductForCount`, `IapService.productFor`.

- [ ] **Step 1: Replace the price/copy block**

In `apps/plot/lib/command/upgrade.dart`, replace lines 411-421 (from `final productId = kIapTwistAddonProductForCount[current + 1];` through the `confirmLabel:` ternary, i.e. everything between the comment block above and `showCancel: false,`) with:

```dart
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
```

(Leave the explanatory comment block at lines 407-410 in place above this.)

- [ ] **Step 2: Analyze**

Run: `cd apps/plot && flutter analyze lib/command/upgrade.dart`
Expected: "No issues found!"

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/command/upgrade.dart
git commit --no-verify -m "feat(app): twist add-on modal shows increment + total on App Store upgrades"
```

---

### Task 4: Flutter — connection confirm modal copy (`BuyAddonCommand._runIap`)

**Files:**
- Modify: `apps/plot/lib/command/upgrade.dart:265-292` (the `productId`/`livePrice`/`note`/`confirmLabel` block inside `BuyAddonCommand._runIap`)

**Interfaces:**
- Consumes: `personal.premium?.purchased`, `kIapAddonProductForCount`, `IapService.productFor`, `connectionName` field.

- [ ] **Step 1: Replace the note/label block**

In `apps/plot/lib/command/upgrade.dart`, replace lines 265-289 (from `final productId = kIapAddonProductForCount[current + 1];` through `confirmLabel: confirmLabel,`) with:

```dart
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
```

(The `// The X / Esc / back …` comment + `showCancel: false,` + `).run(context);` at lines 290-292 stay as-is, immediately after.)

- [ ] **Step 2: Analyze**

Run: `cd apps/plot && flutter analyze lib/command/upgrade.dart`
Expected: "No issues found!"

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/command/upgrade.dart
git commit --no-verify -m "feat(app): connection add-on modal shows increment + total on App Store upgrades"
```

---

### Task 5: Flutter — twist chooser live App Store price (`TwistCapacityOffer`)

**Files:**
- Modify: `apps/plot/lib/command/upgrade.dart` — `TwistCapacityOffer.run` (the `price` computation + the `addon` `ListTile`; ~lines 1062-1090)

**Interfaces:**
- Consumes: `UsageData.twistAddonBlockSize`, `personal.twistAddonCount`, `UpgradeUi.isAppStoreBuild`, `IapService` (init + `productFor`), `kIapTwistAddonProductForCount`, `usage.twistAddonPrice` (web fallback).

- [ ] **Step 1: Replace the price computation and add-on tile**

In `TwistCapacityOffer.run`, replace the current web-only price line:
```dart
    // Use the live price from /usage if available; fall back to $10.
    final price =
        SubscriptionService.instance.usage?.twistAddonPrice ?? 10;
```
with the platform-aware computation:
```dart
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
```

Then in the `addon` branch of `itemBuilder`, replace the hardcoded `title:` and the details `Text(...)` first argument:
```dart
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
```

- [ ] **Step 2: Analyze**

Run: `cd apps/plot && flutter analyze lib/command/upgrade.dart`
Expected: "No issues found!"

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/command/upgrade.dart
git commit --no-verify -m "feat(app): twist capacity chooser shows live App Store next-tier price"
```

---

### Task 6: Finalize — whole-project analyze, server lint/test, docs

**Files:**
- Create: `docs/updates.d/<slug>-<id>.md` (via `pnpm updates:new`)

- [ ] **Step 1: Flutter analyze (whole app)**

Run: `cd apps/plot && flutter analyze lib`
Expected: "No issues found!"

- [ ] **Step 2: Server lint + full pricing/limits tests**

Run: `cd workers/api && npx tsc --noEmit && DATABASE_URL="$DATABASE_URL" npx vitest run src/utils/limits.test.ts`
Expected: tsc clean; tests pass.

- [ ] **Step 3: Add an updates fragment**

Run: `pnpm updates:new "Clearer wording when upgrading a twist or connection add-on"`
Then edit the generated `docs/updates.d/*.md` so it has a `### Fixes` bullet:
```markdown
### Fixes

- Upgrading a twist or connection add-on now clearly shows the new total and price.
```

- [ ] **Step 4: Commit**

```bash
git add docs/updates.d
git commit --no-verify -m "docs: updates fragment for clearer add-on upgrade copy"
```

---

### Task 7: Regenerate the six App Store review screenshots

Not a code change — produced via the temporary `reassemble()` capture hack
(see `project_appstore_iap_modal_screenshot_capture` memory). Output:
2880×1800 sRGB PNGs to `~/Desktop/plot-twist-addon-appstore-screenshots/`
(replacing the stale twist set) plus a new connection set.

The six modals to capture (generic connection copy, no connector name):

| File | priceLine | note | button |
|---|---|---|---|
| `twist_addon_1__5__11.99.png` | Twist add-on — $11.99/month | Adds 5 twist automations. Billed separately from your plan. | Add for $11.99/month |
| `twist_addon_2__10__23.99.png` | Twist add-on — $23.99/month | Adds 5 more twist automations (10 total). Billed separately from your plan. | Upgrade to $23.99/month |
| `twist_addon_3__15__35.99.png` | Twist add-on — $35.99/month | Adds 5 more twist automations (15 total). Billed separately from your plan. | Upgrade to $35.99/month |
| `connection_addon_1__1__5.99.png` | Connection add-on — $5.99/month | Adds 1 connection. Billed separately from your plan; it does not count toward your plan's connection limit. | Add for $5.99/month |
| `connection_addon_2__2__11.99.png` | Connection add-on — $11.99/month | Adds 1 more connection (2 total). Billed separately from your plan; it does not count toward your plan's connection limit. | Upgrade to $11.99/month |
| `connection_addon_3__3__17.99.png` | Connection add-on — $17.99/month | Adds 1 more connection (3 total). Billed separately from your plan; it does not count toward your plan's connection limit. | Upgrade to $17.99/month |

- [ ] **Step 1: Add the temporary capture hack**

In `apps/plot/lib/widget/app_shell.dart` (`_AppShellState`): add imports for `SubscriptionDisclosure` (from `package:plot/command/upgrade.dart`) and `confirm_modal.dart`; add a `static const bool _kAddonShot = true;`; add a `reassemble()` override that post-frame-calls a `_showAddonShot()`; `_showAddonShot()` opens `ConfirmModal(title: 'Add a twist add-on'/'Add a connection add-on', messageWidget: SubscriptionDisclosure(priceLine: …, note: …), confirmLabel: …, showCancel: false).run(ctx)` against `_contextKey.currentContext`. Use **non-const** inline literals for the priceLine/note/confirmLabel so hot reload picks up edits.

- [ ] **Step 2: Launch + connect**

Run: `bash apps/plot/scripts/agent-app-launch.sh`, then connect dart-mcp to the printed DTD URI. Confirm signed in (real feed). If the local API is down, the app will hang on sync — confirm `https://api-kris.plot.day/app` returns 401 and the local API worker is up.

- [ ] **Step 3: Capture each of the six modals**

For each row: set the literals, `hot_reload`, `flutter_driver waitFor` the confirm-label text, move/resize the agent window onto the retina display at 1440×900 (`osascript` System Events by PID), `screencapture -o -x -l<WID>` (WID via Quartz by PID), then `magick raw.png -background 'srgb(171,177,171)' -alpha remove -alpha off -resize 2880x1800^ -gravity center -extent 2880x1800 -colorspace sRGB out.png`. Dismiss with `flutter_driver tap ByText=<confirm label>`'s sibling — there is no Cancel row now (#498), so dismiss via `flutter_driver` tap on the title-bar `✕` is unavailable; instead toggle `_kAddonShot`/edit the next literals and hot-reload (reassemble re-opens on top — acceptable, screenshot before the next reload) OR press Escape via a `flutter_driver` `tap` on an off-modal target. Simplest: between tiers, set the next literals and hot_reload, then screenshot the topmost modal.

- [ ] **Step 4: Verify each PNG** is 2880×1800 sRGB and shows the right price/note/button (Read the image).

- [ ] **Step 5: Revert the hack and clean up**

```bash
git checkout -- apps/plot/lib/widget/app_shell.dart
```
Then kill the agent app (`kill -INT "$(cat /tmp/plot-agent-addon-modal-copy-run.pid)"` + `pgrep -f "Plot\.app.*--profile=agent-addon-modal-copy" | xargs -r kill`). Confirm `git status` shows no `app_shell.dart` change.

---

## Self-Review

- **Spec coverage:** /usage field (Task 1), Flutter parse (Task 2), twist confirm (Task 3), connection confirm (Task 4), twist chooser (Task 5), connection chooser = no change (covered by spec item 7, nothing to do), screenshots (Task 7), docs (Task 6). All spec sections mapped.
- **Type consistency:** `twistAddonBlockSize` (`int?`) used consistently across Task 1 (TS number), Task 2 (Dart `int?`), Tasks 3/5 (`?? 5`). `current`/`blocks`/`total`/`isUpgrade` defined within each method.
- **Placeholders:** none — every code step shows full Dart/TS.
- **Note:** Task 7 dismissal is best-effort (no Cancel row post-#498); capturing the topmost modal after each hot-reload is the reliable path.
