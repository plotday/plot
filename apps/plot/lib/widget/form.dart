import 'package:drift/drift.dart' show Value;
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/select_tile.dart';
import 'package:plot/command/base.dart';
import 'package:plot/command/logging.dart';
import 'package:plot/command/share.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/store/store.dart'
    show Actor, ActorId, Group, Priority, Uuid;
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/store/attention.dart';
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';

/// Simple command for form submission when display command cannot be built
class _FormSubmitCommand extends Command {
  _FormSubmitCommand()
    : super(
        title: 'Submit',
        eventObject: EventObject.modal,
        eventAction: EventAction.updated,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    return const CommandSkipped();
  }
}

/// Controller for programmatically triggering FormButton submission
/// (e.g., when Enter is pressed in form fields)
class FormButtonController {
  final ListTileController _controller = ListTileController();

  /// Run the form button command (triggers spinner and validation)
  Future<CommandReturn> run() {
    return _controller.run();
  }

  /// Internal: Get the ListTileController for passing to ListTile
  ListTileController get _listTileController => _controller;
}

/// Provides form values and validation to descendants
class FormScope extends InheritedWidget {
  const FormScope({
    required this.values,
    required this.validate,
    this.refresh,
    required super.child,
    super.key,
  });

  final Map<String, dynamic> values;
  final bool Function() validate;

  /// Triggers a form data refresh (re-fetches and rebuilds groups).
  /// Only available when the form's [FormData.onRefresh] is set.
  final Future<void> Function()? refresh;

  static FormScope? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<FormScope>();
  }

  @override
  bool updateShouldNotify(FormScope old) => values != old.values;
}

/// A action for showing a form
class ShowForm extends Command {
  ShowForm({
    required super.title,
    super.subtitle,
    super.icon,
    super.shortcut,
    required this.form,
    this.constraints,
    this.maxWidthPercentage,
    EventObject? eventObject,
    EventAction? eventAction,
  }) : super(
         eventObject: eventObject ?? EventObject.modal,
         eventAction: eventAction ?? EventAction.opened,
       );

  final Future<FormData> Function(BuildContext context) form;
  final BoxConstraints? constraints;
  final double? maxWidthPercentage;

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
        constraints: constraints,
        maxWidthPercentage: maxWidthPercentage,
      ).run(context);
    } on ApiException catch (e, t) {
      // A failed request (e.g. a 404 fetching a connection's integrations)
      // must surface to the user rather than dying silently — ApiException is
      // an Exception, not an Error, so it would otherwise slip past the
      // `on Error` clause below and rethrow with no UI. Mirror the
      // ManageConnections._loadData pattern: convert to an error toast.
      log.warning('Action "$title" failed', e, t);
      return const CommandMessage(
        'Something went wrong. Please try again.',
        isError: true,
      );
    } on NetworkException catch (e, t) {
      log.warning('Action "$title" failed', e, t);
      return const CommandMessage(
        'Could not connect to Plot servers.',
        isError: true,
      );
    } on Error catch (e, t) {
      log.warning('Action "$title" failed', e, t);
      rethrow;
    }
  }
}

/// Form item base class
abstract class FormItem {
  const FormItem({required this.key, this.label, this.required = false});

  final String key;
  final String? label;
  final bool required;

  /// Whether this item can receive keyboard focus and navigation
  bool get isFocusable => true;

  /// Number of focusable sub-items within this form item.
  /// Most items have 1 (or 0 if not focusable). Items like FormWindowList
  /// have multiple sub-items that each need their own focus slot.
  int get focusableCount => isFocusable ? 1 : 0;

  /// Whether this item can be activated (e.g., opens a modal on Enter/tap)
  bool get canActivate => false;

  /// Activate the item (e.g., open a selection modal).
  /// Only called when [canActivate] is true.
  /// [subIndex] indicates which sub-item was activated (0 for most items).
  Future<void> activate(BuildContext context, {int subIndex = 0}) async {}

  /// Get the current value of the form item
  dynamic getValue();

  /// Set the value of the form item
  void setValue(dynamic value);

  /// Check if the form item is valid
  bool isValid();

  /// Add a listener for value changes. Override in subclasses with editable
  /// state that the form modal should react to (e.g. re-evaluate validation).
  void addChangeListener(VoidCallback listener) {}

  /// Remove a value change listener.
  void removeChangeListener(VoidCallback listener) {}

