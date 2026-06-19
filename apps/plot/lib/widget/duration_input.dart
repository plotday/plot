import 'package:flutter/material.dart' show OutlineInputBorder;
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/button.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/widget/step_controller.dart';
import 'package:plot/widget/text_field_selection_theme.dart';

/// A compound input widget for editing durations with +/- buttons and separate hour/minute fields.
///
/// Provides:
/// - Left "-" button (decreases by 15 minutes)
/// - Hour TextField with 'h' suffix
/// - Minute TextField with 'm' suffix
/// - Right "+" button (increases by 15 minutes)
/// - All wrapped in a common outline border
///
/// Supports flexible input parsing (e.g., '90', '1.5h', '2h 30m') and clamps values
/// to a minimum of 5 minutes and maximum of 24 hours.
class DurationInput extends StatefulWidget {
  const DurationInput({
    required this.value,
    required this.onChanged,
    this.focusNode,
    this.minutesFocusNode,
    this.autofocus = false,
    this.backgroundColor,
    this.stepController,
    super.key,
  });

  /// The current duration value.
  final Duration value;

  /// Called when the duration changes.
  final ValueChanged<Duration> onChanged;

  /// Optional focus node for the hour field.
  final FocusNode? focusNode;

  /// Optional focus node for the minute field.
  final FocusNode? minutesFocusNode;

  /// Whether to autofocus the hour field.
  final bool autofocus;

  /// Optional background color for the container.
  final Color? backgroundColor;

  /// Optional hook exposing the +/- step actions for external (keyboard) drivers.
  final StepController? stepController;

  @override
  State<DurationInput> createState() => _DurationInputState();
}

class _DurationInputState extends State<DurationInput> {
  late TextEditingController _hoursController;
  late TextEditingController _minutesController;
  late FocusNode _hoursFocusNode;
  late FocusNode _minutesFocusNode;

  bool _updating = false;

  static const Duration _minDuration = Duration(minutes: 5);
  static const Duration _maxDuration = Duration(hours: 24);
  static const Duration _incrementAmount = Duration(minutes: 15);

  @override
  void initState() {
    super.initState();
    _hoursFocusNode = widget.focusNode ?? FocusNode();
    _minutesFocusNode = widget.minutesFocusNode ?? FocusNode();

    final (hours, minutes) = _splitDuration(widget.value);
    _hoursController = TextEditingController(text: hours.toString());
    _minutesController = TextEditingController(
      text: minutes.toString().padLeft(2, '0'),
    );

    _hoursController.addListener(_onHoursChanged);
    _minutesController.addListener(_onMinutesChanged);
  }

  @override
  void dispose() {
    _hoursController.dispose();
    _minutesController.dispose();
    if (widget.focusNode == null) {
      _hoursFocusNode.dispose();
    }
    if (widget.minutesFocusNode == null) {
      _minutesFocusNode.dispose();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(DurationInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !_updating) {
      _updateFromValue();
    }
  }

  void _updateFromValue() {
    _updating = true;
    try {
      final (hours, minutes) = _splitDuration(widget.value);
      _hoursController.text = hours.toString();
      _minutesController.text = minutes.toString().padLeft(2, '0');
    } finally {
      _updating = false;
    }
  }

  /// Splits a duration into hours and minutes.
  (int hours, int minutes) _splitDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    return (hours, minutes);
  }

  /// Parses the hour and minute text fields into a Duration.
  /// Supports flexible parsing like "1.5" for hours or "90" for minutes.
  Duration? _parseDuration() {
    final hoursText = _hoursController.text.trim();
    final minutesText = _minutesController.text.trim();

    int totalMinutes = 0;

    // Parse hours (supports decimals like "1.5")
    if (hoursText.isNotEmpty) {
      final hoursValue = double.tryParse(hoursText);
      if (hoursValue != null) {
        totalMinutes += (hoursValue * 60).round();
      }
    }

    // Parse minutes
    if (minutesText.isNotEmpty) {
      final minutesValue = int.tryParse(minutesText);
      if (minutesValue != null) {
        totalMinutes += minutesValue;
      }
    }

    if (totalMinutes == 0) return null;

    return _clampDuration(Duration(minutes: totalMinutes));
  }

  /// Clamps a duration to the min/max bounds.
  Duration _clampDuration(Duration duration) {
    if (duration < _minDuration) return _minDuration;
    if (duration > _maxDuration) return _maxDuration;
    return duration;
  }

  void _onHoursChanged() {
    if (_updating) return;
    final duration = _parseDuration();
    if (duration != null) {
      _updateDuration(duration);
    }
  }

