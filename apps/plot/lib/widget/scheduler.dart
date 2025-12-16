import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/util/time.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/icon_input_row.dart';
import 'package:plot/widget/duration_input.dart';
import 'package:plot/widget/date_input.dart';
import 'package:plot/widget/time_range_input.dart';

/// A scheduler widget for selecting a date, start time, duration, and end time.
///
/// Uses platform-adaptive field selection:
/// - Touch devices: FDateField.calendar() and FTimeField.picker()
/// - Non-touch devices: FDateField.input() and FTimeField.new()
///
/// Supports bidirectional synchronization between start time, duration, and end time.
///
/// ## Usage in a Modal
///
/// ```dart
/// final modal = Modal(
///   header: Text('Schedule Activity'),
///   constraints: BoxConstraints(maxHeight: 500, maxWidth: 750),
///   builder: (context) {
///     DateTimeRange range = DateTimeRange(
///       DateTime.now(),
///       DateTime.now().add(Duration(hours: 1)),
///     );
///
///     return Scheduler(
///       value: range,
///       onChanged: (newRange) {
///         range = newRange;
///       },
///     );
///   },
/// );
///
/// final result = await modal.show<DateTimeRange>(context);
/// if (result.present) {
///   final selectedRange = result.value;
///   // Use the selected range
/// }
/// ```
///
/// ## Usage in a Page
///
/// ```dart
/// class SchedulingPage extends StatefulWidget {
///   @override
///   State<SchedulingPage> createState() => _SchedulingPageState();
/// }
///
/// class _SchedulingPageState extends State<SchedulingPage> {
///   late DateTimeRange _range;
///
///   @override
///   void initState() {
///     super.initState();
///     _range = DateTimeRange(
///       DateTime.now(),
///       DateTime.now().add(Duration(hours: 1)),
///     );
///   }
///
///   @override
///   Widget build(BuildContext context) {
///     return Column(
///       children: [
///         Scheduler(
///           value: _range,
///           onChanged: (newRange) {
///             setState(() {
///               _range = newRange;
///             });
///             // Save or update activity with new range
///           },
///         ),
///       ],
///     );
///   }
/// }
/// ```
class Scheduler extends StatefulWidget {
  /// Creates a scheduler widget.
  const Scheduler({
    required this.value,
    required this.onChanged,
    this.onClose,
    this.allowPastTimes = false,
    super.key,
  });

  /// The current date/time range value.
  final DateTimeRange value;

  /// Called when the date/time range changes.
  final ValueChanged<DateTimeRange> onChanged;

  /// Called when the close button is pressed.
  final VoidCallback? onClose;

  /// Whether to allow scheduling times in the past.
  ///
  /// When false (default), the scheduler will automatically adjust past times to the current time.
  /// When true, past times are preserved, useful for rescheduling existing events.
  final bool allowPastTimes;

  @override
  State<Scheduler> createState() => _SchedulerState();
}

class _SchedulerState extends State<Scheduler> with TickerProviderStateMixin {
  late FDateFieldController _dateController;
  late FTimeFieldController _startTimeController;
  late FTimeFieldController _endTimeController;

  final FocusNode _dateFocusNode = FocusNode();
  final FocusNode _startTimeFocusNode = FocusNode();
  final FocusNode _endTimeFocusNode = FocusNode();
  final FocusNode _durationHoursFocusNode = FocusNode();
  final FocusNode _durationMinutesFocusNode = FocusNode();

  // Track whether we're currently updating to prevent circular updates
  bool _updating = false;