  /// Called when the user presses Enter in a text field.
  /// Set by FormModalState to trigger form submission.
  /// Override the setter in subclasses with text input.
  set onSubmitted(VoidCallback? callback) {}
  VoidCallback? get onSubmitted => null;

  /// Build the widget for this form item.
  /// [highlightedSubIndex] is the sub-item index that should be highlighted,
  /// or -1 if no sub-item is highlighted.
  /// [focusNodes] contains one focus node per focusable sub-item.
  Widget build(
    BuildContext context,
    int highlightedSubIndex, {
    bool enabled = true,
    List<FocusNode> focusNodes = const [],
    FormButtonController? controller,
  });
}

/// Text input form item
class FormTextInput extends FormItem {
  FormTextInput({
    required super.key,
    super.label,
    super.required,
    this.placeholder,
    this.maxLines = 1,
    String? initialValue,
  }) : controller = TextEditingController(text: initialValue);

  final String? placeholder;
  final int maxLines;
  final TextEditingController controller;

  VoidCallback? _onSubmitted;

  @override
  set onSubmitted(VoidCallback? callback) => _onSubmitted = callback;

  @override
  VoidCallback? get onSubmitted => _onSubmitted;

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
    int highlightedSubIndex, {
    bool enabled = true,
    List<FocusNode> focusNodes = const [],
    FormButtonController? controller,
  }) {
    return InputTile(
      label: label ?? key,
      controller: this.controller,
      placeholder: placeholder,
      highlighted: highlightedSubIndex >= 0,
      focusNode: focusNodes.firstOrNull,
      onSubmitted: _onSubmitted != null ? (_) => _onSubmitted!() : null,
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
    required this.items,
    this.labelBuilder,
    this.titleBuilder,
    this.subtitleBuilder,
    this.leadingBuilder,
    this.placeholder,
    this.enabled = true,
    this.readonlyMessage,
    T? initialValue,
    this.onChanged,
    this.onAdd,
    this.addLabel,
    this.gridColumns,
    this.gridCellSize = 36,
    this.gridCellSpacing = 4,
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

  /// When set, the field looks enabled but shows this message as a toast
  /// instead of opening the selection modal.
  String? readonlyMessage;

  /// Callback when value changes.
  final VoidCallback? onChanged;

  /// Optional callback to create a new item inline.
  /// When provided, a "+" button is shown in the selection modal.
  final Future<T?> Function(BuildContext context)? onAdd;

  /// When set together with [onAdd], the selection modal renders a labeled
  /// "[addLabel]" row at the bottom of the list (keyboard-navigable) instead of
  /// the "+" search-field button. Activating it runs [onAdd] and, on a non-null
  /// result, selects it. Leave null to keep the legacy "+" button.
  final String? addLabel;

  /// When non-null, the selection modal renders items in a grid with this many
  /// columns (like the emoji reaction picker) instead of the default list.
  /// Each cell shows the item's [leadingBuilder] widget with its
  /// [titleBuilder] text as a tooltip. The form field display is unchanged.
  final int? gridColumns;

  /// Edge length of each grid cell in logical pixels. Only used when
  /// [gridColumns] is set.
  final double gridCellSize;

  /// Spacing between grid cells in logical pixels. Only used when
  /// [gridColumns] is set.
  final double gridCellSpacing;

  T? _value;
  bool _hasValue;

  /// Whether the user explicitly changed the value (via activate/modal).
  /// Used by form refresh to decide whether to restore saved values.
  bool userModified = false;

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
  bool get canActivate => true;

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
  @override
  Future<void> activate(BuildContext context, {int subIndex = 0}) async {
    if (readonlyMessage != null) {
      context.showToast(message: readonlyMessage!);
      return;
    }
    if (!enabled) return;
    final useAddRow = addLabel != null && onAdd != null;
    final result = await SelectModal.open<T>(
      context,
      items: (search) async {
        final itemsList = await items(search);
        return [
          SelectGroup<T>(title: null, items: itemsList),
          if (useAddRow)
            SelectGroup<T>(
              items: <T>[],
              infoBuilder: (ctx) => addItemRow(ctx, label: addLabel!),
              onActivate: (ctx) async {
                final created = await onAdd!(ctx);
                if (created != null && ctx.mounted) {
                  Modal.pop<T>(ctx, Value(created));
                }
              },
            ),
        ];
      },
      itemBuilder: gridColumns != null
          ? (item, _) => _buildGridCell(context, item)
          : (item, _) {
              final leading = leadingBuilder?.call(item);

              // Use Widget-based label if provided
              if (labelBuilder != null) {
                final labelWidget = labelBuilder!(item);
                return Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.theme.spacing.lg,
                    vertical: context.theme.spacing.md,
                  ),
                  child: Row(
                    children: [
                      if (leading != null) ...[
                        IconTheme(
                          data: IconThemeData(
                            color: context.theme.colors.foreground,
                          ),
                          child: leading,
                        ),
                        SizedBox(width: context.theme.spacing.md),
                      ],
                      Expanded(child: labelWidget),
                    ],
                  ),
                );
              }

              // Otherwise use String-based title+subtitle
              final title = titleBuilder!(item);
              final subtitle = subtitleBuilder?.call(item);

              return Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: context.theme.spacing.lg,
                  vertical: context.theme.spacing.md,
                ),
                child: Row(
                  children: [
                    if (leading != null) ...[
                      IconTheme(
                        data: IconThemeData(
                          color: context.theme.colors.foreground,
                        ),
                        child: leading,
                      ),
                      SizedBox(width: context.theme.spacing.md),
                    ],
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
      onAdd: useAddRow ? null : onAdd,
      gridColumns: gridColumns,
      gridCellSize: gridCellSize,
      gridCellSpacing: gridCellSpacing,
    );
    if (result.present) {
      _value = result.value;
      _hasValue = true;
      userModified = true;
      onChanged?.call();
      _notifyListeners();
    }
  }

  /// Builds a compact cell for the selection modal's grid mode: the item's
  /// leading widget centered, with its title shown as a tooltip. Falls back to
  /// the title text when no leading widget is provided.
  Widget _buildGridCell(BuildContext context, T item) {
    final leading = leadingBuilder?.call(item);
    final title = titleBuilder?.call(item);
    final cell = Center(
      child: IconTheme(
        data: IconThemeData(color: context.theme.colors.foreground),
        child:
            leading ??
            (title != null
                ? Text(title, overflow: TextOverflow.ellipsis)
                : const SizedBox.shrink()),
      ),
    );
    if (title == null) return cell;
    return FTooltip(tipBuilder: (ctx, _) => Text(title), child: cell);
  }

  @override
  Widget build(
    BuildContext context,
    int highlightedSubIndex, {
    bool enabled = true,
    List<FocusNode> focusNodes = const [],
    FormButtonController? controller,
  }) {
    final isEnabled = this.enabled && enabled;
    return SelectTile(
      label: label ?? key,
      value: _hasValue ? titleBuilder!(_value as T) : null,
      // When a Widget label is provided it carries its own styling (e.g. a
      // role/focus label rendered in its colour), so show it in the value slot
      // instead of the plain title text.
      valueWidget: _hasValue && labelBuilder != null
          ? labelBuilder!(_value as T)
          : null,
      leading: _hasValue && leadingBuilder != null
          ? IconTheme(
              data: IconThemeData(color: context.theme.colors.foreground),
              child: leadingBuilder!(_value as T),
            )
          : null,
      placeholder: placeholder,
      highlighted: highlightedSubIndex >= 0,
      enabled: isEnabled,
      readonlyMessage: readonlyMessage,
      onSelect: () => activate(context),
      focusNode: focusNodes.firstOrNull,
    );
  }
}

/// Button form item
class FormButton extends FormItem {
  FormButton({
    required super.key,
    required this.buildCommand,
    this.skipValidation = false,
    this.isPrimary = false,
  }) : super(required: false, label: '');

  final Command Function(Map<String, dynamic> values) buildCommand;

  /// When true, this button remains enabled even when form validation fails.
  final bool skipValidation;

  /// Whether this is the primary submit button — styled with accent color and
  /// triggered when the user presses Enter from a text input. Forms should
  /// mark exactly one button primary; forms with no obvious submit (e.g. an
  /// auth widget that handles its own action) may have none.
  final bool isPrimary;

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
    int highlightedSubIndex, {
    bool enabled = true,
    List<FocusNode> focusNodes = const [],
    FormButtonController? controller,
  }) {
    return _FormButtonWidget(
      buildCommand: buildCommand,
      controller: controller,
      highlighted: highlightedSubIndex >= 0,
      enabled: enabled,
      skipValidation: skipValidation,
      focusNode: focusNodes.firstOrNull,
      isPrimary: isPrimary,
    );
  }
}

