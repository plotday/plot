import 'package:flutter/widgets.dart' hide Action, Actions;
import 'package:flutter/widgets.dart' as flutter_widgets show Actions, CallbackAction, KeyEventResult;
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import 'package:plot/action/action.dart';
import 'package:plot/widget/bidirectional_list.dart';
import 'dialog.dart';
import 'theme.dart';
import 'logging.dart';

class FormBar extends Dialog {
  FormBar(
    FormData form, {
    required BuildContext rootContext,
  }) : super(
         padding: const EdgeInsets.all(0),
         builder: (_) => _FormBar(
           form,
           rootContext: rootContext,
         ),
         key: ObjectKey(form),
       );

  Future<ActionReturn> run(BuildContext context) {
    return super
        .show<ActionReturn>(context)
        .then((value) => value.present ? value.value : const ActionSkipped());
  }
}

class _FormBar extends StatefulWidget {
  const _FormBar(
    this.form, {
    required this.rootContext,
  });

  final FormData form;
  final BuildContext rootContext;

  @override
  FormBarState createState() => FormBarState();
}

class FormBarState extends State<_FormBar> {
  List<StaticFormGroup> _formGroups = [];
  String? _error;
  bool _isDisposed = false;
  int _highlightedIndex = 0; // Track highlighted item for keyboard navigation

  @override
  void initState() {
    super.initState();
    _initForm();
  }

  @override
  void dispose() {
    _isDisposed = true;
    // Remove listeners and dispose all form text input controllers
    for (var group in _formGroups) {
      for (var item in group.items) {
        if (item is FormTextInput) {
          item.controller.removeListener(_onFormChanged);
          item.dispose();
        }
      }
    }
    super.dispose();
  }

  void _initForm() async {
    try {
      setState(() {
        _error = null;
      });
      final formGroups = await widget.form.list();

      if (_isDisposed) return;

      setState(() {
        _formGroups = formGroups;
        // Auto-focus first item
        _highlightedIndex = 0;
      });

      // Add listeners to all text input controllers to rebuild on changes
      for (var group in _formGroups) {
        for (var item in group.items) {
          if (item is FormTextInput) {
            item.controller.addListener(_onFormChanged);
          }
        }
      }
    } catch (e, t) {
      log.warning('Error initializing form', e, t);
      if (!_isDisposed) {
        setState(() {
          _error = 'Form initialization failed.';
        });
      }
    }
  }

  void _onFormChanged() {
    if (mounted) {
      setState(() {
        // Rebuild to update button enabled state
      });
    }
  }

  int _allItemsCount() {
    return _formGroups.fold(
      0,
      (total, group) => total + group.items.length,
    );
  }

  void _moveHighlight(int offset) {
    setState(() {
      final totalCount = _allItemsCount();
      if (totalCount == 0) return;

      _highlightedIndex = (_highlightedIndex + offset).clamp(0, totalCount - 1);
    });
  }

  FormItem _getItemAtIndex(int index) {
    int currentIndex = 0;
    for (var group in _formGroups) {
      for (var item in group.items) {
        if (currentIndex == index) {
          return item;
        }
        currentIndex++;
      }
    }
    throw RangeError('Index $index out of range');
  }

  StaticFormGroup _getGroupAtIndex(int index) {
    int currentIndex = 0;
    for (var group in _formGroups) {
      for (var _ in group.items) {
        if (currentIndex == index) {
          return group;
        }
        currentIndex++;
      }
    }
    throw RangeError('Index $index out of range');
  }

  /// Check if all required fields are valid
  bool _isFormValid() {
    for (var group in _formGroups) {
      for (var item in group.items) {
        if (!item.isValid()) {
          return false;
        }
      }
    }
    return true;
  }

  /// Collect all form values into a map
  Map<String, dynamic> _collectFormValues() {
    final Map<String, dynamic> values = {};
    for (var group in _formGroups) {
      for (var item in group.items) {
        if (item is! FormButton) {
          values[item.key] = item.getValue();
        }
      }
    }
    return values;
  }

  /// Find the first button (primary button)
  FormButton? _getPrimaryButton() {
    for (var group in _formGroups) {
      for (var item in group.items) {
        if (item is FormButton) {
          return item;
        }
      }
    }
    return null;
  }

  /// Execute form submission (triggered by Enter key or button click)
  Future<void> _submitForm() async {
    if (!_isFormValid()) {
      setState(() {
        _error = 'Please fill in all required fields';
      });
      return;
    }

    final primaryButton = _getPrimaryButton();
    if (primaryButton == null || primaryButton.onSubmit == null) {
      return;
    }

    setState(() {
      _error = null;
    });

    try {
      final values = _collectFormValues();
      final result = await primaryButton.onSubmit!(widget.rootContext, values);

      if (!mounted) return;

      if (result is ActionMessage && result.isError) {
        setState(() {
          _error = result.message;
        });
        return;
      }

      Dialog.popAll(context);
      if (context.mounted && result is ActionRoute) {
        result.go(widget.rootContext);
      }
    } catch (e, stackTrace) {
      log.warning('Error submitting form', e, stackTrace);
      if (mounted) {
        setState(() {
          _error = 'Something went wrong';
        });
      }
    }
  }

