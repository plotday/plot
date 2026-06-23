import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:in_app_purchase/in_app_purchase.dart';

import 'package:plot/api/api.dart' as api;
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/logging.dart';

/// Product identifiers configured in App Store Connect. Same IDs for iOS
/// and Mac App Store — StoreKit treats them as the same auto-renewable
/// subscription across the user's Apple ID.
const String kIapProductCoreMonthly = 'day.plot.app.core_monthly';
const String kIapProductProMonthly = 'day.plot.app.pro_monthly';

const Set<String> _kAllProductIds = {
  kIapProductCoreMonthly,
  kIapProductProMonthly,
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

    final purchaseParam = PurchaseParam(productDetails: product);
    try {
      // Subscriptions go through buyNonConsumable on both StoreKit and
      // Google Play; auto-renewal is handled by the platform.
      await _iap.buyNonConsumable(purchaseParam: purchaseParam);
    } catch (e, st) {
      log.warning('IAP: buyNonConsumable threw', e, st);
      _pending.remove(productId);
      return IapResult(
        status: IapPurchaseStatus.storeError,
        message: e.toString(),
      );
    }
    return completer.future;
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