class _FormButtonWidget extends StatefulWidget {
  const _FormButtonWidget({
    required this.buildCommand,
    required this.controller,
    required this.highlighted,
    required this.enabled,
    this.skipValidation = false,
    this.focusNode,
    this.isPrimary = false,
  });

  final Command Function(Map<String, dynamic> values) buildCommand;
  final FormButtonController? controller;
  final bool highlighted;
  final bool enabled;
  final bool skipValidation;
  final FocusNode? focusNode;
  final bool isPrimary;

  @override
  State<_FormButtonWidget> createState() => _FormButtonWidgetState();
}

class _FormButtonWidgetState extends State<_FormButtonWidget> {
  @override
  void initState() {
    super.initState();
    // No manual attachment needed - ListTile handles this via controller
  }

  @override
  void dispose() {
    // No manual detachment needed
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Get form values from FormScope
    final formValues = FormScope.of(context)?.values ?? {};
    final formValidate = FormScope.of(context)?.validate;

    // Build display command for icon/text (with current form values)
    Command displayCommand;
    try {
      displayCommand = widget.buildCommand(formValues);
    } catch (e) {
      // If command requires values, use fallback command with no icon
      log.warning('Could not build command for display: $e');
      displayCommand = _FormSubmitCommand();
    }

    // Create the run function that validates, executes, and handles result
    Future<CommandReturn> runWrappedCommand() async {
      // Validate form before executing (skip for buttons that opt out)
      if (!widget.skipValidation && formValidate != null && !formValidate()) {
        context.showToast(
          message: 'Please fill in all required fields',
          isError: true,
        );
        return const CommandDone();
      }

      // Get latest form values
      final latestValues = FormScope.of(context)?.values ?? formValues;

      // Build fresh command with latest values
      final command = widget.buildCommand(latestValues);

      // Execute command
      final result = await command.run(context);

      // Handle result inline (FormButton-specific behavior)
      if (context.mounted) {
        if (result is CommandMessage && result.isError) {
          context.showToast(
            title: result.title,
            message: result.message,
            isError: true,
          );
        } else if (result is CommandRefresh) {
          // Refresh in-place if the form supports it, otherwise pop
          final refresh = FormScope.of(context)?.refresh;
          if (refresh != null) {
            await refresh();
          } else {
            Modal.pop<CommandReturn>(context, Value(result));
          }
        } else if (result is CommandRoute) {
          await Modal.popAll(context);
          if (context.mounted) {
            result.go(context);
          }
        } else if (result is! CommandSkipped) {
          Modal.pop<CommandReturn>(context, Value(result));
        }
      }

      // Prevent double-toast: CommandMessage results are already handled above
      // (error toast shown, or success result passed via Modal.pop for the
      // parent modal to handle). Return CommandDone so context.run() in
      // base.dart doesn't show a duplicate toast.
      if (result is CommandMessage) {
        return const CommandDone();
      }
      return result;
    }

    // Create CommandWrapper that uses the run function
    final wrappedCommand = CommandWrapper(
      displayCommand,
      run: (_, context) => runWrappedCommand(),
    );

    return Opacity(
      opacity: widget.enabled ? 1.0 : 0.5,
      child: IgnorePointer(
        ignoring: !widget.enabled,
        child: ListTile(
          command: wrappedCommand,
          style: ListTileStyle.button,
          padding: EdgeInsets.symmetric(
            horizontal: context.theme.spacing.xl,
            vertical: context.theme.spacing.sm,
          ),
          focusNode: widget.focusNode,
          controller: widget.controller?._listTileController,
          textStyle: widget.isPrimary && widget.enabled
              ? context.theme.typography.md.copyWith(
                  fontWeight: FontWeight.bold,
                  color: context.theme.colors.primary,
                )
              : null,
        ),
      ),
    );
  }
}

