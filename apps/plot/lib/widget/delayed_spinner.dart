import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:plot/widget/spinner.dart';

/// A [Spinner] that only appears after [delay] (default 100ms).
///
/// Embeddable anywhere a load might resolve instantly from local data — e.g.
/// the thread note list while notes load on demand. The delay means no spinner
/// flashes when notes are already local (the content arrives within a frame),
/// while a genuine network pull still surfaces a spinner. Mirrors the
/// delayed-spinner pattern in `LoadingPage` (which uses 200ms for full-page
/// transitions).
class DelayedSpinner extends StatefulWidget {
  const DelayedSpinner({
    this.delay = const Duration(milliseconds: 100),
    this.size = 22,
    super.key,
  });

  final Duration delay;
  final double size;

  @override
  State<DelayedSpinner> createState() => _DelayedSpinnerState();
}

class _DelayedSpinnerState extends State<DelayedSpinner> {
  bool _show = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.delay, () {
      if (mounted) setState(() => _show = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
    return Spinner(size: widget.size);
  }
}
