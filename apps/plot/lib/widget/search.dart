import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:provider/provider.dart';
import 'package:forui/forui.dart';

import 'package:plot/state/priority.dart';

/// Toggleable search widget that displays a search icon or input field.
/// Uses debouncing to avoid excessive queries.
class SearchWidget extends StatefulWidget {
  const SearchWidget({super.key});

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
      try {
        final priorityBloc = context.read<PriorityBloc>();
        priorityBloc.updateSearch(search);
      } on ProviderNotFoundException {
        // PriorityBloc not in scope
      }
    });
  }

  void _toggle() {
    setState(() {
      _isExpanded = !_isExpanded;
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

  @override
  Widget build(BuildContext context) {
    if (_isExpanded) {
      return SizedBox(
        width: 200,
        child: Row(
          children: [
            Expanded(
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
            const SizedBox(width: 4),
            FTappable(
              onPress: _toggle,
              child: Icon(Icons.close, size: 14),
            ),
          ],
        ),
      );
    }

    return FTappable(
      onPress: _toggle,
      child: Icon(Icons.search, size: 14),
    );
  }
}
