import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase_storekit/store_kit_wrappers.dart';
import 'package:plot/api/iap_api.dart';

void main() {
  // While `IapService.nativeSheetActive` is true the macOS menu bar drops its
  // Edit-menu Cmd+V/C/X/A key equivalents so they reach the native StoreKit
  // password sheet instead of being captured by Flutter's `PlatformMenuBar`.
  // The flag therefore has to stay true for the WHOLE time the sheet is on
  // screen.
  //
  // StoreKit reports `.purchasing` while the sheet is up — that update is
  // delivered the instant the payment is queued, before the user has typed or
  // pasted a password — and `.deferred` once the sheet has been dismissed to
  // await Ask-to-Buy approval. Both surface as `PurchaseStatus.pending`, so
  // only the StoreKit transaction state can tell "sheet still up" from "sheet
  // dismissed". The shipped 1.5.0+370 build cleared the flag on the first
  // transaction update unconditionally — i.e. on that early `.purchasing`
  // update — which re-armed the Edit-menu Paste accelerator so Cmd+V never
  // reached the password field.
  group('IapService.storeKitSheetIsUp', () {
    test('is true while the transaction is purchasing (sheet on screen)', () {
      expect(
        IapService.storeKitSheetIsUp(
          SKPaymentTransactionStateWrapper.purchasing,
        ),
        isTrue,
      );
    });

    test('is false once the transaction is deferred (sheet dismissed)', () {
      expect(
        IapService.storeKitSheetIsUp(
          SKPaymentTransactionStateWrapper.deferred,
        ),
        isFalse,
      );
    });

    test('is false for terminal / unspecified states (sheet dismissed)', () {
      for (final state in const [
        SKPaymentTransactionStateWrapper.purchased,
        SKPaymentTransactionStateWrapper.failed,
        SKPaymentTransactionStateWrapper.restored,
        SKPaymentTransactionStateWrapper.unspecified,
      ]) {
        expect(
          IapService.storeKitSheetIsUp(state),
          isFalse,
          reason: 'state=$state should not keep the sheet flag set',
        );
      }
    });
  });
}
