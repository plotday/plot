import 'package:plot/command/priority.dart' show createPriorityInline;
import 'package:plot/style/plot_colors.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/scheduler.dart';
import 'package:plot/store/store.dart';

/// A modal for rescheduling an event, optionally allowing priority changes.
class RescheduleEventModal extends StatefulWidget {
  const RescheduleEventModal({
    required this.activity,
    this.showPrioritySelector = false,
    super.key,
  });

  final Thread activity;
  final bool showPrioritySelector;

  @override
  State<RescheduleEventModal> createState() => _RescheduleEventModalState();
}

class _RescheduleEventModalState extends State<RescheduleEventModal> {
  late DateTimeRange _currentRange;
  late DateTimeRange _initialRange;
  Priority? _selectedPriority;
  Priority? _initialPriority;
  FocusNode? _priorityFocusNode;

  @override
  void initState() {
    super.initState();
    _initialRange =
        widget.activity.at ??
        DateTimeRange(
          Time.now(),
          Time.now().add(const Duration(hours: 1)),
        );
    _currentRange = _initialRange;
    _selectedPriority = widget.activity.priority;
    _initialPriority = widget.activity.priority;
    if (widget.showPrioritySelector) {
      _priorityFocusNode = FocusNode();
      _priorityFocusNode!.addListener(_onFocusChange);
    }
  }

  @override
  void dispose() {
    _priorityFocusNode?.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    setState(() {}); // Rebuild when focus changes
  }

  bool get _timeChanged =>
      _currentRange.start != _initialRange.start ||
      _currentRange.end != _initialRange.end;

  bool get _priorityChanged => _selectedPriority?.id != _initialPriority?.id;

  bool get _hasChanged => _timeChanged || _priorityChanged;

  Future<void> _selectPriority() async {
    final result = await SelectModal.open<Priority>(
      context,
      items: (search) async {
        final priorities = Priority.excludePlot(
          await Priority.get(
            order: PriorityOrder.nested,
            search: search,
          ),
        );
        return [SelectGroup(title: null, items: priorities)];
      },
      itemBuilder: (priority, _) =>
          ListTile(body: PriorityLabel(priority: priority)),
      selectedValue: _selectedPriority,
      prompt: 'Priority',
      onAdd: (ctx) => createPriorityInline(ctx, parent: _selectedPriority),
    );

    if (result.present) {
      setState(() {
        _selectedPriority = result.value;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    String buttonText;
    if (_hasChanged) {
      buttonText = _priorityChanged ? 'Save' : 'Reschedule';
    } else {
      buttonText = 'Close';
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 370),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Scheduler(
            value: _currentRange,
            onChanged: (DateTimeRange newRange) {
              setState(() {
                _currentRange = newRange;
              });
            },
            allowPastTimes: true,
          ),
          if (widget.showPrioritySelector && _selectedPriority != null)
            IconInputRow(
              icon: PlotIcon.priority,
              content: FocusableActionDetector(
                focusNode: _priorityFocusNode,
                onFocusChange: (hasFocus) {
                  setState(() {});
                },
                mouseCursor: SystemMouseCursors.basic,
                child: GestureDetector(
                  onTap: _selectPriority,
                  child: Container(
                    decoration: BoxDecoration(
                      color: _priorityFocusNode?.hasFocus ?? false
                          ? theme.plotColors.editableBackground
                          : null,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    child: Center(
                      child: PriorityLabel(priority: _selectedPriority),
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 16),
          FButton(
            variant: FButtonVariant.secondary,
            child: Text(buttonText),
            onPress: () async {
              if (_hasChanged) {
                // Save priority change if it changed
                if (_priorityChanged && _selectedPriority != null) {
                  await widget.activity
                      .copyWith(priority: _selectedPriority)
                      .save();
                }

                if (!context.mounted) return;

                // Return the new range to trigger reschedule if time changed
                if (_timeChanged) {
                  Modal.pop(context, Value(_currentRange));
                } else {
                  // Just close if only priority changed
                  Modal.pop<DateTimeRange>(context, const Value.absent());
                }
              } else {
                // Just close without changes
                Modal.pop<DateTimeRange>(context, const Value.absent());
              }
            },
          ),
        ],
      ),
    );
  }
}
