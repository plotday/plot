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
  late TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _focusNode.addListener(() {
      if (_focusNode.hasFocus) {
        // Select all text when the TextField gains focus
        _controller.selection =
            TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
      }
    });
  }

  @override
  void didUpdateWidget(covariant TimePicker oldWidget) {
    if (oldWidget.value != widget.value) {
      _controller.text = widget.value.format(context);
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.text = widget.value.format(context);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
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
            print("Invalid time: $str");
            print(e);
            // ignore
          }
        },
        onResultSelected: (result) {
          try {
            final time = parseTimeOfDay(result.searchKey);
            widget.onChanged(time);
          } catch (e) {
            print(e);
            // ignore
          }
        },
        results: List.generate(96, (index) {
          final hour = index ~/ 4;
          final minute = (index % 4) * 15;
          final time = TimeOfDay(hour: hour, minute: minute);
          return SearchResultItem(time.format(context));
        }),
        controller: _controller,
        focusNode: _focusNode,
        inputFormatters: [
          TextInputFormatter.withFunction(
            (TextEditingValue oldValue, TextEditingValue newValue) {
              // If the new value is empty, return it as-is
              if (newValue.text.isEmpty) {
                return newValue;
              }

              // Normalize the input by removing non-numeric and non-colon characters
              String cleanedText = newValue.text
                  .replaceAll(RegExp(r'[^0-9:apmAPM ]'), '')
                  .toLowerCase();

              cleanedText = cleanedText
                  .replaceAll(RegExp(r'[ap]m?'), '')
                  .replaceAll(RegExp(r'::*'), ':');

              // Split hours and minutes
              List<String> parts = cleanedText.split(':');

              // Handle cases with or without colon
              String hours = parts.isNotEmpty ? parts[0] : '';
              String minutes = parts.length > 1 ? parts[1] : '';

              // Validate and adjust hours
              int? hourValue = int.tryParse(hours);
              if (hourValue != null && hourValue > 23) {
                hourValue = 12;
              }

              // Validate minutes input
              int minuteValue = 0;
              if (minutes.isNotEmpty) {
                minuteValue = int.parse(minutes.padRight(2, '0'));
                if (minuteValue > 59) {
                  minuteValue = 0;
                }
              }

              // Determine AM/PM
              // Default to PM except for hours 8, 9, 10, 11
              bool isPM = newValue.text.contains('p') ||
                  !newValue.text.contains('a') &&
                      hourValue != null &&
                      (hourValue >= 12 || hourValue <= 8);
              if (hourValue != null && hourValue > 12) {
                hourValue %= 12;
              }

              // Construct formatted time
              String formattedTime =
                  '${hourValue ?? ''}:${minuteValue.toString().padLeft(2, '0')} ${isPM ? 'PM' : 'AM'}';

              // Calculate selection
              int selectionStart = formattedTime.length;

              if (hourValue == null) {
                print("Case 0");
                return TextEditingValue(
                  text: formattedTime,
                  selection: const TextSelection.collapsed(offset: 0),
                );
              } else if ((hours.length == 1 &&
                  hourValue < 3 &&
                  (!newValue.text.contains(':') ||
                      newValue.text.indexOf(':') >=
                          newValue.selection.baseOffset))) {
                print("Case 1");
                // Place cursor at the end of the hours
                selectionStart = hours.length;
              } else if (minutes.isEmpty ||
                  newValue.text.indexOf(':') >= newValue.selection.baseOffset) {
                print("Case 2");
                selectionStart = hours.length + 1;
              } else if (minutes.length == 1 ||
                  newValue.text
                              .lastIndexOf(':', newValue.selection.baseOffset) -
                          newValue.selection.baseOffset <=
                      1) {
                print("Case 3 ($hours) ($minutes)");
                selectionStart = hours.length + 1 + minutes.length;
              } else if (minutes.length == 2) {
                print("Case 4");
                // Select AM/PM
                selectionStart = hours.length + 1 + minutes.length + 1;
              }
              int selectionEnd = formattedTime.length;

              print("${oldValue.text} -> "
                  "${newValue.text} (${newValue.selection.baseOffset}, ${newValue.selection.extentOffset}) -> "
                  "$formattedTime ($selectionStart, $selectionEnd)");

              return TextEditingValue(
                  text: formattedTime,
                  selection: TextSelection(
                      baseOffset: selectionStart, extentOffset: selectionEnd));
            },
          )
        ],
      ),
    );
  }
}
//→

class TimeRangePicker extends StatelessWidget {
  const TimeRangePicker(
      {required this.value, required this.onChanged, super.key});

  final DateTimeRange value;
  final void Function(DateTimeRange) onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(width: 8),
        TimePicker(
          onChanged: (time) {
            onChanged(
              value.copyWith(
                start: value.start.copyWith(
                  hour: time.hour,
                  minute: time.minute,
                ),
              ),
            );
          },
          value: value.start.toTimeOfDay(),
        ),
        const Text('→'),
        TimePicker(
          onChanged: (time) {
            onChanged(
              value.copyWith(
                end: value.end.copyWith(
                  hour: time.hour,
                  minute: time.minute,
                ),
              ),
            );
          },
          value: value.end.toTimeOfDay(),
        ),
      ],
    );
  }
}
