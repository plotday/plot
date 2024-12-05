import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos;
import 'package:platform_builder/platform_builder.dart';

class ToggleChoice<T> {
  const ToggleChoice({
    required this.value,
    required this.label,
  });

  final T value;
  final String label;
}

class Toggle<T> extends StatefulWidget {
  const Toggle(
      {required this.choices,
      required this.selected,
      required this.onSelect,
      super.key});

  final void Function(T) onSelect;
  final T selected;
  final List<ToggleChoice<T>> choices;

  @override
  _ToggleState<T> createState() => _ToggleState<T>();
}

class _ToggleState<T> extends State<Toggle<T>> {
  macos.MacosTabController? _macosTabController;

  macos.MacosTabController getMacosController() {
    _macosTabController = macos.MacosTabController(
      initialIndex: widget.choices
          .indexWhere((choice) => choice.value == widget.selected),
      length: widget.choices.length,
    );
    _macosTabController!.addListener(_handleMacosTabChange);
    return _macosTabController!;
  }

  void _handleMacosTabChange() {
    final selectedIndex = _macosTabController!.index;
    if (selectedIndex < widget.choices.length) {
      widget.onSelect(widget.choices[selectedIndex].value);
    }
  }

  @override
  void dispose() {
    _macosTabController?.removeListener(_handleMacosTabChange);
    _macosTabController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
        macOSBuilder: (_) => macos.MacosSegmentedControl(
              controller: getMacosController(),
              tabs: widget.choices
                  .map((choice) => macos.MacosTab(
                        label: choice.label,
                        active: widget.selected == choice.value,
                      ))
                  .toList(),
            ),
        builder: (_) => material.SegmentedButton<T>(
              segments: widget.choices
                  .map((choice) => material.ButtonSegment<T>(
                        value: choice.value,
                        label: Text(choice.label),
                      ))
                  .toList(),
              selected: <T>{widget.selected},
              onSelectionChanged: (Set<T> newSelection) {
                widget.onSelect(newSelection.first);
              },
            ));
  }
}
