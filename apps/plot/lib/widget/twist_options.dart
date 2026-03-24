import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/spacing.dart';
import 'form.dart';
import 'form_tile_layout.dart';
import 'input_tile.dart';
import 'select_modal.dart';
import 'select_tile.dart';

/// Builds a list of [FormItem]s from a twist options schema.
///
/// Returns the items and a getter to collect the current option values.
/// The items participate in form keyboard navigation.
class TwistOptionItems {
  TwistOptionItems({
    required Map<String, dynamic> options,
    Map<String, dynamic>? initialConfig,
    ValueChanged<Map<String, dynamic>>? onChanged,
  }) {
    final values = <String, dynamic>{};
    for (final entry in options.entries) {
      final key = entry.key;
      final def = entry.value as Map<String, dynamic>;
      values[key] = initialConfig?[key] ?? def['default'];
    }
    _values = values;
    _onChanged = onChanged;

    for (final entry in options.entries) {
      final def = entry.value as Map<String, dynamic>;
      final type = def['type'] as String;
      final item = switch (type) {
        'select' => _TwistSelectItem(
          optionKey: entry.key,
          def: def,
          owner: this,
        ),
        'boolean' => _TwistBooleanItem(
          optionKey: entry.key,
          def: def,
          owner: this,
        ),
        'text' => _TwistTextItem(optionKey: entry.key, def: def, owner: this),
        'number' => _TwistNumberItem(
          optionKey: entry.key,
          def: def,
          owner: this,
        ),
        _ => null,
      };
      if (item != null) _items.add(item);
    }
  }

  late final Map<String, dynamic> _values;
  ValueChanged<Map<String, dynamic>>? _onChanged;
  final List<FormItem> _items = [];

  /// The form items to include in the form group.
  List<FormItem> get items => _items;

  /// Get the current option values.
  Map<String, dynamic> get values => Map.of(_values);

  void _updateValue(String key, dynamic value) {
    _values[key] = value;
    _onChanged?.call(Map.of(_values));
  }
}

// ============================================================================
// FormItem subclasses for twist option types
// ============================================================================

class _TwistSelectItem extends FormItem {
  _TwistSelectItem({
    required this.optionKey,
    required this.def,
    required this.owner,
  }) : super(key: 'option_$optionKey', label: def['label'] as String);

  final String optionKey;
  final Map<String, dynamic> def;
  final TwistOptionItems owner;

  List<Map<String, dynamic>> get _choices =>
      (def['choices'] as List<dynamic>).cast<Map<String, dynamic>>();

  @override
  bool get canActivate => true;

  @override
  dynamic getValue() => owner._values[optionKey];

  @override
  void setValue(dynamic value) {
    owner._updateValue(optionKey, value);
  }

  @override
  bool isValid() => true;

  @override
  Future<void> activate(BuildContext context, {int subIndex = 0}) async {
    final currentValue = owner._values[optionKey] as String?;
    final result = await SelectModal.open<String>(
      context,
      items: (_) async => [
        SelectGroup<String>(
          items: _choices.map((c) => c['value'] as String).toList(),
        ),
      ],
      itemBuilder: (value, _) {
        final choice = _choices.firstWhere((c) => c['value'] == value);
        final isSelected = value == currentValue;
        return Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.theme.spacing.lg,
            vertical: context.theme.spacing.md,
          ),
          child: Text(
            choice['label'] as String,
            style: context.theme.typography.md.copyWith(
              color: context.theme.colors.foreground,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        );
      },
      selectedValue: currentValue,
      showFilter: true,
      prompt: label ?? optionKey,
    );
    if (result.present) {
      owner._updateValue(optionKey, result.value);
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
    final currentValue = owner._values[optionKey] as String?;
    final currentChoice = _choices.firstWhere(
      (c) => c['value'] == currentValue,
      orElse: () => _choices.first,
    );
    return SelectTile(
      label: label ?? optionKey,
      value: currentChoice['label'] as String,
      highlighted: highlightedSubIndex >= 0,
      focusNode: focusNodes.firstOrNull,
      onSelect: () => activate(context),
    );
  }
}

class _TwistBooleanItem extends FormItem {
  _TwistBooleanItem({
    required this.optionKey,
    required this.def,
    required this.owner,
  }) : super(key: 'option_$optionKey', label: def['label'] as String);

