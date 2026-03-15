import 'package:flutter/material.dart' show OutlineInputBorder;
import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/util/platform.dart';

/// A compound input widget for selecting a time range with chevron navigation.
///
/// Provides:
/// - Double left chevron (shift range -1 hour)
/// - Single left chevron (shift range -15 minutes)
/// - Start time field
/// - En dash separator
/// - End time field
/// - Single right chevron (shift range +15 minutes)
/// - Double right chevron (shift range +1 hour)
/// - All wrapped in a common outline border
class TimeRangeInput extends StatefulWidget {
  const TimeRangeInput({
    required this.startTime,
    required this.endTime,
    required this.onStartTimeChanged,
    required this.onEndTimeChanged,
    required this.onRangeShift,
    this.startTimeFocusNode,
    this.endTimeFocusNode,
    this.autofocus = false,
    this.backgroundColor,
    super.key,
  });

  /// The current start time value.
  final FTime? startTime;

  /// The current end time value.
  final FTime? endTime;

  /// Called when the start time changes.
  final ValueChanged<FTime?> onStartTimeChanged;

  /// Called when the end time changes.
  final ValueChanged<FTime?> onEndTimeChanged;

  /// Called when the time range should be shifted by a duration.
  final ValueChanged<Duration> onRangeShift;

  /// Optional focus node for the start time field.
  final FocusNode? startTimeFocusNode;

  /// Optional focus node for the end time field.
  final FocusNode? endTimeFocusNode;

  /// Whether to autofocus the start time field.
  final bool autofocus;

  /// Optional background color for the container.
  final Color? backgroundColor;

  @override
  State<TimeRangeInput> createState() => _TimeRangeInputState();
}

