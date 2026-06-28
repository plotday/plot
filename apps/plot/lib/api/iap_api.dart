import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show kIsWeb, ValueNotifier, visibleForTesting;
import 'package:flutter/widgets.dart' show FocusManager;
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart'
    show AppStorePurchaseDetails;
import 'package:in_app_purchase_storekit/store_kit_wrappers.dart'
    show SKPaymentTransactionStateWrapper;

import 'package:plot/api/api.dart' as api;
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/logging.dart';

/// Product identifiers configured in App Store Connect. Same IDs for iOS
/// and Mac App Store — StoreKit treats them as the same auto-renewable
/// subscription across the user's Apple ID.
const String kIapProductProMonthly = 'day.plot.app.pro_monthly';

/// Connection add-on products. A SEPARATE App Store subscription group from
/// the plans: auto-renewable subscriptions can't be bought in an arbitrary
/// quantity, so "N connection add-ons" is modeled as tiered products (one
/// active at a time). Apple prices are $5.99 / $11.99 / $17.99 for 1 / 2 / 3
/// add-ons (flat $5.99/connection — the cleanest `.99` point above web's
/// $5/unit + Apple's fee). iOS is capped at 3 tiers because Apple's price grid
/// has no clean points above that; web/Stripe is unbounded. The confirm modal
/// shows the live StoreKit price, so these comments are documentation only.
const Map<int, String> kIapAddonProductForCount = {
  1: 'day.plot.app.addon_1',
  2: 'day.plot.app.addon_2',
  3: 'day.plot.app.addon_3',
};

/// Highest add-on count purchasable in-app (the tier cap on iOS).
const int kIapMaxAddons = 3;

/// Twist add-on products. A SEPARATE App Store subscription group from the
/// plan subscriptions and connection add-ons: tiered products (one active at a
/// time) so "N twist add-ons" is purchasable as a step-up upgrade. Apple prices
/// are $11.99 / $23.99 / $35.99 for 1 / 2 / 3 add-ons (flat $11.99/block);
/// web/Stripe is $10/block and unbounded. The confirm modal shows the live
/// StoreKit price, so these comments are documentation only.
const Map<int, String> kIapTwistAddonProductForCount = {
  1: 'day.plot.app.twist_addon_1',
  2: 'day.plot.app.twist_addon_2',
  3: 'day.plot.app.twist_addon_3',
};

/// Highest twist add-on count purchasable in-app (the tier cap on iOS).
const int kIapMaxTwistAddons = 3;

final Set<String> _kAllProductIds = {
  kIapProductProMonthly,
  ...kIapAddonProductForCount.values,
  ...kIapTwistAddonProductForCount.values,
};

/// Outcome of a purchase attempt surfaced to UI.
enum IapPurchaseStatus {
  /// User dismissed the StoreKit sheet without paying.
  canceled,

  /// Purchase succeeded, receipt was forwarded to the server, and the
  /// server confirmed the subscription is now active.
  purchased,

  /// Purchase succeeded on the App Store but the server rejected the
  /// receipt or hasn't yet recognized the entitlement.
  serverError,

  /// StoreKit returned an error.
  storeError,

  /// Apple is still processing the transaction (e.g. Ask-to-Buy /
  /// Family Sharing approval). No further action by us.
  pending,
}

class IapResult {
  const IapResult({required this.status, this.message});
  final IapPurchaseStatus status;
  final String? message;
}

/// StoreKit-backed IAP service. Initialized once at app startup on
/// App Store builds; no-op elsewhere.
///
/// Implements the receipt → server → entitlement flow:
///
///   1. Load products on init so the purchase sheet opens instantly.
///   2. Caller invokes [buy] with a product ID. The StoreKit sheet
///      appears. The future completes once the resulting transaction
///      arrives on the purchase stream and is either ack'd by the
///      server or rejected.
///   3. The purchase stream is also the entry point for renewals,
///      restored purchases, and Apple-initiated state changes — every
///      transaction is forwarded to the server's verification endpoint,
///      which writes/updates the user's subscription.
///   4. `completePurchase()` is always called once the server has
///      verified the receipt, satisfying Apple's "must finish
///      transactions" requirement.
class IapService {
  IapService._();

  static final IapService instance = IapService._();

