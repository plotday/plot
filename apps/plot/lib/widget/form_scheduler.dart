import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'package:forui/forui.dart';

import 'package:plot/style/plot_colors.dart';
import 'package:plot/util/time.dart';
import 'package:plot/widget/form.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/icon_input_row.dart';
import 'package:plot/widget/date_input.dart';
import 'package:plot/widget/duration_input.dart';
import 'package:plot/widget/time_range_input.dart';
import 'package:plot/widget/schedule_range.dart';
import 'package:plot/widget/step_controller.dart';

/// Wraps a single scheduler row so the Left/Right cursor keys adjust its value
/// when the row holds form focus. Plain `←`/`→` do the small step;
/// `Shift+←`/`Shift+→` do the large jump. Every other key (↑/↓/Tab/Enter/Esc)
/// is returned as ignored so [FormModal]'s own navigation handles it.
///
/// Implicit edit-mode: these handlers only fire when [focusNode] (the row) has
/// focus. When the user clicks into an inner editable field, that field owns
/// focus and consumes `←`/`→` for its text cursor, so typing still works.
///
/// [highlightColor] is painted behind [child] when non-null (the caller decides
/// the row is active and supplies the themed color); null = no background.
class StepperRow extends StatelessWidget {
  const StepperRow({
    required this.focusNode,
    required this.child,
    this.highlightColor,
    this.onStepBack,
    this.onStepForward,
    this.onJumpBack,
    this.onJumpForward,
    super.key,
  });

  final FocusNode focusNode;
  final Widget child;
  final Color? highlightColor;
  final VoidCallback? onStepBack;
  final VoidCallback? onStepForward;
  final VoidCallback? onJumpBack;
  final VoidCallback? onJumpForward;

  bool get _shiftPressed =>
      HardwareKeyboard.instance.logicalKeysPressed
          .contains(LogicalKeyboardKey.shiftLeft) ||
      HardwareKeyboard.instance.logicalKeysPressed
          .contains(LogicalKeyboardKey.shiftRight);

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      final cb = _shiftPressed ? onJumpBack : onStepBack;
      if (cb == null) return KeyEventResult.ignored;
      cb();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      final cb = _shiftPressed ? onJumpForward : onStepForward;
      if (cb == null) return KeyEventResult.ignored;
      cb();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final color = highlightColor;
    return Focus(
      focusNode: focusNode,
      onKeyEvent: _onKey,
      child: color != null ? ColoredBox(color: color, child: child) : child,
    );
  }
}

/// A [FormItem] for picking a date + start/end time + duration as a single
/// [DateTimeRange]. Renders three keyboard-steppable rows (date, time, duration)
/// — each a [StepperRow] over the existing chevron+typing input widgets — and
/// exposes them to [FormModal] as three focusable sub-slots. `getValue()`
/// returns the current [DateTimeRange].
class FormScheduler extends FormItem {
  FormScheduler({
    required super.key,
    required DateTimeRange initialRange,
    this.allowPastTimes = false,
    this.onChanged,
  }) : assert(
         initialRange.start != null && initialRange.end != null,
         'FormScheduler requires a bounded initial range (non-null start/end)',
       ),
       _range = initialRange,
       super(required: true);

  /// When true, past start times are preserved (edit mode). When false, the
  /// range is slid forward to "now" (create mode).
  final bool allowPastTimes;

  /// Optional external change callback.
  final VoidCallback? onChanged;

  DateTimeRange _range;
  final List<VoidCallback> _changeListeners = [];

  /// One controller per sub-slot: [0]=date, [1]=time, [2]=duration.
  final List<StepController> _stepControllers = [
    StepController(),
    StepController(),
    StepController(),
  ];

  @override
  bool get isFocusable => true;

  @override
  int get focusableCount => 3;

  @override
  bool get canActivate => true;

  @override
  DateTimeRange getValue() => _range;

  @override
  void setValue(dynamic value) {
    if (value is DateTimeRange) {
      _range = value;
      _notify();
    }
  }

  @override
  bool isValid() {
    final start = _range.start;
    final end = _range.end;
    return start != null && end != null && end.isAfter(start);
  }

  @override
  void addChangeListener(VoidCallback listener) =>
      _changeListeners.add(listener);

  @override
  void removeChangeListener(VoidCallback listener) =>
      _changeListeners.remove(listener);

  void _notify() {
    onChanged?.call();
    for (final l in _changeListeners) {
      l();
    }
  }

  /// Enter / tap on a row focuses its inner editable field for typing.
  @override
  Future<void> activate(BuildContext context, {int subIndex = 0}) async {
    if (subIndex >= 0 && subIndex < _stepControllers.length) {
      _stepControllers[subIndex].focusEditor?.call();
    }
  }