/// Info form item for displaying static content
class FormInfo extends FormItem {
  FormInfo({required super.key, this.builder, this.text, this.divider = false})
    : super(required: false);

  final Widget Function(BuildContext)? builder;
  final String? text;
  final bool divider;

  @override
  bool get isFocusable => false;

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
    int highlightedSubIndex, {
    bool enabled = true,
    List<FocusNode> focusNodes = const [],
    FormButtonController? controller,
  }) {
    return Container(
      padding: EdgeInsets.only(bottom: divider ? context.theme.spacing.md : 0),
      decoration: divider
          ? BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: context.theme.colors.border,
                  width: 1,
                ),
              ),
            )
          : null,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: text != null ? context.theme.spacing.xl : 0,
        ),
        child: text != null
            ? SelectableText(
                text!,
                style: context.theme.typography.md.copyWith(
                  color: context.theme.colors.mutedForeground,
                ),
              )
            : builder!(context),
      ),
    );
  }
}

/// Divider form item for visual separation between form items
class FormDivider extends FormItem {
  FormDivider({required super.key}) : super(required: false);

  @override
  bool get isFocusable => false;

  @override
  dynamic getValue() => null;

  @override
  void setValue(dynamic value) {
    // Divider items don't have values
  }

  @override
  bool isValid() => true; // Divider items are always valid

