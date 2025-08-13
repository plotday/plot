import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/command/command.dart';
import 'theme.dart';
import 'colour_scheme.dart';

class PrioritiesTreeWidget extends StatefulWidget {
  final List<Priority> priorities;
  final void Function(Priority)? onPrioritySelected;

  const PrioritiesTreeWidget({
    super.key,
    required this.priorities,
    this.onPrioritySelected,
  });

  @override
  State<PrioritiesTreeWidget> createState() => _PrioritiesTreeWidgetState();
}

class _PrioritiesTreeWidgetState extends State<PrioritiesTreeWidget> {
  final Set<String> _expandedNodes = <String>{};
  bool _initializedExpansion = false;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (context, state) {
        if (widget.priorities.isEmpty) {
          return Center(
            child: Text(
              'No priorities found',
              style: context.theme.typography.base,
            ),
          );
        }

        // Initialize expansion state on first build
        if (!_initializedExpansion) {
          _initializeExpansion(widget.priorities);
          _initializedExpansion = true;
        }

        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: widget.priorities
                .map((priority) => _buildPriorityNode(priority, 0))
                .toList(),
          ),
        );
      },
    );
  }

  Widget _buildPriorityNode(Priority priority, int depth) {
    final hasChildren = priority.children.isNotEmpty;
    final isExpanded = _expandedNodes.contains(priority.id.toString());
    final currentState = context.read<PriorityBloc>().state;
    final isCurrentPriority = currentState.context.id == priority.id;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: EdgeInsets.only(left: depth * 16.0),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _handlePriorityTap(priority),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: widgetPaddingSm,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: isCurrentPriority
                      ? context.colour.accent.withValues(alpha: 0.1)
                      : null,
                ),
                child: Row(
                  children: [
                    if (hasChildren)
                      GestureDetector(
                        onTap: () => _toggleExpansion(priority.id.toString()),
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          child: Icon(
                            isExpanded
                                ? Icons.keyboard_arrow_down
                                : Icons.keyboard_arrow_right,
                            size: 16,
                            color: context.colour.accent,
                          ),
                        ),
                      )
                    else
                      const SizedBox(width: 20),
                    const SizedBox(width: 4),
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: (priority.color != null)
                            ? Color(priority.color!.index)
                            : context.colour.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        priority.title,
                        style: context.theme.typography.sm,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (hasChildren && isExpanded)
          ...priority.children.map(
            (child) => _buildPriorityNode(child, depth + 1),
          ),
      ],
    );
  }

  void _initializeExpansion(List<Priority> priorities) {
    for (final priority in priorities) {
      if (priority.children.isNotEmpty) {
        _expandedNodes.add(priority.id.toString());
        _initializeExpansion(priority.children);
      }
    }
  }

  void _toggleExpansion(String priorityId) {
    setState(() {
      if (_expandedNodes.contains(priorityId)) {
        _expandedNodes.remove(priorityId);
      } else {
        _expandedNodes.add(priorityId);
      }
    });
  }

  void _handlePriorityTap(Priority priority) {
    if (widget.onPrioritySelected != null) {
      widget.onPrioritySelected!(priority);
    } else {
      // Default behavior: change current priority
      ChangeCurrentPriority(priority).run(context);
    }
  }
}