  void _onMinutesChanged() {
    if (_updating) return;
    final duration = _parseDuration();
    if (duration != null) {
      _updateDuration(duration);
    }
  }

  void _increment15Minutes() {
    final currentDuration = _parseDuration() ?? widget.value;
    final newDuration = _clampDuration(currentDuration + _incrementAmount);
    _updateDuration(newDuration);
  }

  void _decrement15Minutes() {
    final currentDuration = _parseDuration() ?? widget.value;
    final newDuration = _clampDuration(currentDuration - _incrementAmount);
    _updateDuration(newDuration);
  }

  void _incrementHour() {
    final currentDuration = _parseDuration() ?? widget.value;
    final newDuration = _clampDuration(
      currentDuration + const Duration(hours: 1),
    );
    _updateDuration(newDuration);
  }

  void _decrementHour() {
    final currentDuration = _parseDuration() ?? widget.value;
    final newDuration = _clampDuration(
      currentDuration - const Duration(hours: 1),
    );
    _updateDuration(newDuration);
  }

  void _updateDuration(Duration duration) {
    _updating = true;
    try {
      widget.onChanged(duration);
      // Update text fields immediately to show the new value
      final (hours, minutes) = _splitDuration(duration);
      _hoursController.text = hours.toString();
      _minutesController.text = minutes.toString().padLeft(2, '0');
    } finally {
      _updating = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    widget.stepController
      ?..stepBack = _decrement15Minutes
      ..stepForward = _increment15Minutes
      ..jumpBack = _decrementHour
      ..jumpForward = _incrementHour
      ..focusEditor = _hoursFocusNode.requestFocus;
    final theme = context.theme;

    return Row(
      children: [
        // Double left chevron (decrease 1 hour)
        _buildButton(
          icon: FontAwesomeIcons.chevronsLeft,
          onPressed: _decrementHour,
          theme: theme,
        ),
        // Single left chevron (decrease 15 minutes)
        _buildButton(
          icon: FontAwesomeIcons.chevronLeft,
          onPressed: _decrement15Minutes,
          theme: theme,
        ),

        // Centered input fields group
        Expanded(
          child: Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Hours field with 'h' suffix
                SizedBox(
                  width: 48,
                  child: _buildTextField(
                    controller: _hoursController,
                    focusNode: _hoursFocusNode,
                    suffix: 'h',
                    autofocus: widget.autofocus,
                    theme: theme,
                  ),
                ),
                const SizedBox(width: 4),
                // Minutes field with 'm' suffix
                SizedBox(
                  width: 48,
                  child: _buildTextField(
                    controller: _minutesController,
                    focusNode: _minutesFocusNode,
                    suffix: 'm',
                    autofocus: false,
                    theme: theme,
                  ),
                ),
              ],
            ),
          ),
        ),

        // Single right chevron (increase 15 minutes)
        _buildButton(
          icon: FontAwesomeIcons.chevronRight,
          onPressed: _increment15Minutes,
          theme: theme,
        ),
        // Double right chevron (increase 1 hour)
        _buildButton(
          icon: FontAwesomeIcons.chevronsRight,
          onPressed: _incrementHour,
          theme: theme,
        ),
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
      style: stepperButtonStyleDelta(),
      onPress: onPressed,
      child: Icon(icon, size: theme.iconSizes.sm),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required FocusNode focusNode,
    required String suffix,
    required bool autofocus,
    required FThemeData theme,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: FTextField(
            builder: fieldSelectionBuilder,
            control: .managed(controller: controller), focusNode: focusNode,
            autofocus: autofocus,
            textAlign: TextAlign.center,
            style: FTextFieldStyleDelta.delta(
              contentPadding: EdgeInsetsGeometryDelta.value(
                const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 8,
                ),
              ),
              // Borderless inline field: opt out of the global filled
              // appearance (bordered fields fill with editableBackground in
              // every state) so the surrounding surface shows through.
              color: FVariantsValueDelta.delta([
                FVariantValueDeltaOperation.all(const Color(0x00000000)),
              ]),
              border: FVariantsValueDelta.delta([
                FVariantValueDeltaOperation.all(
                  const OutlineInputBorder(
                    borderSide: BorderSide(
                      width: 0,
                      style: BorderStyle.none,
                    ),
                  ),
                ),
              ]),
            ),
            inputFormatters: [
              // Allow digits and decimal point for flexible input
              FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
            ],
            suffixBuilder: (_, _, _) => Text(
              suffix,
              style: theme.typography.sm.copyWith(
                color: theme.colors.mutedForeground,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