  @override
  Widget build(
    BuildContext context,
    int highlightedSubIndex, {
    bool enabled = true,
    List<FocusNode> focusNodes = const [],
    FormButtonController? controller,
  }) {
    return Container(
      margin: EdgeInsets.symmetric(vertical: context.theme.spacing.md),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: context.theme.colors.border, width: 1),
        ),
      ),
    );
  }
}

/// Toggle form item with a switch for boolean values
class FormToggle extends FormItem {
  FormToggle({
    required super.key,
    super.label,
    this.details,
    this.content,
    bool initialValue = true,
    this.onChanged,
  }) : _value = initialValue,
       super(required: false);

  /// Optional description text shown below the toggle.
  final String? details;

  /// Optional rich widget shown in place of the [label] text (e.g. a thread
  /// summary). When set, [label] is still used for the form field's semantics.
  final Widget? content;

  /// Callback when value changes.
  final VoidCallback? onChanged;

  bool _value;
  final List<VoidCallback> _listeners = [];

  @override
  bool getValue() => _value;

  @override
  void setValue(dynamic value) {
    if (value is bool) {
      _value = value;
      onChanged?.call();
      _notifyListeners();
    }
  }

  @override
  bool get canActivate => true;

  @override
  Future<void> activate(BuildContext context, {int subIndex = 0}) async {
    _value = !_value;
    onChanged?.call();
    _notifyListeners();
  }

  @override
  bool isValid() => true;

  void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  void _notifyListeners() {
    for (final listener in _listeners) {
      listener();
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
    return _FormToggleWidget(
      label: label ?? key,
      details: details,
      content: content,
      value: _value,
      highlighted: highlightedSubIndex >= 0,
      enabled: enabled,
      focusNode: focusNodes.firstOrNull,
      onToggle: () => activate(context),
    );
  }
}

class _FormToggleWidget extends StatefulWidget {
  const _FormToggleWidget({
    required this.label,
    this.details,
    this.content,
    required this.value,
    required this.highlighted,
    required this.enabled,
    required this.onToggle,
    this.focusNode,
  });

  final String label;
  final String? details;
  final Widget? content;
  final bool value;
  final bool highlighted;
  final bool enabled;
  final VoidCallback onToggle;
  final FocusNode? focusNode;

  @override
  State<_FormToggleWidget> createState() => _FormToggleWidgetState();
}

class _FormToggleWidgetState extends State<_FormToggleWidget> {
  FocusNode? _internalFocusNode;
  bool _isHovered = false;

  FocusNode get _focusNode => widget.focusNode ?? _internalFocusNode!;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode == null) {
      _internalFocusNode = FocusNode();
    }
    _focusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    setState(() {});
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _internalFocusNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isHighlighted =
        widget.enabled &&
        (_focusNode.hasFocus || _isHovered || widget.highlighted);

