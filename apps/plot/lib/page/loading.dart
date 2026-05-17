import 'dart:async';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/state/user.dart';
import 'package:plot/widget/widget.dart';

/// Thrown when a [LoadingPage] is still on screen 60s after it mounted —
/// i.e. some operation that was supposed to complete in seconds is taking
/// minutes. Captured to PostHog so UI freezes that aren't surfaced as
/// regular exceptions still show up in error tracking.
class StuckLoadingPageException implements Exception {
  StuckLoadingPageException({
    required this.message,
    required this.userStatus,
  });

  final String? message;
  final String? userStatus;

  @override
  String toString() {
    final parts = <String>[];
    if (message != null) parts.add('message="$message"');
    if (userStatus != null) parts.add('userStatus="$userStatus"');
    final detail = parts.isEmpty ? '' : ' (${parts.join(', ')})';
    return 'StuckLoadingPageException: LoadingPage still visible after 60s$detail';
  }
}

class LoadingPage extends StatefulWidget {
  const LoadingPage({this.message, super.key});

  final String? message;

  @override
  State<LoadingPage> createState() => _LoadingPageState();
}

class _LoadingPageState extends State<LoadingPage> {
  bool _showSpinner = false;
  String? _slowMessage;
  Timer? _spinnerTimer;
  Timer? _slowTimer;
  Timer? _stuckTimer;

  @override
  void initState() {
    super.initState();
    // Delay showing the spinner to avoid flashing for quick transitions
    _spinnerTimer = Timer(const Duration(milliseconds: 200), () {
      if (mounted) {
        setState(() {
          _showSpinner = true;
        });
      }
    });

    _slowTimer = Timer(const Duration(seconds: 30), () {
      if (mounted) {
        setState(() {
          _slowMessage = 'Still loading...';
        });
      }
    });

    _stuckTimer = Timer(const Duration(seconds: 60), () {
      if (!mounted) return;
      setState(() {
        _slowMessage = 'Something may have gone wrong';
      });
      // 60s on a LoadingPage means an operation we expected to complete
      // in seconds is taking minutes — almost always a UI/routing bug
      // (e.g. an empty AutoRouter inner stack falling back to its
      // placeholder forever) rather than a slow-network condition.
      // Report it so it shows up in error tracking instead of just on
      // the user's screen.
      Tracker.captureException(
        StuckLoadingPageException(
          message: widget.message,
          userStatus: UserBloc.statusNotifier.value,
        ),
        StackTrace.current,
      );
    });
  }

  @override
  void dispose() {
    _spinnerTimer?.cancel();
    _slowTimer?.cancel();
    _stuckTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      center: true,
      body: Stack(
        alignment: Alignment.center,
        children: [
          if (_showSpinner) Spinner(size: 22),
          Padding(
            padding: const EdgeInsets.only(top: 60),
            child: ValueListenableBuilder<String?>(
              valueListenable: UserBloc.statusNotifier,
              builder: (context, status, _) {
                final displayMessage =
                    _slowMessage ?? status ?? widget.message;
                if (displayMessage == null) return const SizedBox.shrink();
                return Text(
                  displayMessage,
                  style: TextStyle(
                    color: context.theme.colors.mutedForeground,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