  /// True while a StoreKit purchase/password sheet is being presented. The macOS
  /// menu bar watches this to drop its Edit-menu Cmd+V/C/X/A key equivalents
  /// while the sheet is up, so those shortcuts reach the native sheet's fields
  /// (e.g. pasting a password) instead of being captured by Flutter's menu —
  /// Flutter's `PlatformMenuBar` items match their key equivalents app-wide,
  /// ahead of the native first responder. Set just before StoreKit presents and
  /// cleared once no in-flight transaction is still `.purchasing` — i.e. the
  /// sheet has actually been dismissed (terminal state, or `.deferred` for
  /// Ask-to-Buy). Crucially it is NOT cleared on the *first* transaction update:
  /// StoreKit delivers `.purchasing` the instant the payment is queued, while
  /// the sheet is still on screen, so clearing then would re-arm the Edit-menu
  /// Paste accelerator before the user could paste. See RootMenuBar and
  /// [storeKitSheetIsUp]. Also used to retire the purchase loading bridge (it
  /// closes when this goes true→false). Always false off the App Store path
  /// (StoreKit purchases never start).
  static final ValueNotifier<bool> nativeSheetActive = ValueNotifier<bool>(
    false,
  );

  /// Whether StoreKit's purchase/password sheet is still on screen for a
  /// transaction in the given [state]. The sheet is up only while the
  /// transaction is `.purchasing`; every other state means it has been
  /// dismissed — `.deferred` (Ask-to-Buy, awaiting approval) as well as the
  /// terminal `.purchased` / `.failed` / `.restored`. `.purchasing` and
  /// `.deferred` both surface as `PurchaseStatus.pending` in the cross-platform
  /// API, so the raw StoreKit state is the only thing that distinguishes
  /// "sheet up" from "sheet dismissed" while pending.
  @visibleForTesting
  static bool storeKitSheetIsUp(SKPaymentTransactionStateWrapper state) =>
      state == SKPaymentTransactionStateWrapper.purchasing;

  /// Whether [purchase] indicates StoreKit's sheet is still on screen, so the
  /// [nativeSheetActive] flag must stay set. On iOS/macOS purchases are
  /// [AppStorePurchaseDetails] and we read the precise transaction state; for
  /// any other shape (e.g. a future StoreKit 2 details type) fall back to the
  /// cross-platform status and treat a still-`pending` transaction as sheet-up,
  /// so Cmd+V keeps reaching the password field. The worst case of that
  /// fallback is the rare Ask-to-Buy path holding the flag until a later
  /// update — never the paste regression.
  static bool _sheetStillUp(PurchaseDetails purchase) {
    if (purchase is AppStorePurchaseDetails) {
      return storeKitSheetIsUp(purchase.skPaymentTransaction.transactionState);
    }
    return purchase.status == PurchaseStatus.pending;
  }

  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSub;
  bool _available = false;
  bool _initialized = false;
  Map<String, ProductDetails> _products = {};

  /// Pending completers keyed on productID so [buy] can await the round
  /// trip even when the purchase stream is the actual carrier of the
  /// result. The same product may be acted on by Apple via background
  /// renewals — those have no awaiting completer and are processed silently.
  final Map<String, Completer<IapResult>> _pending = {};

  /// True only when the running binary is an App Store build *and*
  /// StoreKit reports availability. False on the web, Android, Windows,
  /// Linux, and the macOS DMG build.
  bool get isSupported {
    if (kIsWeb) return false;
    if (!UpgradeUi.isAppStoreBuild) return false;
    return Platform.isIOS || Platform.isMacOS;
  }

  /// True once [init] has succeeded and product details are loaded.
  bool get isReady => _initialized && _available && _products.isNotEmpty;

  ProductDetails? productFor(String productId) => _products[productId];

  /// Idempotent. Call once at app startup, after sign-in is established
  /// (so the user is known when receipts arrive). Safe to call on
  /// non-App-Store platforms — it short-circuits to a no-op.
  Future<void> init() async {
    if (!isSupported) {
      _initialized = true;
      return;
    }

    // Already set up the purchase stream on a prior call. If product loading
    // came back empty earlier (a transient query failure, or the App Store
    // catalogue not yet propagated at first launch), retry it now so a later
    // upgrade tap can recover without an app restart. Without this the
    // `_runIap` lazy-retry was a no-op and the upgrade button stayed wedged.
    if (_initialized) {
      if (_available && _products.isEmpty) await _loadProducts();
      return;
    }

    _available = await _iap.isAvailable();
    if (!_available) {
      log.info('IAP: StoreKit not available on this device');
      _initialized = true;
      return;
    }

    _purchaseSub = _iap.purchaseStream.listen(
      _onPurchaseUpdates,
      onError: (Object error, StackTrace st) {
        log.warning('IAP: purchase stream error', error, st);
      },
    );

    await _loadProducts();
    _initialized = true;
    log.info(
      'IAP: ready (products=${_products.keys.join(",")}, '
      'platform=${Platform.operatingSystem})',
    );
  }