    return FocusableActionDetector(
      focusNode: _focusNode,
      enabled: widget.enabled,
      child: GestureDetector(
        onTap: widget.enabled ? widget.onToggle : null,
        child: MouseRegion(
          cursor: SystemMouseCursors.basic,
          onEnter: widget.enabled
              ? (_) => setState(() => _isHovered = true)
              : null,
          onExit: widget.enabled
              ? (_) => setState(() => _isHovered = false)
              : null,
          child: FormTileLayout(
            label: '',
            rightBackgroundColor: isHighlighted
                ? context.theme.colors.secondary
                : null,
            isActive: isHighlighted,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: widget.content ??
                          Text(
                            widget.label,
                            style: context.theme.typography.md.copyWith(
                              color: widget.enabled
                                  ? context.theme.colors.foreground
                                  : context.theme.plotColors.muted,
                            ),
                          ),
                    ),
                    SizedBox(width: context.theme.spacing.md),
                    SizedBox(
                      width: 32,
                      height: 20,
                      child: FittedBox(
                        fit: BoxFit.contain,
                        child: FSwitch(
                          value: widget.value,
                          onChange: (_) => widget.onToggle(),
                          enabled: widget.enabled,
                        ),
                      ),
                    ),
                  ],
                ),
                if (widget.details != null)
                  Padding(
                    padding: EdgeInsets.only(top: context.theme.spacing.xs),
                    child: Text(
                      widget.details!,
                      style: context.theme.typography.sm.copyWith(
                        color: context.theme.plotColors.muted,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Form item that displays a list of attention windows as tappable tiles
/// with an "Add attention window" button. Non-focusable; tiles handle their own
/// tap interaction and delegate to [onEdit] / [onAdd] callbacks.
class FormWindowList extends FormItem {
  FormWindowList({
    required super.key,
    required List<AttentionWindow> initialWindows,
    required this.onEdit,
    required this.onAdd,
    this.onChanged,
  }) : _windows = List.of(initialWindows),
       super(required: true);

  final Future<void> Function(BuildContext context, int index) onEdit;
  final Future<void> Function(BuildContext context) onAdd;
  final VoidCallback? onChanged;

  List<AttentionWindow> _windows;
  final List<VoidCallback> _listeners = [];

  List<AttentionWindow> get windows => List.unmodifiable(_windows);

  @override
  bool get isFocusable => true;

  @override
  int get focusableCount => _windows.length + 1;

  @override
  List<AttentionWindow> getValue() => _windows;

  @override
  void setValue(dynamic value) {
    if (value is List<AttentionWindow>) {
      _windows = List.of(value);
      onChanged?.call();
      _notifyListeners();
    }
  }

  void updateWindow(int index, AttentionWindow window) {
    _windows[index] = window;
    onChanged?.call();
    _notifyListeners();
  }

  void removeWindow(int index) {
    _windows.removeAt(index);
    onChanged?.call();
    _notifyListeners();
  }

  void addWindow(AttentionWindow window) {
    _windows.add(window);
    onChanged?.call();
    _notifyListeners();
  }

  @override
  bool get canActivate => true;

  @override
  Future<void> activate(BuildContext context, {int subIndex = 0}) {
    if (subIndex < _windows.length) {
      return onEdit(context, subIndex);
    }
    return onAdd(context);
  }

  @override
  bool isValid() => true;

  void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  void _notifyListeners() {
    for (final listener in _listeners) {
      listener();
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
    return _FormWindowListWidget(
      windows: _windows,
      onEdit: onEdit,
      onAdd: onAdd,
      highlightedSubIndex: highlightedSubIndex,
      focusNodes: focusNodes,
    );
  }
}

class _FormWindowListWidget extends StatelessWidget {
  const _FormWindowListWidget({
    required this.windows,
    required this.onEdit,
    required this.onAdd,
    required this.highlightedSubIndex,
    this.focusNodes = const [],
  });

  final List<AttentionWindow> windows;
  final Future<void> Function(BuildContext context, int index) onEdit;
  final Future<void> Function(BuildContext context) onAdd;
  final int highlightedSubIndex;
  final List<FocusNode> focusNodes;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < windows.length; i++)
          _WindowTile(
            window: windows[i],
            onTap: () => onEdit(context, i),
            highlighted: highlightedSubIndex == i,
            focusNode: i < focusNodes.length ? focusNodes[i] : null,
          ),
        _AddWindowTile(
          onTap: () => onAdd(context),
          highlighted: highlightedSubIndex == windows.length,
          focusNode: windows.length < focusNodes.length
              ? focusNodes[windows.length]
              : null,
        ),
      ],
    );
  }
}

class _WindowTile extends StatelessWidget {
  const _WindowTile({
    required this.window,
    required this.onTap,
    required this.highlighted,
    this.focusNode,
  });

  final AttentionWindow window;
  final VoidCallback onTap;
  final bool highlighted;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: window.summary,
      icon: PlotIcon.right,
      padding: EdgeInsets.symmetric(
        horizontal: context.theme.spacing.xl,
        vertical: context.theme.spacing.sm,
      ),
      highlighted: highlighted,
      focusNode: focusNode,
      command: CommandWrapper(
        _FormSubmitCommand(),
        title: window.summary,
        run: (_, _) async {
          onTap();
          return const CommandSkipped();
        },
      ),
    );
  }
}

class _AddWindowTile extends StatelessWidget {
  const _AddWindowTile({
    required this.onTap,
    required this.highlighted,
    this.focusNode,
  });

