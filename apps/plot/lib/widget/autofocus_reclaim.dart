import 'package:flutter/widgets.dart';

/// Keeps an autofocusing editor focused when a single one-shot `autofocus`
/// isn't reliable.
///
/// The new-thread composer runs its [NoteEditor] in `bodyOnly` mode, which
/// bypasses [EditableArea] (and therefore its focus recovery). On its own,
/// SuperEditor's one-shot `autofocus` loses two documented races as the page
/// mounts:
///
///  * macOS clears `primaryFocus` to the root scope on spurious
///    inactive/hidden lifecycle transitions, and
///  * the navigator's post-route focus pass clears focus the frame after a
///    route mounts — the same race the search field works around with its
///    `_focusSearchSoon` retry.
///
/// When either happens, the editor never gains focus and the app sits with no
/// focus owner: keyboard shortcuts still fire (they're dispatched from
/// app-level shortcuts), but typing goes nowhere.
///
/// [AutofocusReclaim] re-requests focus on [focusNode] across a few frames
/// after mount so it survives those transitions. It only claims focus while
/// nobody else owns it (the root scope, or no primary focus at all), so it
/// never steals focus from a user who tapped another control, and it stops as
/// soon as the node is focused.
///
/// Recovery only runs while [autofocus] is true. Editors that opt out of
/// autofocus — e.g. a note-mode editor on a touch platform, where grabbing
/// focus would pop the soft keyboard — are left untouched.
class AutofocusReclaim extends StatefulWidget {
  const AutofocusReclaim({
    required this.focusNode,
    required this.autofocus,
    required this.child,
    this.maxAttempts = 5,
    super.key,
  });

  /// The editor's focus node. [AutofocusReclaim] drives focus on this node but
  /// does not attach it — [child] is expected to wire it into a [Focus]/editor.
  final FocusNode focusNode;

  /// Whether this editor is configured to autofocus. Recovery is a no-op when
  /// false.
  final bool autofocus;

  /// Maximum number of consecutive frames to attempt reclaiming focus after
  /// mount (or after [autofocus] turns on).
  final int maxAttempts;

  final Widget child;

  @override
  State<AutofocusReclaim> createState() => _AutofocusReclaimState();
}

class _AutofocusReclaimState extends State<AutofocusReclaim> {
  @override
  void initState() {
    super.initState();
    if (widget.autofocus) _reclaim();
  }

  @override
  void didUpdateWidget(AutofocusReclaim oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Start a fresh pass if autofocus turns on (e.g. a panel-layout change
    // promotes this editor to the active composer).
    if (widget.autofocus && !oldWidget.autofocus) _reclaim();
  }

  void _reclaim({int attempt = 0}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.autofocus) return;
      final node = widget.focusNode;
      if (node.hasFocus) return;
      // Skip claiming on the first pass — focus changes from this mount frame
      // (the editor's own autofocus, or a sibling's) are still pending and
      // haven't committed to primaryFocus yet. Observing one frame first lets
      // them land so the safety net never grabs focus out from under them.
      if (attempt > 0) {
        // Only claim focus when nobody else owns it: the root scope (where
        // macOS and the navigator's post-route pass park focus) or no primary
        // focus at all. Never yank focus from a deliberate move elsewhere.
        final primary = FocusManager.instance.primaryFocus;
        final ownerless =
            primary == null ||
            identical(primary, FocusManager.instance.rootScope);
        if (ownerless && node.canRequestFocus) {
          node.requestFocus();
        }
      }
      // Keep retrying across a few frames: the contended focus often settles a
      // frame or two after mount (the outgoing editor releasing to the root
      // scope). A post-frame callback alone doesn't request a frame, so pump
      // one explicitly — otherwise the chain stalls on any pass that didn't
      // call requestFocus (the observe pass, or a pass where someone else
      // owned focus and then let go).
      if (attempt + 1 < widget.maxAttempts) {
        _reclaim(attempt: attempt + 1);
        WidgetsBinding.instance.scheduleFrame();
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
