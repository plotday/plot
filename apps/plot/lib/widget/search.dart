import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'icon.dart';

/// Toggleable search widget that displays a search icon or input field.
/// Uses debouncing to avoid excessive queries.
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
    // Cancel previous timer
    _debounceTimer?.cancel();

    // Create new timer with 250ms delay
    _debounceTimer = Timer(const Duration(milliseconds: 250), () {
      final search = _controller.text;
      widget.onSearchChanged(search);
    });
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
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
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
                  controller: _controller,
                  focusNode: _focusNode,
                  hint: 'Search...',
                  style: (style) => style.copyWith(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            FButton.icon(
              style: FButtonStyle.ghost(),
              onPress: _toggle,
              child: Icon(PlotIcon.close, size: 14),
            ),
          ],
        ),
      );
    }

    return FButton.icon(
      style: FButtonStyle.ghost(),
      onPress: _toggle,
      child: Icon(PlotIcon.search, size: 14),
    );
  }
}
