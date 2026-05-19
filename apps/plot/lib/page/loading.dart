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

class _LoadingPageState extends State<LoadingPage>
    with WidgetsBindingObserver {
  static const _slowAfter = Duration(seconds: 30);
  static const _stuckAfter = Duration(seconds: 60);

  bool _showSpinner = false;
  String? _slowMessage;
  Timer? _spinnerTimer;
  Timer? _slowTimer;
  Timer? _stuckTimer;
  bool _slowFired = false;
  bool _stuckFired = false;

  // Cumulative time the page has been visible while the app was in the
  // foreground. Time spent backgrounded (window hidden, screen locked,
  // laptop asleep, another tab focused) does NOT count — otherwise the
  // 60s stuck-loading timer fires for users who simply left the app
  // sitting in the background, producing a false-positive error report.
  Duration _foregroundElapsed = Duration.zero;
  DateTime? _foregroundStartedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _foregroundStartedAt = DateTime.now();
    }

    // Delay showing the spinner to avoid flashing for quick transitions
    _spinnerTimer = Timer(const Duration(milliseconds: 200), () {
      if (mounted) {
        setState(() {
          _showSpinner = true;
        });
      }
    });

    _scheduleLifecycleAwareTimers();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foregroundStartedAt ??= DateTime.now();
      _scheduleLifecycleAwareTimers();
    } else {
      _accumulateForegroundElapsed();
      _slowTimer?.cancel();
      _stuckTimer?.cancel();
    }
  }

  void _accumulateForegroundElapsed() {
    final startedAt = _foregroundStartedAt;
    if (startedAt == null) return;
    _foregroundElapsed += DateTime.now().difference(startedAt);
    _foregroundStartedAt = null;
  }

  Duration get _currentForegroundElapsed {
    final startedAt = _foregroundStartedAt;
    if (startedAt == null) return _foregroundElapsed;
    return _foregroundElapsed + DateTime.now().difference(startedAt);
  }

  void _scheduleLifecycleAwareTimers() {
    _slowTimer?.cancel();
    _stuckTimer?.cancel();
    if (_foregroundStartedAt == null) return;
    final elapsed = _currentForegroundElapsed;

    if (!_slowFired) {
      final remaining = _slowAfter - elapsed;
      _slowTimer = Timer(
        remaining <= Duration.zero ? Duration.zero : remaining,
        _fireSlow,
      );
    }
    if (!_stuckFired) {
      final remaining = _stuckAfter - elapsed;
      _stuckTimer = Timer(
        remaining <= Duration.zero ? Duration.zero : remaining,
        _fireStuck,
      );
    }
  }

  void _fireSlow() {
    if (!mounted || _slowFired) return;
    _slowFired = true;
    setState(() {
      _slowMessage = 'Still loading...';
    });
  }

  void _fireStuck() {
    if (!mounted || _stuckFired) return;
    _stuckFired = true;
    setState(() {
      _slowMessage = 'Something may have gone wrong';
    });
    // 60s of foreground time on a LoadingPage means an operation we
    // expected to complete in seconds is taking minutes — almost always
    // a UI/routing bug (e.g. an empty AutoRouter inner stack falling
    // back to its placeholder forever) rather than a slow-network
    // condition. Report it so it shows up in error tracking instead of
    // just on the user's screen.
    Tracker.captureException(
      StuckLoadingPageException(
        message: widget.message,
        userStatus: UserBloc.statusNotifier.value,
      ),
      StackTrace.current,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