  /// Query the StoreKit catalogue for our subscription products. Safe to call
  /// repeatedly — each call replaces [_products] with the latest response.
  /// Empty [notFoundIDs]-only responses are the usual symptom of a missing
  /// Paid Apps Agreement or unconfigured products in App Store Connect.
  Future<void> _loadProducts() async {
    final response = await _iap.queryProductDetails(_kAllProductIds);
    if (response.error != null) {
      log.warning(
        'IAP: queryProductDetails error: ${response.error!.message}',
      );
    }
    if (response.notFoundIDs.isNotEmpty) {
      log.warning(
        'IAP: product IDs not found in App Store Connect: '
        '${response.notFoundIDs.join(", ")}',
      );
    }
    _products = {for (final p in response.productDetails) p.id: p};
  }

  /// Begin a purchase for [productId]. Returns when the transaction has
  /// either been completed (server acknowledged the receipt), failed, or
  /// was canceled by the user. The result also reflects the server's
  /// validation outcome — purchase is only [IapPurchaseStatus.purchased]
  /// if both StoreKit and our server agreed.
  Future<IapResult> buy(String productId) async {
    if (!isSupported) {
      return const IapResult(
        status: IapPurchaseStatus.storeError,
        message: 'In-app purchases are not supported on this device.',
      );
    }
    if (!_initialized) await init();
    if (!_available) {
      return const IapResult(
        status: IapPurchaseStatus.storeError,
        message: 'In-app purchases are not available right now.',
      );
    }

    final product = _products[productId];
    if (product == null) {
      return const IapResult(
        status: IapPurchaseStatus.storeError,
        message: 'This subscription is not currently available.',
      );
    }

    // If a purchase for the same product is already in flight (e.g. the
    // user double-tapped), reuse the in-flight completer instead of
    // starting a duplicate transaction.
    final existing = _pending[productId];
    if (existing != null && !existing.isCompleted) return existing.future;

    final completer = Completer<IapResult>();
    _pending[productId] = completer;

    // The native StoreKit sheet is about to appear. Flag it so the macOS menu
    // bar drops its Edit-menu accelerators (so Cmd+V etc. reach the sheet's
    // password field). Set before the focus flush below so the menu rebuilds
    // before the sheet shows; cleared in `_onPurchaseUpdates` once the sheet is
    // dismissed (no transaction still `.purchasing`), or here if the launch
    // throws.
    nativeSheetActive.value = true;

    // Release Flutter's keyboard focus before presenting the StoreKit sheet.
    // On macOS (and iOS) the native purchase/password sheet shares the app
    // window, so while a Flutter text field still owns the text input
    // connection the sheet's password field can't become first responder —
    // anything typed or pasted goes to the field behind the sheet instead.
    // Dropping focus sends `TextInput.clearClient`; the zero-delay await lets
    // that platform message flush (focus changes apply on the next microtask)
    // before the sheet appears, so the native field receives keystrokes.
    FocusManager.instance.primaryFocus?.unfocus();
    await Future<void>.delayed(Duration.zero);

    final purchaseParam = PurchaseParam(productDetails: product);
    try {
      // Subscriptions go through buyNonConsumable on both StoreKit and
      // Google Play; auto-renewal is handled by the platform.
      await _iap.buyNonConsumable(purchaseParam: purchaseParam);
    } catch (e, st) {
      log.warning('IAP: buyNonConsumable threw', e, st);
      _pending.remove(productId);
      nativeSheetActive.value = false;
      return IapResult(
        status: IapPurchaseStatus.storeError,
        message: e.toString(),
      );
    }
    return completer.future;
  }

  /// Buy (or change to) the add-on tier granting [count] connection add-ons.
  /// Tiers are mutually exclusive within the App Store add-on subscription
  /// group, so picking a higher tier upgrades the user's add-on count (Apple
  /// prorates the change).
  Future<IapResult> buyAddon(int count) {
    final productId = kIapAddonProductForCount[count];
    if (productId == null) {
      return Future.value(
        const IapResult(
          status: IapPurchaseStatus.storeError,
          message: 'That add-on amount is not available.',
        ),
      );
    }
    return buy(productId);
  }

  /// Buy (or change to) the twist add-on tier granting [count] twist add-ons.
  /// Tiers are mutually exclusive within the App Store twist add-on subscription
  /// group, so picking a higher tier upgrades the user's add-on count (Apple
  /// prorates the change).
  Future<IapResult> buyTwistAddon(int count) {
    final productId = kIapTwistAddonProductForCount[count];
    if (productId == null) {
      return Future.value(
        const IapResult(
          status: IapPurchaseStatus.storeError,
          message: 'That add-on amount is not available.',
        ),
      );
    }
    return buy(productId);
  }

