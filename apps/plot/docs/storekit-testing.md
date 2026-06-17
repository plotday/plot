# StoreKit / In-App Purchase testing & App Store review checklist

How to verify Plot's auto-renewable subscriptions (`Core` / `Pro`) end-to-end,
and what must be true in App Store Connect before submitting. Written after a
full audit of the client (`lib/api/iap_api.dart`, `lib/command/upgrade.dart`),
the server (`workers/api/src/apple/iap.ts`, `app/upgrade.ts`, `webhook.ts`), and
the build config.

## Architecture in one paragraph

The client uses `in_app_purchase` (StoreKit 2 — deployment targets are iOS 16 /
macOS 15, both above the SK2 floor of iOS 15 / macOS 12, so StoreKit 1 never
runs). On a successful/restored purchase the client POSTs the SK2
**signed-transaction JWS** to `POST /upgrade/iap/verify`. The server verifies
Apple's signature by walking the `x5c` chain to a **pinned Apple Root CA G3**
fingerprint, then writes the entitlement. Renewals/refunds arrive out-of-band at
`POST /hook/appstore` (App Store Server Notifications V2), verified the same way.
The server **accepts both `Production` and `Sandbox`** transactions, which is why
App Review (which always purchases in Sandbox) will entitle correctly.

Product IDs (must match App Store Connect exactly):
- `day.plot.app.core_monthly` — Core, $14.99/mo
- `day.plot.app.pro_monthly` — Pro, $24.99/mo

## What each test level actually proves

