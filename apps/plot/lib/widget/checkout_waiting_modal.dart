import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
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