  /// Trigger a restore of all past purchases tied to the user's Apple
  /// ID. Returns once StoreKit has finished re-delivering them via the
  /// purchase stream. Apple requires every app with subscriptions to
  /// surface a "Restore Purchases" affordance.
  Future<void> restorePurchases() async {
    if (!isSupported) return;
    if (!_initialized) await init();
    if (!_available) return;
    await _iap.restorePurchases();
  }

  Future<void> _onPurchaseUpdates(List<PurchaseDetails> purchases) async {
    // Lower the menu-suppression flag once StoreKit's purchase/password sheet
    // is no longer on screen, but NOT before. The sheet is up only while a
    // transaction is `.purchasing`; `.deferred` (Ask-to-Buy) and every terminal
    // state mean it has been dismissed. The earlier "clear on the first update"
    // logic re-armed the Edit-menu Paste accelerator on the `.purchasing`
    // update — delivered while the sheet was still showing — so Cmd+V never
    // reached the password field. Background renewals/restores arrive here too
    // with no sheet up, where this is a harmless no-op (already false).
    if (nativeSheetActive.value && !purchases.any(_sheetStillUp)) {
      nativeSheetActive.value = false;
    }
    for (final purchase in purchases) {
      await _handlePurchase(purchase);
    }
  }

  Future<void> _handlePurchase(PurchaseDetails purchase) async {
    log.info(
      'IAP: update productID=${purchase.productID} '
      'status=${purchase.status.name} pending=${purchase.pendingCompletePurchase}',
    );

    switch (purchase.status) {
      case PurchaseStatus.pending:
        _resolvePending(
          purchase.productID,
          const IapResult(status: IapPurchaseStatus.pending),
          keepWaiting: true,
        );
        return;

      case PurchaseStatus.canceled:
        _resolvePending(
          purchase.productID,
          const IapResult(status: IapPurchaseStatus.canceled),
        );
        // Even canceled purchases sometimes need to be acknowledged to
        // clear StoreKit's queue.
        if (purchase.pendingCompletePurchase) {
          await _iap.completePurchase(purchase);
        }
        return;

      case PurchaseStatus.error:
        log.warning(
          'IAP: purchase error productID=${purchase.productID} '
          'code=${purchase.error?.code} message=${purchase.error?.message}',
        );
        _resolvePending(
          purchase.productID,
          IapResult(
            status: IapPurchaseStatus.storeError,
            message: purchase.error?.message,
          ),
        );
        if (purchase.pendingCompletePurchase) {
          await _iap.completePurchase(purchase);
        }
        return;

      case PurchaseStatus.purchased:
      case PurchaseStatus.restored:
        final verified = await _verifyWithServer(purchase);
        // Always finish the transaction. Apple keeps re-delivering until
        // we complete it; the server has its receipt now and renewals
        // will arrive via App Store Server Notifications V2.
        if (purchase.pendingCompletePurchase) {
          try {
            await _iap.completePurchase(purchase);
          } catch (e, st) {
            log.warning('IAP: completePurchase failed', e, st);
          }
        }
        _resolvePending(
          purchase.productID,
          IapResult(
            status: verified
                ? IapPurchaseStatus.purchased
                : IapPurchaseStatus.serverError,
          ),
        );
        return;
    }
  }

  /// POST the StoreKit receipt to the server, which validates with Apple
  /// and writes the entitlement onto the current user.
  Future<bool> _verifyWithServer(PurchaseDetails purchase) async {
    try {
      final serverData = purchase.verificationData.serverVerificationData;
      final source = purchase.verificationData.source; // 'app_store'
      await api.post<Map<String, dynamic>>(
        '/upgrade/iap/verify',
        body: {
          'product_id': purchase.productID,
          'source': source,
          'purchase_id': purchase.purchaseID,
          'transaction_data': serverData,
        },
      );
      return true;
    } catch (e, st) {
      log.warning(
        'IAP: server verification failed for ${purchase.productID}',
        e,
        st,
      );
      return false;
    }
  }

  void _resolvePending(
    String productId,
    IapResult result, {
    bool keepWaiting = false,
  }) {
    final completer = _pending[productId];
    if (completer == null) return;
    if (completer.isCompleted) {
      _pending.remove(productId);
      return;
    }
    if (keepWaiting) return;
    completer.complete(result);
    _pending.remove(productId);
  }

  Future<void> dispose() async {
    await _purchaseSub?.cancel();
    _purchaseSub = null;
  }
}