  final String optionKey;
  final Map<String, dynamic> def;
  final TwistOptionItems owner;

  @override
  dynamic getValue() => owner._values[optionKey];

  @override
  void setValue(dynamic value) {
    owner._updateValue(optionKey, value);
  }

  @override
  bool isValid() => true;

  @override
  Widget build(
    BuildContext context,
    int highlightedSubIndex, {
    bool enabled = true,
    List<FocusNode> focusNodes = const [],
    FormButtonController? controller,
  }) {
    final value = owner._values[optionKey] as bool? ?? false;
    return FormTileLayout(
      label: label ?? optionKey,
      isActive: highlightedSubIndex >= 0,
      content: Align(
        alignment: Alignment.centerLeft,
        child: FSwitch(
          value: value,
          onChange: (newValue) => owner._updateValue(optionKey, newValue),
        ),
      ),
    );
  }
}

class _TwistTextItem extends FormItem {
  _TwistTextItem({
    required this.optionKey,
    required this.def,
    required this.owner,
  }) : _secure = def['secure'] == true,
       _changed = false,
       _controller = TextEditingController(
         text: def['secure'] == true && owner._values[optionKey] == true
             ? ''
             : (owner._values[optionKey] ?? '').toString(),
       ),
       super(key: 'option_$optionKey', label: def['label'] as String);

  final String optionKey;
  final Map<String, dynamic> def;
  final TwistOptionItems owner;
  final TextEditingController _controller;
  final bool _secure;
  bool _changed;

  @override
  dynamic getValue() {
    if (_secure && !_changed) {
      // Return the sentinel value (true) meaning "value unchanged"
      return true;
    }
    return _controller.text;
  }

  @override
  void setValue(dynamic value) {
    if (value is String) {
      _controller.text = value;
      _changed = true;
      owner._updateValue(optionKey, value);
    }
  }

  @override
  bool isValid() => true;

  @override
  Widget build(
    BuildContext context,
    int highlightedSubIndex, {
    bool enabled = true,
    List<FocusNode> focusNodes = const [],
    FormButtonController? controller,
  }) {
    return InputTile(
      label: label ?? optionKey,
      controller: _controller,
      placeholder: _secure && !_changed
          ? '\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022'
          : def['placeholder'] as String?,
      highlighted: highlightedSubIndex >= 0,
      focusNode: focusNodes.firstOrNull,
      obscureText: _secure,
      onChanged: (value) {
        _changed = true;
        owner._updateValue(optionKey, value);
      },
    );
  }
}

class _TwistNumberItem extends FormItem {
  _TwistNumberItem({
    required this.optionKey,
    required this.def,
    required this.owner,
  }) : _controller = TextEditingController(
         text: (owner._values[optionKey] ?? '').toString(),
       ),
       super(key: 'option_$optionKey', label: def['label'] as String);

  final String optionKey;
  final Map<String, dynamic> def;
  final TwistOptionItems owner;
  final TextEditingController _controller;

  @override
  dynamic getValue() => num.tryParse(_controller.text);

  @override
  void setValue(dynamic value) {
    _controller.text = value?.toString() ?? '';
    owner._updateValue(optionKey, value);
  }

  @override
  bool isValid() => true;

  @override
  Widget build(
    BuildContext context,
    int highlightedSubIndex, {
    bool enabled = true,
    List<FocusNode> focusNodes = const [],
    FormButtonController? controller,
  }) {
    return InputTile(
      label: label ?? optionKey,
      controller: _controller,
      highlighted: highlightedSubIndex >= 0,
      focusNode: focusNodes.firstOrNull,
      onChanged: (value) {
        final numValue = num.tryParse(value);
        if (numValue != null) {
          owner._updateValue(optionKey, numValue);
        }
      },
    );
  }
}
