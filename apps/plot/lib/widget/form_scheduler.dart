import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'package:forui/forui.dart';

import 'package:plot/style/spacing.dart';
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

  // Enter on any scheduler row submits the form (like a text field), instead of
  // entering per-field edit mode — FormModal restores row focus right after
  // `activate`, which made an Enter-to-edit flash and revert. Typing stays
  // available by clicking into a field; arrow keys adjust without typing.
  VoidCallback? _onSubmitted;

  @override
  set onSubmitted(VoidCallback? callback) => _onSubmitted = callback;

  @override
  VoidCallback? get onSubmitted => _onSubmitted;

  /// Focus a row's inner editable field (e.g. when the row is tapped). Not
  /// reached via Enter — Enter submits the form (see [onSubmitted]).
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

/// A [FormItem] for picking a single date + time (minute granularity) as a
/// [DateTime]. Two keyboard-steppable rows — date and time — mirroring
/// [FormScheduler] but without a range/duration. Used by the schedule-send
/// modal. `getValue()` returns the chosen [DateTime].
class FormSendScheduler extends FormItem {
  FormSendScheduler({
    required super.key,
    required DateTime initialValue,
    this.onChanged,
  }) : _value = initialValue,
       super(required: true);

  /// Optional external change callback.
  final VoidCallback? onChanged;

  DateTime _value;
  final List<VoidCallback> _changeListeners = [];

  /// One controller per sub-slot: [0]=date, [1]=time.
  final List<StepController> _stepControllers = [
    StepController(),
    StepController(),
  ];

  @override
  bool get isFocusable => true;

  @override
  int get focusableCount => 2;

  @override
  bool get canActivate => true;

  @override
  DateTime getValue() => _value;

  @override
  void setValue(dynamic value) {
    if (value is DateTime) {
      _value = value;
      _notify();
    }
  }

  // A scheduled send must be in the future; the body clamps to now+1 min on
  // edit, so validity only guards direct typing of a past instant.
  @override
  bool isValid() => _value.isAfter(Time.now());

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

  // Enter submits the form (see FormScheduler.onSubmitted for rationale).
  VoidCallback? _onSubmitted;

  @override
  set onSubmitted(VoidCallback? callback) => _onSubmitted = callback;

  @override
  VoidCallback? get onSubmitted => _onSubmitted;

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
    return _FormSendSchedulerBody(
      value: _value,
      highlightedSubIndex: highlightedSubIndex,
      focusNodes: focusNodes,
      stepControllers: _stepControllers,
      onChanged: (next) {
        _value = next;
        _notify();
      },
    );
  }
}

class _FormSendSchedulerBody extends StatefulWidget {
  const _FormSendSchedulerBody({
    required this.value,
    required this.highlightedSubIndex,
    required this.focusNodes,
    required this.stepControllers,
    required this.onChanged,
  });

  final DateTime value;
  final int highlightedSubIndex;
  final List<FocusNode> focusNodes;
  final List<StepController> stepControllers;
  final ValueChanged<DateTime> onChanged;

  @override
  State<_FormSendSchedulerBody> createState() => _FormSendSchedulerBodyState();
}

class _FormSendSchedulerBodyState extends State<_FormSendSchedulerBody> {
  late DateTime _value;

  @override
  void initState() {
    super.initState();
    _value = widget.value;
  }

  @override
  void didUpdateWidget(_FormSendSchedulerBody old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && widget.value != _value) {
      _value = widget.value;
    }
  }

  void _apply(DateTime next) {
    // Seconds are always zero (minute granularity) and the instant may not be
    // in the past — clamp to the next whole minute.
    var clamped = DateTime(
      next.year,
      next.month,
      next.day,
      next.hour,
      next.minute,
    );
    final now = Time.now();
    if (!clamped.isAfter(now)) {
      clamped = DateTime(now.year, now.month, now.day, now.hour, now.minute)
          .add(const Duration(minutes: 1));
    }
    setState(() => _value = clamped);
    widget.onChanged(clamped);
  }

  FocusNode _node(int i) {
    assert(
      i < widget.focusNodes.length,
      'FormSendScheduler.focusableCount is 2 but only '
      '${widget.focusNodes.length} focus nodes were provided',
    );
    return widget.focusNodes[i];
  }

  StepController _ctrl(int i) => widget.stepControllers[i];

  @override
  Widget build(BuildContext context) {
    final highlight = context.theme.colors.secondary;

    Widget row(int i, IconData icon, Widget content) {
      final ctrl = _ctrl(i);
      return StepperRow(
        focusNode: _node(i),
        highlightColor: widget.highlightedSubIndex == i ? highlight : null,
        onStepBack: () => ctrl.stepBack?.call(),
        onStepForward: () => ctrl.stepForward?.call(),
        onJumpBack: () => ctrl.jumpBack?.call(),
        onJumpForward: () => ctrl.jumpForward?.call(),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.theme.spacing.xl),
          child: IconInputRow(icon: icon, content: content),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row(
          0,
          PlotIcon.event,
          DateInput(
            value: _value,
            onChanged: (date) {
              if (date != null) {
                _apply(
                  DateTime(
                    date.year,
                    date.month,
                    date.day,
                    _value.hour,
                    _value.minute,
                  ),
                );
              }
            },
            stepController: _ctrl(0),
          ),
        ),
        row(
          1,
          PlotIcon.later,
          TimeRangeInput(
            startTime: FTime.fromDateTime(_value),
            onStartTimeChanged: (t) {
              if (t != null) {
                _apply(
                  DateTime(
                    _value.year,
                    _value.month,
                    _value.day,
                    t.hour,
                    t.minute,
                  ),
                );
              }
            },
            onRangeShift: (delta) => _apply(_value.add(delta)),
            stepController: _ctrl(1),
          ),
        ),
      ],
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

    // Match the standard FormModal rows: highlight with the same secondary
    // colour, and inset row content by spacing.xl so the leading icons line up
    // with the priority field and submit button above/below.
    final highlight = context.theme.colors.secondary;

    Widget row(int i, IconData icon, Widget content) {
      final ctrl = _ctrl(i);
      return StepperRow(
        focusNode: _node(i),
        highlightColor: widget.highlightedSubIndex == i ? highlight : null,
        onStepBack: () => ctrl.stepBack?.call(),
        onStepForward: () => ctrl.stepForward?.call(),
        onJumpBack: () => ctrl.jumpBack?.call(),
        onJumpForward: () => ctrl.jumpForward?.call(),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.theme.spacing.xl),
          child: IconInputRow(icon: icon, content: content),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row(
          0,
          PlotIcon.event,
          DateInput(
            value: _range.start,
            onChanged: (date) {
              if (date != null) _apply(withDate(_range, date));
            },
            stepController: _ctrl(0),
          ),
        ),
        row(
          1,
          PlotIcon.later,
          TimeRangeInput(
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
        row(
          2,
          PlotIcon.waiting,
          DurationInput(
            value: _range.duration ?? const Duration(minutes: 30),
            onChanged: (d) => _apply(withDuration(_range, d)),
            stepController: _ctrl(2),
          ),
        ),
      ],
    );
  }
}