  final VoidCallback onTap;
  final bool highlighted;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: 'Add notification window',
      icon: PlotIcon.add,
      padding: EdgeInsets.symmetric(
        horizontal: context.theme.spacing.xl,
        vertical: context.theme.spacing.sm,
      ),
      muted: true,
      highlighted: highlighted,
      focusNode: focusNode,
      command: CommandWrapper(
        _FormSubmitCommand(),
        title: 'Add notification window',
        icon: Value(PlotIcon.add),
        run: (_, _) async {
          onTap();
          return const CommandSkipped();
        },
      ),
    );
  }
}

/// Controller for [FormChannelList] that bridges async-loaded channel content
/// to the form's focus system.
class FormChannelListController {
  int _count = 0;
  Future<void> Function(BuildContext, int)? _activator;
  VoidCallback? _onCountChanged;

  /// Which sub-item is currently highlighted by the form (-1 = none).
  int highlightedSubIndex = -1;

  /// Focus nodes assigned by the form, one per focusable sub-item.
  List<FocusNode> focusNodes = const [];

  int get count => _count;

  /// Called by the channel widget after building its rows.
  void update(int count, Future<void> Function(BuildContext, int) activator) {
    _activator = activator;
    if (count != _count) {
      _count = count;
      _onCountChanged?.call();
    }
  }

  /// Notify the form that validation state may have changed (e.g. channel toggled).
  void notifyValidationChanged() {
    _onCountChanged?.call();
  }
}

/// Form item that displays a list of channels via an external builder.
/// The channel widget calls [controller.update] to report its focusable count
/// and activation handler, bridging async-loaded content to the form's focus system.
class FormChannelList extends FormItem {
  FormChannelList({
    required super.key,
    required this.controller,
    required this.builder,
    this.validator,
  }) : super(required: false);

  final FormChannelListController controller;
  final Widget Function(BuildContext) builder;

  /// Optional validator that controls form-level validity.
  /// When provided and returns false, buttons without [FormButton.skipValidation]
  /// will be disabled.
  final bool Function()? validator;

  @override
  bool get isFocusable => true;

  @override
  int get focusableCount => controller.count;

  @override
  bool get canActivate => true;

  @override
  Future<void> activate(BuildContext context, {int subIndex = 0}) async {
    await controller._activator?.call(context, subIndex);
  }

  @override
  dynamic getValue() => null;

  @override
  void setValue(dynamic value) {}

  @override
  bool isValid() => validator?.call() ?? true;

  void addListener(VoidCallback listener) {
    controller._onCountChanged = listener;
  }