  @override
  void initState() {
    super.initState();

    // Initialize date controller
    _dateController = FDateFieldController(
      vsync: this,
      initialDate: widget.value.start,
    );

    // Initialize time controllers
    final startTime = widget.value.start != null
        ? FTime.fromDateTime(widget.value.start!)
        : FTime.now();
    final endTime = widget.value.end != null
        ? FTime.fromDateTime(widget.value.end!)
        : FTime.fromDateTime(DateTime.now().add(const Duration(hours: 1)));

    _startTimeController = FTimeFieldController(
      vsync: this,
      initialTime: startTime,
    );

    _endTimeController = FTimeFieldController(
      vsync: this,
      initialTime: endTime,
    );

    // Add listeners
    _dateController.addValueListener(_onDateChanged);
    _startTimeController.addValueListener(_onStartTimeChanged);
    _endTimeController.addValueListener(_onEndTimeChanged);

    // Add focus listeners to rebuild when focus changes
    _durationHoursFocusNode.addListener(() => setState(() {}));
    _durationMinutesFocusNode.addListener(() => setState(() {}));

    // Validate initial value and correct if in the past
    final validatedRange = _validateRange(widget.value);
    if (validatedRange != widget.value) {
      // Schedule the callback after the current frame to avoid calling setState during build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onChanged(validatedRange);
      });
    }
  }

  @override
  void dispose() {
    _dateController.dispose();
    _startTimeController.dispose();
    _endTimeController.dispose();
    _dateFocusNode.dispose();
    _startTimeFocusNode.dispose();
    _endTimeFocusNode.dispose();
    _durationHoursFocusNode.dispose();
    _durationMinutesFocusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(Scheduler oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !_updating) {
      _updateFromValue();
    }
  }

  void _updateFromValue() {
    _updating = true;
    try {
      if (widget.value.start != null) {
        _dateController.value = widget.value.start;
        _startTimeController.value = FTime.fromDateTime(widget.value.start!);
      }
      if (widget.value.end != null) {
        _endTimeController.value = FTime.fromDateTime(widget.value.end!);
      }
    } finally {
      _updating = false;
    }
  }

  void _onDateChanged(DateTime? date) {
    if (_updating || date == null) return;
    _recalculateRange(newDate: date);
  }

  void _onStartTimeChanged(FTime? time) {
    if (_updating || time == null) return;
    _recalculateRange(newStartTime: time);
  }

  void _onEndTimeChanged(FTime? time) {
    if (_updating || time == null) return;
    _recalculateRange(newEndTime: time);
  }

  void _onDurationChanged(Duration duration) {
    if (_updating) return;
    _recalculateRange(newDuration: duration);
  }

  void _navigateTimeRange(Duration delta) {
    final startTime = _startTimeController.value ?? FTime.now();
    final endTime = _endTimeController.value ?? FTime.now();
    final currentDate = _dateController.value ?? DateTime.now();

    // Convert to DateTime for easier calculation
    var startDateTime = DateTime(
      currentDate.year,
      currentDate.month,
      currentDate.day,
      startTime.hour,
      startTime.minute,
    );

    var endDateTime = DateTime(
      currentDate.year,
      currentDate.month,
      currentDate.day,
      endTime.hour,
      endTime.minute,
    );

    // Add delta to both times
    startDateTime = startDateTime.add(delta);
    endDateTime = endDateTime.add(delta);

    // Prevent scheduling in the past (unless explicitly allowed)
    if (!widget.allowPastTimes) {
      final now = DateTime.now();
      if (startDateTime.isBefore(now)) {
        final adjustment = now.difference(startDateTime);
        startDateTime = now;
        endDateTime = endDateTime.add(adjustment);
      }
    }

    // Update controllers
    _updating = true;
    try {
      _dateController.value = startDateTime;
      _startTimeController.value = FTime.fromDateTime(startDateTime);
      _endTimeController.value = FTime.fromDateTime(endDateTime);
    } finally {
      _updating = false;
    }

    // Recalculate the range
    _recalculateRange(
      newDate: startDateTime,
      newStartTime: FTime.fromDateTime(startDateTime),
      newEndTime: FTime.fromDateTime(endDateTime),
    );
  }

  void _recalculateRange({
    DateTime? newDate,
    FTime? newStartTime,
    FTime? newEndTime,
    Duration? newDuration,
  }) {
    _updating = true;
    try {
      // Get current values
      DateTime date = newDate ?? _dateController.value ?? DateTime.now();
      FTime startTime =
          newStartTime ?? _startTimeController.value ?? FTime.now();

      // Build start DateTime
      DateTime start = DateTime(
        date.year,
        date.month,
        date.day,
        startTime.hour,
        startTime.minute,
      );

      // Calculate end DateTime
      DateTime end;
      if (newDuration != null) {
        // Duration changed, calculate end time
        end = start.add(newDuration);
        _endTimeController.value = FTime.fromDateTime(end);
      } else if (newEndTime != null) {
        // End time changed, calculate duration
        end = DateTime(
          date.year,
          date.month,
          date.day,
          newEndTime.hour,
          newEndTime.minute,
        );

        // Handle day boundary crossing
        if (end.isBefore(start)) {
          end = end.add(const Duration(days: 1));
        }
      } else {
        // Date or start time changed, maintain duration
        final currentDuration =
            widget.value.duration ?? const Duration(hours: 1);
        end = start.add(currentDuration);
        _endTimeController.value = FTime.fromDateTime(end);
      }

      // Validate and notify
      final newRange = DateTimeRange(start, end);
      final validatedRange = _validateRange(newRange);
      widget.onChanged(validatedRange);
    } finally {
      _updating = false;
    }
  }

  DateTimeRange _validateRange(DateTimeRange range) {
    if (range.start == null || range.end == null) {
      return range;
    }

    DateTime start = range.start!;
    DateTime end = range.end!;
    final now = DateTime.now();

    // Prevent past scheduling (unless explicitly allowed)
    if (!widget.allowPastTimes && start.isBefore(now)) {
      start = now;
      end = start.add(const Duration(hours: 1));

      // Update controllers to reflect corrected values
      _updating = true;
      try {
        _dateController.value = start;
        _startTimeController.value = FTime.fromDateTime(start);
        _endTimeController.value = FTime.fromDateTime(end);
      } finally {
        _updating = false;
      }
    }

    // Ensure end > start with minimum duration
    final minDuration = const Duration(minutes: 15);
    if (end.isBefore(start) || end.difference(start) < minDuration) {
      end = start.add(minDuration);

      // Update end time controller to reflect corrected value
      _updating = true;
      try {
        _endTimeController.value = FTime.fromDateTime(end);
      } finally {
        _updating = false;
      }
    }

    return DateTimeRange(start, end);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Duration field
        IconInputRow(
          icon: PlotIcon.waiting,
          content: DurationInput(
            value: widget.value.duration ?? const Duration(hours: 1),
            onChanged: _onDurationChanged,
            focusNode: _durationHoursFocusNode,
            minutesFocusNode: _durationMinutesFocusNode,
            backgroundColor:
                (_durationHoursFocusNode.hasFocus ||
                    _durationMinutesFocusNode.hasFocus)
                ? theme.plotColors.editableBackground
                : null,
          ),
        ),

        // Date field with navigation
        IconInputRow(
          icon: PlotIcon.event,
          content: DateInput(
            controller: _dateController,
            focusNode: _dateFocusNode,
            backgroundColor: _dateFocusNode.hasFocus
                ? theme.plotColors.editableBackground
                : null,
          ),
        ),

        // Combined time fields (start and end)
        IconInputRow(
          icon: PlotIcon.later,
          content: TimeRangeInput(
            startTime: _startTimeController.value,
            endTime: _endTimeController.value,
            onStartTimeChanged: (time) {
              if (time != null) {
                _startTimeController.value = time;
              }
            },
            onEndTimeChanged: (time) {
              if (time != null) {
                _endTimeController.value = time;
              }
            },
            onRangeShift: _navigateTimeRange,
            startTimeFocusNode: _startTimeFocusNode,
            endTimeFocusNode: _endTimeFocusNode,
            backgroundColor:
                (_startTimeFocusNode.hasFocus || _endTimeFocusNode.hasFocus)
                ? theme.plotColors.editableBackground
                : null,
          ),
        ),
      ],
    );
  }
}
