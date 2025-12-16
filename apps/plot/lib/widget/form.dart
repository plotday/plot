import 'package:plot/widget/widget.dart';
import 'package:plot/widget/select_tile.dart';
import 'package:plot/command/base.dart';
import 'package:plot/command/logging.dart';
import 'package:plot/analytics/analytics.dart';

/// A action for showing a form
class ShowForm extends Command {
  ShowForm({
    required super.title,
    super.icon,
    super.shortcut,
    required this.form,
    EventObject? eventObject,
    EventAction? eventAction,
  }) : super(
         eventObject: eventObject ?? EventObject.dialog,
         eventAction: eventAction ?? EventAction.opened,
       );

  final Future<FormData> Function(BuildContext context) form;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final formInstance = await form(context);
      if (!context.mounted) {
        log.info('Context no longer mounted, skipping FormModal for "$title"');
        return const CommandSkipped();
      }
      // Pre-load form groups to avoid jank when modal opens
      final groups = await formInstance.list();
      if (!context.mounted) {
        log.info('Context no longer mounted, skipping FormModal for "$title"');
        return const CommandSkipped();
      }
      return await FormModal(
        formInstance,
        groups: groups,
        rootContext: context,
      ).run(context);
    } on Error catch (e, t) {
      log.warning('Action "$title" failed', e, t);
      rethrow;
    }
  }
}

/// Form item base class
abstract class FormItem {
  const FormItem({
    required this.key,
    this.label,
    this.required = false,
    this.autofocus = false,
  });

  final String key;
  final String? label;
  final bool required;
  final bool autofocus;

  /// Get the current value of the form item
  dynamic getValue();

  /// Set the value of the form item
  void setValue(dynamic value);

  /// Check if the form item is valid
  bool isValid();

  /// Build the widget for this form item
  Widget build(
    BuildContext context,
    bool highlighted, {
    bool enabled = true,
    FocusNode? focusNode,
  });
}

/// Text input form item
class FormTextInput extends FormItem {
  FormTextInput({
    required super.key,
    super.label,
    super.required,
    super.autofocus,
    this.placeholder,
    this.maxLines = 1,
    String? initialValue,
  }) : controller = TextEditingController(text: initialValue);

  final String? placeholder;
  final int maxLines;
  final TextEditingController controller;

  @override
  String getValue() => controller.text;

  @override
  void setValue(dynamic value) {
    if (value is String) {
      controller.text = value;
    }
  }

  @override
  bool isValid() {
    if (this.required) {
      return controller.text.isNotEmpty;
    }
    return true;
  }

  @override
  Widget build(
    BuildContext context,
    bool highlighted, {
    bool enabled = true,
    FocusNode? focusNode,
  }) {
    return InputTile(
      label: label ?? key,
      controller: controller,
      placeholder: placeholder,
      autofocus: autofocus,
      highlighted: highlighted,
      focusNode: focusNode,
    );
  }

  void dispose() {
    controller.dispose();
  }
}

/// Select form item for choosing from a list of options
class FormSelect<T> extends FormItem {
  FormSelect({
    required super.key,
    super.label,
    super.required,
    super.autofocus,
    required this.items,
    this.labelBuilder,
    this.titleBuilder,
    this.subtitleBuilder,
    this.leadingBuilder,
    this.placeholder,
    this.enabled = true,
    T? initialValue,
    this.onChanged,
    bool hasInitialValue = false,
  }) : assert(
         labelBuilder != null || titleBuilder != null,
         'Must provide either labelBuilder or titleBuilder',
       ),
       _value = initialValue,
       _hasValue = hasInitialValue || initialValue != null;

  /// Function to fetch items, optionally filtered by search text.
  final Future<List<T>> Function(String? search) items;

  /// Optional function to build a Widget label for an item in the selection modal.
  /// If provided, this takes precedence over titleBuilder+subtitleBuilder for the modal.
  /// The titleBuilder is still required for the form field display.
  final Widget Function(T)? labelBuilder;

  /// Function to build the string title for an item.
  /// Used for the form field display, and also for the modal if labelBuilder is not provided.
  final String Function(T)? titleBuilder;

  /// Optional function to build a subtitle for an item in the selection modal.
  /// Only used when labelBuilder is not provided (i.e., using string-based labels).
  final String? Function(T)? subtitleBuilder;

  /// Optional function to build a leading widget for an item.
  final Widget Function(T)? leadingBuilder;

  /// Placeholder text when no value is selected.
  final String? placeholder;

  /// Whether the field is enabled and can receive focus/interaction.
  final bool enabled;

  /// Callback when value changes.
  final VoidCallback? onChanged;

  T? _value;
  bool _hasValue;
  final List<VoidCallback> _listeners = [];

  @override
  T? getValue() => _value;

  @override
  void setValue(dynamic value) {
    if (value is T?) {
      _value = value;
      _hasValue = true;
      onChanged?.call();
      _notifyListeners();
    }
  }

  @override
  bool isValid() {
    if (this.required) {
      return _value != null;
    }
    return true;
  }

  /// Add a listener to be notified when the value changes
  void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  /// Remove a listener
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  /// Notify all listeners of a value change
  void _notifyListeners() {
    for (final listener in _listeners) {
      listener();
    }
  }