  void removeListener(VoidCallback listener) {
    if (controller._onCountChanged == listener) {
      controller._onCountChanged = null;
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
    this.controller.highlightedSubIndex = highlightedSubIndex;
    this.controller.focusNodes = focusNodes;
    return builder(context);
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
  const FormData({
    required this.title,
    required this.groups,
    this.onRefresh,
    this.refreshOn,
    this.dismissable = false,
  });

  final String title;
  final List<FormGroup> groups;

  /// Optional callback to rebuild form groups (e.g. after a child modal adds data).
  /// Called when a child modal is popped. Returns new resolved groups.
  final Future<List<StaticFormGroup>> Function()? onRefresh;

  /// Optional external trigger that re-runs [onRefresh] when it fires (e.g.
  /// [SubscriptionService.instance.notifier] so an open setup modal rebuilds
  /// its upgrade/at-limit buttons the moment the user's plan changes — even
  /// when the upgrade completed out-of-band in a browser, where no child
  /// modal pop would otherwise refresh the form). Requires [onRefresh] to be
  /// set; ignored otherwise.
  final Listenable? refreshOn;

  /// When true, the form modal renders a close (X) button in its header
  /// even when the form is the only modal on the stack. Default: false —
  /// the standard back-button-only header is shown when the form is
  /// nested inside another modal.
  final bool dismissable;

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

/// Multi-select form item backed by [SharedSelection] (contacts + groups +
/// invite emails). Looks and behaves like a [SelectTile]; tapping opens the
/// shared picker and the user can toggle multiple entries in one pass.
class FormShareSelect extends FormItem {
  FormShareSelect({
    required super.key,
    super.label,
    this.placeholder,
    this.priority,
    this.requireEmail = false,
    SharedSelection? initialValue,
  }) : _value = initialValue ?? const SharedSelection();

  /// Placeholder when nothing is selected.
  final String? placeholder;

  /// Optional priority for scoping contact suggestions (ranks people the
  /// user typically shares with in this priority first).
  final Priority? priority;

  /// When true, contacts without an email are hidden from the suggestion list
  /// (group editing).
  final bool requireEmail;

  SharedSelection _value;
  bool userModified = false;
  final List<VoidCallback> _listeners = [];

  /// Cache of (contact id → display name) and (group id → display name) so
  /// the tile summary can render even before the selection is resolved
  /// through DB lookups.
  final Map<Uuid, String> _contactNames = {};
  final Map<Uuid, String> _groupNames = {};
  bool _namesLoaded = false;

  @override
  SharedSelection getValue() => _value;

  @override
  void setValue(dynamic value) {
    if (value is SharedSelection) {
      _value = value;
      userModified = true;
      for (final listener in _listeners) {
        listener();
      }
    }
  }

  @override
  bool isValid() => true;

  @override
  bool get canActivate => true;

  @override
  void addChangeListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeChangeListener(VoidCallback listener) =>
      _listeners.remove(listener);

  Future<void> _ensureNamesLoaded() async {
    if (_namesLoaded) return;
    for (final id in _value.contacts) {
      if (_contactNames.containsKey(id)) continue;
      try {
        final actor = await Actor.getOne(ActorId.fromUuid(id));
        _contactNames[id] = actor.nameOrEmail;
      } catch (_) {}
    }
    for (final id in _value.groups) {
      if (_groupNames.containsKey(id)) continue;
      final group = await Group.getOne(id);
      if (group != null) _groupNames[id] = group.name;
    }
    _namesLoaded = true;
  }

  @override
  Future<void> activate(BuildContext context, {int subIndex = 0}) async {
    await _ensureNamesLoaded();
    if (!context.mounted) return;
    await PickShared(
      selection: _value,
      priority: priority,
      requireEmail: requireEmail,
      title: label ?? key,
      onUpdate: (next) async {
        _value = next;
        userModified = true;
        // Refresh name cache for any newly-added ids.
        for (final id in next.contacts) {
          if (_contactNames.containsKey(id)) continue;
          try {
            final actor = await Actor.getOne(ActorId.fromUuid(id));
            _contactNames[id] = actor.nameOrEmail;
          } catch (_) {}
        }
        for (final id in next.groups) {
          if (_groupNames.containsKey(id)) continue;
          final group = await Group.getOne(id);
          if (group != null) _groupNames[id] = group.name;
        }
        for (final listener in _listeners) {
          listener();
        }
      },
    ).run(context);
  }

  String get _summary => sharedSelectionSummary(
    _value,
    groupNames: _groupNames,
    contactNames: _contactNames,
  );

  @override
  Widget build(
    BuildContext context,
    int highlightedSubIndex, {
    bool enabled = true,
    List<FocusNode> focusNodes = const [],
    FormButtonController? controller,
  }) {
    return _FormShareSelectTile(
      formItem: this,
      highlighted: highlightedSubIndex >= 0,
      focusNode: focusNodes.firstOrNull,
      enabled: enabled,
    );
  }
}

class _FormShareSelectTile extends StatefulWidget {
  const _FormShareSelectTile({
    required this.formItem,
    required this.highlighted,
    required this.focusNode,
    required this.enabled,
  });

  final FormShareSelect formItem;
  final bool highlighted;
  final FocusNode? focusNode;
  final bool enabled;

  @override
  State<_FormShareSelectTile> createState() => _FormShareSelectTileState();
}

class _FormShareSelectTileState extends State<_FormShareSelectTile> {
  bool _namesLoaded = false;

  @override
  void initState() {
    super.initState();
    widget.formItem.addChangeListener(_onChanged);
    _loadNames();
  }

  @override
  void dispose() {
    widget.formItem.removeChangeListener(_onChanged);
    super.dispose();
  }

  Future<void> _loadNames() async {
    await widget.formItem._ensureNamesLoaded();
    if (!mounted) return;
    setState(() => _namesLoaded = true);
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final summary = _namesLoaded ? widget.formItem._summary : '';
    return SelectTile(
      label: widget.formItem.label ?? widget.formItem.key,
      value: summary.isEmpty ? null : summary,
      placeholder: widget.formItem.placeholder ?? 'No one',
      highlighted: widget.highlighted,
      enabled: widget.enabled,
      onSelect: () => widget.formItem.activate(context),
      focusNode: widget.focusNode,
    );
  }
}
