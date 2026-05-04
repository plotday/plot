import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/plot_icon_sizes.dart';
import 'icon.dart';

/// Toggleable search widget that displays a search icon or input field.
/// Uses throttling to keep results streaming in while the user types
/// without overloading the database.
/// When expanded, it takes the full width of the header.
class SearchWidget extends StatefulWidget {
  const SearchWidget({
    required this.onSearchChanged,
    this.onExpandChanged,
    super.key,
  });

  final void Function(String) onSearchChanged;
  final void Function(bool)? onExpandChanged;

  @override
  State<SearchWidget> createState() => _SearchWidgetState();
}

class _SearchWidgetState extends State<SearchWidget> {
  bool _isExpanded = false;
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    // Listen to changes and apply debouncing
    _controller.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onSearchChanged);
    _controller.dispose();
    _focusNode.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _onSearchChanged() {
    final search = _controller.text;

    // Clearing the box should feel instant.
    if (search.isEmpty) {
      _debounceTimer?.cancel();
      widget.onSearchChanged('');
      return;
    }

    // Throttle with trailing edge: first keystroke arms a 500 ms timer;
    // further keystrokes during the window are absorbed (no reset). When
    // it fires, the callback receives the latest controller text. The
    // next keystroke arms a fresh window, so continued typing yields one
    // update per ~500 ms and the final text always gets searched.
    if (_debounceTimer == null || !_debounceTimer!.isActive) {
      _debounceTimer = Timer(const Duration(milliseconds: 500), () {
        widget.onSearchChanged(_controller.text);
      });
    }
  }

  void _toggle() {
    setState(() {
      _isExpanded = !_isExpanded;
      widget.onExpandChanged?.call(_isExpanded);
      if (_isExpanded) {
        // Focus the text field when expanding
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _focusNode.requestFocus();
        });
      } else {
        // Clear search when collapsing
        _controller.clear();
      }
    });
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _toggle();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (_isExpanded) {
      return Expanded(
        child: Row(
          children: [
            Expanded(
              child: Focus(
                onKeyEvent: _handleKeyEvent,
                child: FTextField(
                  control: .managed(controller: _controller),
                  focusNode: _focusNode,
                  hint: 'Search...',
                  style: FTextFieldStyleDelta.delta(
                    contentPadding: EdgeInsetsGeometryDelta.value(
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            FButton.icon(
              variant: FButtonVariant.ghost,
              onPress: _toggle,
              child: Icon(PlotIcon.close, size: context.theme.iconSizes.sm),
            ),
          ],
        ),
      );
    }

    return FButton.icon(
      variant: FButtonVariant.ghost,
      onPress: _toggle,
      child: Icon(PlotIcon.search, size: context.theme.iconSizes.sm),
    );
  }
}
