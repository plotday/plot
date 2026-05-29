import 'package:plot/command/command.dart';
import 'package:plot/store/store.dart' hide PriorityBlock;
import 'package:plot/style/plot_colors.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/scheduler.dart';

/// Modal for creating or editing a user-scheduled "focus block" — an
/// explicit block of time on a priority at a chosen day, start time, and
/// duration. Backed by a `priority_block` row carrying `effective_at` =
/// block start and `duration` = block length.
///
/// Construct via [ScheduleFocusModal.create] (date pre-filled, priority
/// and duration empty) or [ScheduleFocusModal.edit] (all fields pre-filled
/// from an existing row + a Delete affordance that soft-archives it).
class ScheduleFocusModal extends StatefulWidget {
  const ScheduleFocusModal._({
    required this.initialDate,
    required this.initialPriority,
    required this.initialRange,
    required this.initialDuration,
    this.existingRow,
    super.key,
  });

  /// Open the modal in create mode. The block defaults to today (or
  /// [date] when provided) starting at the next 15-minute boundary with
  /// a 30-minute duration. The priority defaults to [defaultPriority]
  /// (typically the active priority context) and the user can re-pick.
  factory ScheduleFocusModal.create({
    Date? date,
    Priority? defaultPriority,
    Key? key,
  }) {
    final base = date?.toDateTime() ?? Date.today().toDateTime();
    final now = Time.now();
    DateTime start = _isToday(base)
        ? _snapForward(now)
        : DateTime(base.year, base.month, base.day, 9, 0);
    const duration = Duration(minutes: 30);
    final range = DateTimeRange(start, start.add(duration));
    return ScheduleFocusModal._(
      initialDate: date ?? Date(base.year, base.month, base.day),
      initialPriority: defaultPriority,
      initialRange: range,
      initialDuration: duration,
      key: key,
    );
  }

  /// Open the modal in edit mode for an existing focus block row.
  factory ScheduleFocusModal.edit({
    required PriorityBlockRow row,
    required Priority priority,
    Key? key,
  }) {
    final duration = row.duration ?? const Duration(minutes: 30);
    final start = row.effectiveAt;
    final range = DateTimeRange(start, start.add(duration));
    return ScheduleFocusModal._(
      initialDate: Date(start.year, start.month, start.day),
      initialPriority: priority,
      initialRange: range,
      initialDuration: duration,
      existingRow: row,
      key: key,
    );
  }

  final Date initialDate;
  final Priority? initialPriority;
  final DateTimeRange initialRange;
  final Duration initialDuration;
  final PriorityBlockRow? existingRow;

  static DateTime _snapForward(DateTime m) {
    final remainder = m.minute % 15;
    final pad = remainder == 0 ? 0 : 15 - remainder;
    return DateTime(m.year, m.month, m.day, m.hour, m.minute + pad);
  }

  static bool _isToday(DateTime d) {
    final today = Date.today();
    return d.year == today.year &&
        d.month == today.month &&
        d.day == today.day;
  }

  @override
  State<ScheduleFocusModal> createState() => _ScheduleFocusModalState();
}

class _ScheduleFocusModalState extends State<ScheduleFocusModal> {
  late DateTimeRange _range;
  Priority? _priority;
  FocusNode? _priorityFocusNode;

  bool get _isEdit => widget.existingRow != null;

  @override
  void initState() {
    super.initState();
    _range = widget.initialRange;
    _priority = widget.initialPriority;
    _priorityFocusNode = FocusNode();
    _priorityFocusNode!.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _priorityFocusNode?.dispose();
    super.dispose();
  }

  void _onFocusChange() => setState(() {});

  Future<void> _selectPriority() async {
    final result = await SelectModal.open<Priority>(
      context,
      items: (search) async {
        final priorities = await Priority.get(order: PriorityOrder.nested);
        return [SelectGroup(title: null, items: priorities)];
      },
      itemBuilder: (priority, _) =>
          ListTile(body: PriorityLabel(priority: priority)),
      selectedValue: _priority,
      prompt: 'Priority',
      onAdd: (ctx) => createPriorityInline(ctx, parent: _priority),
      filter: (priority, search) => priority.matchesSearch(search),
    );

    if (result.present) {
      setState(() {
        _priority = result.value;
      });
    }
  }

  bool get _canSave {
    if (_priority == null) return false;
    final start = _range.start;
    final end = _range.end;
    if (start == null || end == null) return false;
    if (!end.isAfter(start)) return false;
    return true;
  }

  Duration get _currentDuration {
    final start = _range.start;
    final end = _range.end;
    if (start == null || end == null) return widget.initialDuration;
    final d = end.difference(start);
    return d <= Duration.zero ? widget.initialDuration : d;
  }

  Future<void> _onSave() async {
    if (!_canSave) {
      Modal.pop<void>(context, const Value.absent());
      return;
    }
    final command = ScheduleFocusBlock(
      priorityId: _priority!.id,
      start: _range.start!,
      duration: _currentDuration,
      existingRow: widget.existingRow,
    );
    final result = await command.run(context);
    if (!mounted) return;
    if (result is CommandMessage && result.isError) {
      context.showOverlayToast(message: result.message, isError: true);
      return;
    }
    Modal.pop<void>(context, const Value(null));
  }

  Future<void> _onDelete() async {
    final existing = widget.existingRow;
    if (existing == null) return;
    final command = ArchiveFocusBlock(row: existing);
    await command.run(context);
    if (!mounted) return;
    Modal.pop<void>(context, const Value(null));
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final selectedPriority = _priority;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 370),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconInputRow(
            icon: PlotIcon.priority,
            content: FocusableActionDetector(
              focusNode: _priorityFocusNode,
              onFocusChange: (_) => setState(() {}),
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
                    child: selectedPriority == null
                        ? Text(
                            'Select priority',
                            style: TextStyle(
                              color: theme.colors.mutedForeground,
                            ),
                          )
                        : PriorityLabel(priority: selectedPriority),
                  ),
                ),
              ),
            ),
          ),
          Scheduler(
            value: _range,
            onChanged: (newRange) {
              setState(() {
                _range = newRange;
              });
            },
            allowPastTimes: _isEdit,
          ),
          const SizedBox(height: 16),
          FButton(
            variant: FButtonVariant.secondary,
            onPress: _canSave ? _onSave : null,
            child: Text(_isEdit ? 'Save' : 'Schedule'),
          ),
          if (_isEdit) ...[
            const SizedBox(height: 8),
            FButton(
              variant: FButtonVariant.outline,
              onPress: _onDelete,
              child: const Text('Delete'),
            ),
          ],
        ],
      ),
    );
  }
}