  /// Execute a specific button action
  Future<ActionReturn> _executeButton(FormButton button) async {
    if (!_isFormValid()) {
      setState(() {
        _error = 'Please fill in all required fields';
      });
      return const ActionDone();
    }

    setState(() {
      _error = null;
    });

    try {
      if (button.onSubmit != null) {
        final values = _collectFormValues();
        final result = await button.onSubmit!(widget.rootContext, values);

        if (!mounted) return const ActionSkipped();

        if (result is ActionMessage && result.isError) {
          setState(() {
            _error = result.message;
          });
          return const ActionDone();
        }

        Dialog.popAll(context);
        if (context.mounted && result is ActionRoute) {
          result.go(widget.rootContext);
        }
        return result;
      } else {
        // Fallback to action's run method
        final result = await button.action.run(widget.rootContext);
        if (!mounted) return const ActionSkipped();

        if (result is ActionMessage && result.isError) {
          setState(() {
            _error = result.message;
          });
          return const ActionDone();
        }

        Dialog.popAll(context);
        if (context.mounted && result is ActionRoute) {
          result.go(widget.rootContext);
        }
        return result;
      }
    } catch (e, stackTrace) {
      log.warning('Error executing button', e, stackTrace);
      if (mounted) {
        setState(() {
          _error = 'Something went wrong';
        });
      }
    }
    return const ActionDone();
  }

  @override
  Widget build(BuildContext context) {
    Widget? errorBox;
    if (_error != null) {
      errorBox = Container(
        padding: const EdgeInsets.all(8),
        child: Text(_error!),
      );
    }

    final totalItemCount = _allItemsCount();

    return BidirectionalListSelector(
      key: ValueKey(totalItemCount),
      onActivate: (index) async {
        final item = _getItemAtIndex(index);
        if (item is FormButton) {
          await _executeButton(item);
        } else if (item is FormTextInput) {
          // Enter key in text input triggers form submission
          await _submitForm();
        }
      },
      builder: (context, listController) => Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowUp): MoveListSelectionIntent(-1),
          SingleActivator(LogicalKeyboardKey.arrowDown): MoveListSelectionIntent(1),
          SingleActivator(LogicalKeyboardKey.enter): ActivateListSelectionIntent(),
        },
        child: flutter_widgets.Actions(
          actions: {
            MoveListSelectionIntent: flutter_widgets.CallbackAction<MoveListSelectionIntent>(
              onInvoke: (intent) {
                _moveHighlight(intent.offset);
                return flutter_widgets.KeyEventResult.handled;
              },
            ),
            ActivateListSelectionIntent: flutter_widgets.CallbackAction<ActivateListSelectionIntent>(
              onInvoke: (intent) {
                if (_allItemsCount() > 0) {
                  final item = _getItemAtIndex(_highlightedIndex);
                  if (item is FormButton) {
                    if (_isFormValid()) {
                      _executeButton(item);
                    }
                  } else if (item is FormTextInput) {
                    _submitForm();
                  }
                  return flutter_widgets.KeyEventResult.handled;
                }
                return flutter_widgets.KeyEventResult.ignored;
              },
            ),
          },
          child: SizedBox.expand(
            child: Column(
              children: [
                // Title header
                Container(
                  padding: widgetPadding,
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: context.theme.colors.border,
                        width: 1,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.form.title,
                          style: context.theme.typography.base.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (errorBox != null) errorBox,
                Expanded(
                  child: BidirectionalList(
                    controller: listController,
                    count: totalItemCount,
                    builder: (context, index, focusNode) {
                      final group = _getGroupAtIndex(index);
                      final item = _getItemAtIndex(index);
                      Widget? header;

                      if (group.title != null &&
                          (index == 0 ||
                              group != _getGroupAtIndex(index - 1))) {
                        header = Padding(
                          padding: widgetPaddingSm,
                          child: Text(
                            group.title!,
                            style: TextStyle(
                              color: context.theme.colors.mutedForeground,
                              fontSize: context.theme.typography.xs.fontSize,
                            ),
                          ),
                        );
                      }

                      return Column(
                        key: ValueKey(index),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (header != null) header,
                          item.build(
                            context,
                            index == _highlightedIndex,
                            enabled: item is FormButton ? _isFormValid() : true,
                          ),
                        ],
                      );
                    },
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