  /// Activate the select field (open the selection modal)
  Future<void> activate(BuildContext context) async {
    if (!enabled) return;
    final result = await SelectModal.open<T>(
      context,
      items: (search) async {
        final itemsList = await items(search);
        return [SelectGroup(title: null, items: itemsList)];
      },
      itemBuilder: (item) {
        final leading = leadingBuilder?.call(item);

        // Use Widget-based label if provided
        if (labelBuilder != null) {
          final labelWidget = labelBuilder!(item);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                if (leading != null) ...[leading, const SizedBox(width: 8)],
                Expanded(child: labelWidget),
              ],
            ),
          );
        }

        // Otherwise use String-based title+subtitle
        final title = titleBuilder!(item);
        final subtitle = subtitleBuilder?.call(item);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              if (leading != null) ...[leading, const SizedBox(width: 8)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, overflow: TextOverflow.ellipsis),
                    if (subtitle != null)
                      Text(
                        subtitle,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0x80FFFFFF),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
      selectedValue: _value,
      prompt: label ?? key,
    );
    if (result.present) {
      _value = result.value;
      _hasValue = true;
      onChanged?.call();
      _notifyListeners();
    }
  }

  @override
  Widget build(
    BuildContext context,
    bool highlighted, {
    bool enabled = true,
    FocusNode? focusNode,
  }) {
    final isEnabled = this.enabled && enabled;
    return SelectTile(
      label: label ?? key,
      value: _hasValue ? titleBuilder!(_value as T) : null,
      leading: _hasValue && leadingBuilder != null
          ? leadingBuilder!(_value as T)
          : null,
      placeholder: placeholder,
      autofocus: autofocus,
      highlighted: highlighted,
      enabled: isEnabled,
      onSelect: () => activate(context),
      focusNode: focusNode,
    );
  }
}

/// Button form item
class FormButton extends FormItem {
  FormButton({required super.key, required this.command, this.onSubmit})
    : super(required: false, autofocus: false);

  final Command command;
  final Future<CommandReturn> Function(
    BuildContext context,
    Map<String, dynamic> values,
  )?
  onSubmit;

  @override
  dynamic getValue() => null;

  @override
  void setValue(dynamic value) {
    // Buttons don't have values
  }

  @override
  bool isValid() => true; // Buttons are always valid

  @override
  Widget build(
    BuildContext context,
    bool highlighted, {
    bool enabled = true,
    FocusNode? focusNode,
  }) {
    return _FormButtonWidget(
      command: command,
      highlighted: highlighted,
      enabled: enabled,
      focusNode: focusNode,
    );
  }
}

class _FormButtonWidget extends StatefulWidget {
  const _FormButtonWidget({
    required this.command,
    required this.highlighted,
    required this.enabled,
    this.focusNode,
  });

  final Command command;
  final bool highlighted;
  final bool enabled;
  final FocusNode? focusNode;

  @override
  State<_FormButtonWidget> createState() => _FormButtonWidgetState();
}

class _FormButtonWidgetState extends State<_FormButtonWidget> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isHighlighted = widget.highlighted || _isHovered;

    return Opacity(
      opacity: widget.enabled ? 1.0 : 0.5,
      child: IgnorePointer(
        ignoring: !widget.enabled,
        child: FocusableActionDetector(
          focusNode: widget.enabled ? widget.focusNode : null,
          child: FormTileLayout(
            label:
                '', // FormButton doesn't have a label, just empty space on left
            rightBackgroundColor: isHighlighted
                ? context.theme.colors.secondary
                : null,
            isActive: isHighlighted,
            content: MouseRegion(
              onEnter: (_) => setState(() => _isHovered = true),
              onExit: (_) => setState(() => _isHovered = false),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  widget.command.title,
                  style: context.theme.typography.sm.copyWith(
                    fontWeight: FontWeight.bold,
                    color: context.theme.colors.foreground,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Info form item for displaying static content
class FormInfo extends FormItem {
  FormInfo({required super.key, required this.builder})
    : super(required: false, autofocus: false);

  final Widget Function(BuildContext) builder;

  @override
  dynamic getValue() => null;

  @override
  void setValue(dynamic value) {
    // Info items don't have values
  }

  @override
  bool isValid() => true; // Info items are always valid

  @override
  Widget build(
    BuildContext context,
    bool highlighted, {
    bool enabled = true,
    FocusNode? focusNode,
  }) {
    return Padding(
      padding: .symmetric(horizontal: 12),
      child: builder(context),
    );
  }
}

/// Form group base class
abstract class FormGroup {
  FormGroup({this.title, this.subtitle});

  final String? title;
  final String? subtitle;

  Future<List<FormItem>> list();
}

/// Static form group
class StaticFormGroup extends FormGroup {
  StaticFormGroup({super.title, super.subtitle, required this.items});

  final List<FormItem> items;

  @override
  Future<List<FormItem>> list() async {
    return items;
  }
}

/// Form data structure
class FormData {
  const FormData({required this.title, required this.groups});

  final String title;
  final List<FormGroup> groups;

  Future<List<StaticFormGroup>> list() async {
    List<StaticFormGroup> staticGroups = [];
    for (var group in groups) {
      List<FormItem> items = await group.list();
      if (items.isNotEmpty) {
        staticGroups.add(
          StaticFormGroup(
            title: group.title,
            subtitle: group.subtitle,
            items: items,
          ),
        );
      }
    }
    return staticGroups;
  }
}
