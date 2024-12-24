import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart';
import 'package:platform_builder/platform_builder.dart';

class SelectItem<T> {
  final T value;
  final String label;

  SelectItem({required this.value, required this.label});

  @override
  String toString() {
    return label;
  }
}

class Select<T> extends StatefulWidget {
  final List<SelectItem<T>> items;
  final T selected;
  final ValueChanged<T> onSelect;

  const Select({
    required this.items,
    required this.selected,
    required this.onSelect,
    super.key,
  });

  @override
  SelectState<T> createState() => SelectState<T>();
}

class SelectState<T> extends State<Select<T>> {
  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => MacosPopupButton(
        items: widget.items
            .map(
              (SelectItem<T> item) => MacosPopupMenuItem(
                value: item.value,
                child: Text(item.label),
              ),
            )
            .toList(),
        onChanged: (T? newValue) {
          if (newValue != null) {
            widget.onSelect(newValue);
          }
        },
      ),
      builder: (_) => material.DropdownButton<T>(
        value: widget.selected,
        onChanged: (T? newValue) {
          if (newValue != null) {
            widget.onSelect(newValue);
          }
        },
        items: widget.items
            .map<material.DropdownMenuItem<T>>((SelectItem<T> item) {
          return material.DropdownMenuItem<T>(
            value: item.value,
            child: Text(item.label),
          );
        }).toList(),
      ),
    );
  }
}