| Test | Proves | Does NOT prove |
|------|--------|----------------|
| **A. Local StoreKit (Xcode + `Plot.storekit`)** | Products load, purchase sheet, restore, UI flow, graceful errors | Server verification (local receipts are signed by Xcode's test cert, **not** Apple — the real server rejects them → "couldn't confirm" toast) |
| **B. Sandbox on device / TestFlight** | The *full* path incl. `/upgrade/iap/verify`, entitlement write, renewals | App Review's human policy judgment |
| **C. App Review** | Final compliance sign-off | — |

> `flutter run` / dart-mcp / the `run-app` skill **cannot** do level A — Flutter's
> tooling launches the binary directly and never activates the `.storekit`
> config. Level A requires launching the scheme **from Xcode**. (Flutter issue
> [#79286](https://github.com/flutter/flutter/issues/79286).)

---

## A. Local StoreKit test (Xcode) — fastest, no Apple account needed

The `Plot.storekit` config is now wired into both Run schemes
(`ios/.../Runner.xcscheme` → `../Plot.storekit`; `macos/.../Runner.xcscheme` →
`../../ios/Plot.storekit`, single source of truth). It is referenced by the
scheme only and is **not** in any Copy-Bundle-Resources phase, so it never ships
in a release build.

### iOS Simulator (recommended — zero extra config)

`isAppStoreBuild` is `true` on iOS purely from `Platform.isIOS`, so no dart-define
is needed.

1. `cd apps/plot && open ios/Runner.xcworkspace` (use the **workspace**, not the
   project — Pods).
2. Pick an iOS Simulator destination, scheme **Runner**.
3. (Optional) confirm the config is selected: **Product ▸ Scheme ▸ Edit Scheme ▸
   Run ▸ Options ▸ StoreKit Configuration** should show `Plot.storekit`.
4. **Run** (⌘R). In the app, open **Settings ▸ Upgrade your plan**, pick a tier,
   confirm the StoreKit sheet.
5. Expected: the sheet completes and you'll see **"Purchase succeeded but we
   could not confirm it. Try Restore Purchases in Settings."** — this is correct
   for level A. The local receipt is not Apple-signed, so the server's
   `verifyAppleJws` rejects it. The *client* half (load → buy → finish
   transaction → restore) is what you're validating here.
6. Use **Debug ▸ StoreKit ▸ Manage Transactions** in Xcode to inspect / delete /
   refund test transactions, and to drive renewal and Ask-to-Buy edge cases.
7. To test error handling, toggle failures in `Plot.storekit` (the
   `_storeKitErrors` "Load Products" / "Purchase" / "Verification" entries) and
   re-run — the app should surface the `storeError` toast without crashing.

### macOS (one extra step)

`isAppStoreBuild` on macOS requires the `APP_STORE_BUILD=true` dart-define (the
Fastlane `build_mas` lane sets it). An Xcode Run does **not** include it by
default, so the StoreKit path stays dormant unless you inject it. Easiest:

```bash
cd apps/plot
flutter build macos --debug --dart-define=APP_STORE_BUILD=true   # bakes the define into Generated xcconfig
open macos/Runner.xcworkspace                                    # then ⌘R the Runner scheme
```

(Any later `flutter run`/`flutter build` without the define overwrites it —
re-run the build above before each macOS local test session.) iOS Simulator is
simpler; prefer it unless you specifically need to exercise the Mac App Store
build.

---

## B. Sandbox test on a real device / TestFlight — proves the server path

This is the only level that exercises `/upgrade/iap/verify` for real, because
only Apple's Sandbox issues genuinely Apple-signed JWS transactions.

**Prereqs**
- Both products exist in App Store Connect (status ≥ *Ready to Submit*) — see
  the checklist below.
- A **Sandbox Apple Account** (App Store Connect ▸ Users and Access ▸ Sandbox ▸
  Testers). Do *not* use your real Apple ID.
- The dev API the device talks to must be reachable and running the current
  `workers/api` (Sandbox JWS verify + `/hook/appstore`).

**Steps**
1. Install a real build on device: TestFlight, or `flutter run --release` /
   Xcode Run to an attached device (App Store distribution profile).
2. On the device: **Settings ▸ Developer ▸ Sandbox Apple Account** (iOS 16+) and
   sign in with the sandbox tester. (Older iOS: you'll be prompted at purchase.)
3. In Plot: **Upgrade your plan ▸ Core/Pro ▸** confirm. Sandbox subscriptions
   renew on an accelerated clock (monthly → ~5 min) so you can watch a renewal.
4. **Expected: "Subscription active."** toast — the full round trip worked.
   Verify server-side: `user_subscription` row for your user has
   `origin='app_store'`, `plan` set, `apple_original_transaction_id` populated,
   `billing_cycle_end` in the future.
5. **Restore:** delete & reinstall, then **Settings ▸ Restore purchases** →
   "Restored from App Store." and the entitlement returns.
6. **Renewal/refund:** confirm `/hook/appstore` receives `DID_RENEW` /
   `REFUND` and updates the row (watch worker logs; refund should downgrade to
   free via `revocationDate`).

If step 4 shows the "couldn't confirm" toast against a real Sandbox purchase,
that's a genuine bug (not expected like level A) — check the worker log for the
`IAP: failed to verify Apple transaction` warning and the JWS reason.

---

## C. App Store Connect — pre-submission checklist

These live in ASC / the binary's metadata and **cannot be verified from the
repo**. Reviewers reject on these far more often than on purchase plumbing.

**Subscriptions (Guideline 3.1.2)**
- [ ] `day.plot.app.core_monthly` and `day.plot.app.pro_monthly` both created as
      **auto-renewable** subscriptions, in **one subscription group**, duration
      **1 month**, prices $14.99 / $24.99, status ≥ *Ready to Submit*.
- [ ] Each has a localized **display name** + **description**; the subscription
      **group** has a localized display name.
- [ ] A **review screenshot** is attached to each subscription (Apple requires
      one per IAP).
- [ ] App's **App Privacy** (privacy nutrition labels) completed, incl. Purchases.

**Required disclosures & links (3.1.2 / 3.1.1)**
- [x] In-app paywall already shows auto-renew + length + **Terms** and **Privacy**
      links (`_kSubscriptionDisclosure` in `command/upgrade.dart`).
- [ ] ASC app metadata: **License Agreement / EULA** (Apple's standard EULA or a
      custom one) and **Privacy Policy URL** filled in — Apple checks these
      *outside* the binary too. Plot uses `plot.day/terms` + `plot.day/privacy`.
- [x] **Restore Purchases** reachable in-app (Settings ▸ App, App-Store builds).
- [x] **Manage Subscription** deep-links to `apps.apple.com/account/subscriptions`.

**3.1.1 "no external purchase" — the one residual code risk**
- [ ] **Verify the web Team page** (`ManageTeams` opens
      `${siteRoot}/team/<id>` via the external browser on App-Store builds) does
      **not** show team-plan pricing or a buy/checkout button to App-Store-origin
      users. The in-app label already strips the word "billing", but Apple looks
      at the destination. This is the most plausible rejection vector left.
- [x] On App-Store builds the web upgrade flow (`/upgrade`, Stripe checkout/portal)
      is unreachable — purchases go through StoreKit only (`UpgradeUi.isAppStoreBuild`
      gating, audited).

**Server notifications**
- [ ] App Store Connect ▸ App ▸ **App Store Server Notifications** → set both the
      **Production** and **Sandbox** URL to `https://<api-root>/hook/appstore`
      (V2). Handler verifies the signed payload via `verifyAppleJws`.

**Reviewer access**
- [ ] The paywall must be reachable by the reviewer without special account state
      (it is: Settings ▸ Upgrade your plan). Add an App Review note pointing there
      if useful.

---

## Automated coverage that exists today

- `workers/api/src/apple/iap.test.ts` — JWS chain verification, bundle/product
  guards, entitlement application. **10/10 passing.** This covers the most
  fragile, review-critical server logic.
- There are **no** Flutter-side IAP tests (the `IapService` purchase stream is
  driven by the platform plugin and is awkward to unit-test). Levels A and B
  above are the substitute; consider a thin `IapService` unit test that fakes
  `InAppPurchase.instance` if regressions appear.
