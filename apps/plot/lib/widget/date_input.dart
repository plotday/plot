import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';
import 'package:intl/intl.dart';

/// A compound input widget for selecting dates with chevron navigation.
///
/// Provides:
/// - Double left chevron (back one week)
/// - Single left chevron (back one day)
/// - Date field with calendar picker
/// - Single right chevron (forward one day)
/// - Double right chevron (forward one week)
/// - All wrapped in a common outline border
class DateInput extends StatefulWidget {
  const DateInput({
    required this.controller,
    this.focusNode,
    this.autofocus = false,
    this.backgroundColor,
    super.key,
  });

  /// The date field controller.
  final FDateFieldController controller;

  /// Optional focus node for the date field.
  final FocusNode? focusNode;

  /// Whether to autofocus the date field.
  final bool autofocus;

  /// Optional background color for the container.
  final Color? backgroundColor;

  @override
  State<DateInput> createState() => _DateInputState();
}

class _DateInputState extends State<DateInput> {
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
  }

  @override
  void dispose() {
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  void _navigateDate(int days) {
    final currentDate = widget.controller.value ?? DateTime.now();
    final newDate = currentDate.add(Duration(days: days));

    // Prevent navigating to past dates
    final today = DateTime.now();
    final todayStart = DateTime(today.year, today.month, today.day);
    final newDateStart = DateTime(newDate.year, newDate.month, newDate.day);

    if (newDateStart.isBefore(todayStart)) {
      return;
    }

    widget.controller.value = newDate;
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;

    return Row(
      children: [
        const SizedBox(width: 8),
        // Double left chevron (back one week)
        _buildButton(
          icon: FontAwesomeIcons.chevronsLeft,
          onPressed: () => _navigateDate(-7),
          theme: theme,
        ),
        // Single left chevron (back one day)
        _buildButton(
          icon: FontAwesomeIcons.chevronLeft,
          onPressed: () => _navigateDate(-1),
          theme: theme,
        ),
        const SizedBox(width: 8),
        // Date field
        Expanded(
          child: FDateField.calendar(
            controller: widget.controller,
            focusNode: _focusNode,
            format: DateFormat.yMMMEd(),
            textAlign: TextAlign.center,
            prefixBuilder: null,
            start: DateTime.now(),
            style: (style) {
              final textField = style.textFieldStyle.copyWith(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 8,
                ),
                border: style.textFieldStyle.border.map(
                  (borderStyle) => borderStyle.copyWith(
                    borderSide: const BorderSide(
                      width: 0,
                      style: BorderStyle.none,
                    ),
                  ),
                ),
              );
              return style.copyWith(textFieldStyle: textField);
            },
            builder: (context, style, states, child) => child,
          ),
        ),
        const SizedBox(width: 8),
        // Single right chevron (forward one day)
        _buildButton(
          icon: FontAwesomeIcons.chevronRight,
          onPressed: () => _navigateDate(1),
          theme: theme,
        ),
        // Double right chevron (forward one week)
        _buildButton(
          icon: FontAwesomeIcons.chevronsRight,
          onPressed: () => _navigateDate(7),
          theme: theme,
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildButton({
    required IconData icon,
    required VoidCallback onPressed,
    required FThemeData theme,
  }) {
    return FButton(
      style: (style) => theme.buttonStyles.ghost,
      onPress: onPressed,
      child: Icon(icon, size: 14),
    );
  }
}
