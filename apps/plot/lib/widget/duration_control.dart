import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/widget/duration_modal.dart';

/// Compact duration display with inline editing affordances.
///
/// On desktop (hover-capable), `−` and `+` glyphs slide in at the outer edges
/// when the cursor enters; tapping each half steps the duration by 15 minutes.
/// On touch platforms, a single tap opens [DurationModal].
class DurationControl extends StatefulWidget {
  const DurationControl({
    required this.value,
    required this.onChanged,
    required this.foreground,
    super.key,
  });

  /// Current duration. Null means "no duration set".
  final Duration? value;

  /// Called with the new duration. `null` means "clear duration".
  /// If null, the control renders read-only (no controls revealed,
  /// no tap handler).
  final ValueChanged<Duration?>? onChanged;

  /// Foreground accent color (priority's display color).
  final Color foreground;

  static const _step = Duration(minutes: 15);

  @override
  State<DurationControl> createState() => _DurationControlState();
}

class _DurationControlState extends State<DurationControl> {
  bool _hover = false;

  String _format(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes - h * 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h${m}m';
  }

  Duration? _bump(Duration? current, Duration delta) {
    final next = (current ?? Duration.zero) + delta;
    if (next <= Duration.zero) return null;
    return next;
  }

  Future<void> _openModal() async {
    final result = await DurationModal(
      initial: widget.value,
    ).show<Duration?>(context);
    if (!result.present) return;
    widget.onChanged?.call(result.value);
  }

  @override
  Widget build(BuildContext context) {
    final fontSize = context.theme.typography.sm.fontSize ?? 13;
    final readOnly = widget.onChanged == null;
    final value = widget.value;

    if (isTouchPlatform()) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: readOnly ? null : _openModal,
        child: _label(value, fontSize),
      );
    }

    // Right edge of the visible text aligns with the container's inner
    // right edge minus the label's 6px padding — so its right edge lands
    // at the same x as gap-row durations. The "+" glyph is rendered as a
    // [Positioned] overlay past the right edge so it does not push the
    // label inward (which previously caused the event-block duration to
    // sit ~18px more inset than gap durations).
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: readOnly
            ? null
            : (details) {
          final box =
              context.findRenderObject() as RenderBox?;
          if (box == null) return;
          final tapX = details.localPosition.dx;
          final centerX = box.size.width / 2;
          if (tapX < centerX) {
            widget.onChanged!(_bump(value, -DurationControl._step));
          } else {
            widget.onChanged!(_bump(value, DurationControl._step));
          }
        },
        child: SizedBox(
          height: 20,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              _label(value, fontSize),
              Positioned(
                left: -18,
                top: 0,
                bottom: 0,
                child: _HitGlyph(
                  visible: _hover && !readOnly && value != null,
                  glyph: '−',
                  fontSize: fontSize,
                  foreground: widget.foreground,
                ),
              ),
              Positioned(
                right: -18,
                top: 0,
                bottom: 0,
                child: _HitGlyph(
                  visible: _hover && !readOnly,
                  glyph: '+',
                  fontSize: fontSize,
                  foreground: widget.foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(Duration? value, double fontSize) {
    final text = value == null ? '' : _format(value);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: fontSize,
          color: widget.foreground,
          height: 1,
        ),
      ),
    );
  }
}

class _HitGlyph extends StatelessWidget {
  const _HitGlyph({
    required this.visible,
    required this.glyph,
    required this.fontSize,
    required this.foreground,
  });

  final bool visible;
  final String glyph;
  final double fontSize;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 20,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 120),
        child: Center(
          child: Text(
            glyph,
            style: TextStyle(
              fontSize: fontSize + 1,
              height: 1,
              color: foreground,
            ),
          ),
        ),
      ),
    );
  }
}