class _TimeRangeInputState extends State<TimeRangeInput>
    with TickerProviderStateMixin {
  late FocusNode _startTimeFocusNode;
  late FocusNode _endTimeFocusNode;

  @override
  void initState() {
    super.initState();
    _startTimeFocusNode = widget.startTimeFocusNode ?? FocusNode();
    _endTimeFocusNode = widget.endTimeFocusNode ?? FocusNode();
  }

  @override
  void dispose() {
    if (widget.startTimeFocusNode == null) {
      _startTimeFocusNode.dispose();
    }
    if (widget.endTimeFocusNode == null) {
      _endTimeFocusNode.dispose();
    }
    super.dispose();
  }

  void _shiftLeft15() {
    final startTime = widget.startTime ?? FTime.now();
    final minutes = startTime.minute;

    if (minutes % 15 != 0) {
      // Not on a 15-minute boundary - snap down to previous 15-minute mark
      final snappedMinutes = (minutes ~/ 15) * 15;
      final delta = minutes - snappedMinutes;
      widget.onRangeShift(Duration(minutes: -delta));
    } else {
      // On a 15-minute boundary - subtract 15 minutes
      widget.onRangeShift(const Duration(minutes: -15));
    }
  }

  void _shiftRight15() {
    final startTime = widget.startTime ?? FTime.now();
    final minutes = startTime.minute;

    if (minutes % 15 != 0) {
      // Not on a 15-minute boundary - snap up to next 15-minute mark
      final snappedMinutes = ((minutes ~/ 15) + 1) * 15;
      final delta = snappedMinutes - minutes;
      widget.onRangeShift(Duration(minutes: delta));
    } else {
      // On a 15-minute boundary - add 15 minutes
      widget.onRangeShift(const Duration(minutes: 15));
    }
  }

  void _shiftLeft1Hour() {
    final startTime = widget.startTime ?? FTime.now();
    final minutes = startTime.minute;

    if (minutes % 15 == 0) {
      // On a 15-minute boundary - subtract 1 hour
      widget.onRangeShift(const Duration(hours: -1));
    } else {
      // Not on a 15-minute boundary - snap down to nearest 30-minute mark
      final snappedMinutes = minutes < 30 ? 0 : 30;
      final delta = minutes - snappedMinutes;
      widget.onRangeShift(Duration(minutes: -delta));
    }
  }

  void _shiftRight1Hour() {
    final startTime = widget.startTime ?? FTime.now();
    final minutes = startTime.minute;

    if (minutes % 15 == 0) {
      // On a 15-minute boundary - add 1 hour
      widget.onRangeShift(const Duration(hours: 1));
    } else {
      // Not on a 15-minute boundary - snap up to nearest 30-minute mark
      final snappedMinutes = minutes < 30 ? 30 : 60;
      final delta = snappedMinutes - minutes;
      widget.onRangeShift(Duration(minutes: delta));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final isTouch = !hasPhysicalKeyboard();

    return Row(
      children: [
        SizedBox(width: theme.spacing.md),
        // Double left chevron (shift range -1 hour or snap to 30-min)
        _buildButton(
          icon: FontAwesomeIcons.chevronsLeft,
          onPressed: _shiftLeft1Hour,
          theme: theme,
        ),
        // Single left chevron (shift range -15 min or snap to 15-min)
        _buildButton(
          icon: FontAwesomeIcons.chevronLeft,
          onPressed: _shiftLeft15,
          theme: theme,
        ),

        // Centered time fields group
        Expanded(
          child: Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Start time field
                Flexible(
                  child: isTouch
                      ? FTimeField.picker(
                          control: .lifted(
                            time: widget.startTime,
                            onChange: widget.onStartTimeChanged,
                          ),
                          focusNode: _startTimeFocusNode,
                          prefixBuilder: null,
                          textAlign: TextAlign.right,
                          style: FTimeFieldStyleDelta.delta(
                            fieldStyles: FVariantsDelta.delta([
                              FVariantOperation.all(
                                FTextFieldStyleDelta.delta(
                                  contentPadding: EdgeInsetsGeometryDelta.value(
                                    EdgeInsets.symmetric(
                                      horizontal: theme.spacing.sm,
                                      vertical: theme.spacing.md,
                                    ),
                                  ),
                                  border: FVariantsValueDelta.delta([
                                    FVariantValueDeltaOperation.all(
                                      OutlineInputBorder(
                                        borderSide: const BorderSide(
                                          width: 0,
                                          style: BorderStyle.none,
                                        ),
                                        borderRadius: BorderRadius.zero,
                                      ),
                                    ),
                                  ]),
                                ),
                              ),
                            ]),
                          ),
                          builder: (context, style, states, child) => child,
                        )
                      : FTimeField(
                          control: .lifted(
                            time: widget.startTime,
                            onChange: widget.onStartTimeChanged,
                          ),
                          focusNode: _startTimeFocusNode,
                          prefixBuilder: null,
                          textAlign: TextAlign.right,
                          style: FTimeFieldStyleDelta.delta(
                            fieldStyles: FVariantsDelta.delta([
                              FVariantOperation.all(
                                FTextFieldStyleDelta.delta(
                                  contentPadding: EdgeInsetsGeometryDelta.value(
                                    EdgeInsets.symmetric(
                                      horizontal: theme.spacing.sm,
                                      vertical: theme.spacing.md,
                                    ),
                                  ),
                                  border: FVariantsValueDelta.delta([
                                    FVariantValueDeltaOperation.all(
                                      OutlineInputBorder(
                                        borderSide: const BorderSide(
                                          width: 0,
                                          style: BorderStyle.none,
                                        ),
                                        borderRadius: BorderRadius.zero,
                                      ),
                                    ),
                                  ]),
                                ),
                              ),
                            ]),
                          ),
                          builder: (context, style, states, child) => child,
                        ),
                ),
                // En dash separator
                Text(
                  '–',
                  style: theme.typography.sm.copyWith(
                    color: theme.colors.mutedForeground,
                    height: 1.0,
                  ),
                ),
                // End time field
                Flexible(
                  child: isTouch
                      ? FTimeField.picker(
                          control: .lifted(
                            time: widget.endTime,
                            onChange: widget.onEndTimeChanged,
                          ),
                          focusNode: _endTimeFocusNode,
                          prefixBuilder: null,
                          textAlign: TextAlign.left,
                          style: FTimeFieldStyleDelta.delta(
                            fieldStyles: FVariantsDelta.delta([
                              FVariantOperation.all(
                                FTextFieldStyleDelta.delta(
                                  contentPadding: EdgeInsetsGeometryDelta.value(
                                    EdgeInsets.symmetric(
                                      horizontal: theme.spacing.sm,
                                      vertical: theme.spacing.md,
                                    ),
                                  ),
                                  border: FVariantsValueDelta.delta([
                                    FVariantValueDeltaOperation.all(
                                      OutlineInputBorder(
                                        borderSide: const BorderSide(
                                          width: 0,
                                          style: BorderStyle.none,
                                        ),
                                        borderRadius: BorderRadius.zero,
                                      ),
                                    ),
                                  ]),
                                ),
                              ),
                            ]),
                          ),
                          builder: (context, style, states, child) => child,
                        )
                      : FTimeField(
                          control: .lifted(
                            time: widget.endTime,
                            onChange: widget.onEndTimeChanged,
                          ),
                          focusNode: _endTimeFocusNode,
                          prefixBuilder: null,
                          textAlign: TextAlign.left,
                          style: FTimeFieldStyleDelta.delta(
                            fieldStyles: FVariantsDelta.delta([
                              FVariantOperation.all(
                                FTextFieldStyleDelta.delta(
                                  contentPadding: EdgeInsetsGeometryDelta.value(
                                    EdgeInsets.symmetric(
                                      horizontal: theme.spacing.sm,
                                      vertical: theme.spacing.md,
                                    ),
                                  ),
                                  border: FVariantsValueDelta.delta([
                                    FVariantValueDeltaOperation.all(
                                      OutlineInputBorder(
                                        borderSide: const BorderSide(
                                          width: 0,
                                          style: BorderStyle.none,
                                        ),
                                        borderRadius: BorderRadius.zero,
                                      ),
                                    ),
                                  ]),
                                ),
                              ),
                            ]),
                          ),
                          builder: (context, style, states, child) => child,
                        ),
                ),
              ],
            ),
          ),
        ),

        // Single right chevron (shift range +15 min or snap to 15-min)
        _buildButton(
          icon: FontAwesomeIcons.chevronRight,
          onPressed: _shiftRight15,
          theme: theme,
        ),
        // Double right chevron (shift range +1 hour or snap to 30-min)
        _buildButton(
          icon: FontAwesomeIcons.chevronsRight,
          onPressed: _shiftRight1Hour,
          theme: theme,
        ),
        SizedBox(width: theme.spacing.md),
      ],
    );
  }

  Widget _buildButton({
    required IconData icon,
    required VoidCallback onPressed,
    required FThemeData theme,
  }) {
    return FButton(
      variant: FButtonVariant.ghost,
      onPress: onPressed,
      child: Icon(icon, size: theme.iconSizes.sm),
    );
  }
}