  @override
  Widget build(
    BuildContext context,
    int highlightedSubIndex, {
    bool enabled = true,
    List<FocusNode> focusNodes = const [],
    FormButtonController? controller,
  }) {
    return _FormSchedulerBody(
      range: _range,
      allowPastTimes: allowPastTimes,
      highlightedSubIndex: highlightedSubIndex,
      focusNodes: focusNodes,
      stepControllers: _stepControllers,
      onChanged: (next) {
        _range = next;
        _notify();
      },
    );
  }
}

class _FormSchedulerBody extends StatefulWidget {
  const _FormSchedulerBody({
    required this.range,
    required this.allowPastTimes,
    required this.highlightedSubIndex,
    required this.focusNodes,
    required this.stepControllers,
    required this.onChanged,
  });

  final DateTimeRange range;
  final bool allowPastTimes;
  final int highlightedSubIndex;
  final List<FocusNode> focusNodes;
  final List<StepController> stepControllers;
  final ValueChanged<DateTimeRange> onChanged;

  @override
  State<_FormSchedulerBody> createState() => _FormSchedulerBodyState();
}

class _FormSchedulerBodyState extends State<_FormSchedulerBody> {
  late DateTimeRange _range;

  @override
  void initState() {
    super.initState();
    _range = widget.range;
  }

  @override
  void didUpdateWidget(_FormSchedulerBody old) {
    super.didUpdateWidget(old);
    if (old.range != widget.range && widget.range != _range) {
      _range = widget.range;
    }
  }

  void _apply(DateTimeRange next) {
    final clamped = clampScheduleRange(
      next,
      allowPast: widget.allowPastTimes,
      now: Time.now(),
    );
    setState(() => _range = clamped);
    widget.onChanged(clamped);
  }

  FocusNode _node(int i) {
    assert(
      i < widget.focusNodes.length,
      'FormScheduler.focusableCount is 3 but only '
      '${widget.focusNodes.length} focus nodes were provided',
    );
    return widget.focusNodes[i];
  }

  StepController _ctrl(int i) => widget.stepControllers[i];

  @override
  Widget build(BuildContext context) {
    final start = _range.start;
    final startFTime = start != null ? FTime.fromDateTime(start) : FTime.now();
    final end = _range.end;
    final endFTime = end != null
        ? FTime.fromDateTime(end)
        : FTime.fromDateTime(Time.now().add(const Duration(hours: 1)));

    final highlight = context.theme.plotColors.editableBackground;
    Color? hlFor(int i) => widget.highlightedSubIndex == i ? highlight : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 0: Date
        StepperRow(
          focusNode: _node(0),
          highlightColor: hlFor(0),
          onStepBack: () => _ctrl(0).stepBack?.call(),
          onStepForward: () => _ctrl(0).stepForward?.call(),
          onJumpBack: () => _ctrl(0).jumpBack?.call(),
          onJumpForward: () => _ctrl(0).jumpForward?.call(),
          child: IconInputRow(
            icon: PlotIcon.event,
            content: DateInput(
              value: _range.start,
              onChanged: (date) {
                if (date != null) _apply(withDate(_range, date));
              },
              stepController: _ctrl(0),
            ),
          ),
        ),
        // 1: Time range
        StepperRow(
          focusNode: _node(1),
          highlightColor: hlFor(1),
          onStepBack: () => _ctrl(1).stepBack?.call(),
          onStepForward: () => _ctrl(1).stepForward?.call(),
          onJumpBack: () => _ctrl(1).jumpBack?.call(),
          onJumpForward: () => _ctrl(1).jumpForward?.call(),
          child: IconInputRow(
            icon: PlotIcon.later,
            content: TimeRangeInput(
              startTime: startFTime,
              endTime: endFTime,
              onStartTimeChanged: (t) {
                if (t != null) _apply(withStart(_range, t));
              },
              onEndTimeChanged: (t) {
                if (t != null) _apply(withEnd(_range, t));
              },
              onRangeShift: (delta) => _apply(shiftedBy(_range, delta)),
              stepController: _ctrl(1),
            ),
          ),
        ),
        // 2: Duration
        StepperRow(
          focusNode: _node(2),
          highlightColor: hlFor(2),
          onStepBack: () => _ctrl(2).stepBack?.call(),
          onStepForward: () => _ctrl(2).stepForward?.call(),
          onJumpBack: () => _ctrl(2).jumpBack?.call(),
          onJumpForward: () => _ctrl(2).jumpForward?.call(),
          child: IconInputRow(
            icon: PlotIcon.waiting,
            content: DurationInput(
              value: _range.duration ?? const Duration(minutes: 30),
              onChanged: (d) => _apply(withDuration(_range, d)),
              stepController: _ctrl(2),
            ),
          ),
        ),
      ],
    );
  }
}
