import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'package:plot/util/time.dart';
import 'package:plot/widget/macos/search_field.dart';

class TimePicker extends StatefulWidget {
  const TimePicker({required this.value, required this.onChanged, super.key});

  final TimeOfDay value;
  final void Function(TimeOfDay) onChanged;

  @override
  State<TimePicker> createState() => TimePickerState();
}

class TimePickerState extends State<TimePicker> {
  TextEditingController? _controller;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller = TextEditingController(text: widget.value.format(context));
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 90,
      child: MacosSearchField(
        placeholder: 'HH:MM AM',
        autocorrect: false,
        maxLines: 1,
        textAlign: TextAlign.center,
        onChanged: (str) {
          try {
            final time = parseTimeOfDay(str);
            widget.onChanged(time);
          } catch (e) {
            // ignore
          }
        },
        onBlur: () {
          _controller!.text = widget.value.format(context);
        },
        results: List.generate(96, (index) {
          final hour = index ~/ 4;
          final minute = (index % 4) * 15;
          final time = TimeOfDay(hour: hour, minute: minute);
          return SearchResultItem(time.format(context));
        }),
        controller: _controller,
        inputFormatters: [
          TextInputFormatter.withFunction(
            (TextEditingValue oldValue, TextEditingValue newValue) {
              final text = newValue.text;

              // Handle deletion
              if (text.length < oldValue.text.length) {
                return newValue;
              }

              // Remove any invalid characters
              String sanitizedText =
                  text.replaceAll(RegExp(r"[^0-9: aApPmM]"), '');

              final length = sanitizedText.length;

              if (length > 4) {
                // If longer than valid time (HHMM)
                sanitizedText = sanitizedText.substring(0, 4);
              }

              // Construct the hours and minutes
              String formattedText = sanitizedText;
              if (length >= 3) {
                // Insert colon after hours
                formattedText =
                    '${sanitizedText.substring(0, 2)}:${sanitizedText.substring(2)}';
              }

              // Validation for hour and minutes separately
              if (length >= 2 &&
                  int.tryParse(sanitizedText.substring(0, 2))! > 23) {
                return oldValue; // Invalid hour, retain old value
              }
              if (length >= 4 &&
                  int.tryParse(sanitizedText.substring(2, 4))! > 59) {
                return oldValue; // Invalid minutes, retain old value
              }

              return TextEditingValue(
                text: formattedText,
                // Place the cursor at the end of the input
                selection:
                    TextSelection.collapsed(offset: formattedText.length),
              );
            },
          )
        ],
      ),
    );
  }
}
