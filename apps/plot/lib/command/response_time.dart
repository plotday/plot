import 'package:plot/api/api.dart' as api;
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';
import 'package:plot/store/response_time.dart';

import 'base.dart';

class ShowResponseTimeSettings extends ShowForm {
  ShowResponseTimeSettings(this.priority)
    : super(
        title: 'Response time',
        icon: PlotIcon.later,
        form: (context) => _buildForm(priority),
      );

  final Priority priority;

  static Future<FormData> _buildForm(Priority priority) async {
    final windows = priority.responseWindows;
    final turnaround = priority.turnaroundTime;

    return FormData(
      title: 'Response time',
      groups: [
        StaticFormGroup(
          items: [
            FormInfo(
              key: 'window_header',
              text: priority.responseWindowSet
                  ? 'Response window (set on this priority)'
                  : windows != null
                      ? 'Response window (inherited)'
                      : 'Response window (not set)',
            ),
            if (windows != null)
              FormInfo(
                key: 'window_value',
                text: _formatWindows(windows),
              ),
            FormButton(
              key: 'set_window',
              buildCommand: (_) => _SetDefaultResponseWindow(priority),
            ),
            if (priority.responseWindowSet)
              FormButton(
                key: 'clear_window',
                buildCommand: (_) => ClearResponseWindow(priority.id),
              ),
            FormDivider(key: 'divider'),
            FormInfo(
              key: 'turnaround_header',
              text: priority.turnaroundSet
                  ? 'Turnaround time (set on this priority)'
                  : turnaround != null
                      ? 'Turnaround time (inherited)'
                      : 'Turnaround time (not set)',
            ),
            if (turnaround != null)
              FormInfo(
                key: 'turnaround_value',
                text: turnaround.displayLabel,
              ),
            FormButton(
              key: 'set_turnaround',
              buildCommand: (_) => _ShowSetTurnaroundForm(priority),
            ),
            if (priority.turnaroundSet)
              FormButton(
                key: 'clear_turnaround',
                buildCommand: (_) => ClearTurnaround(priority.id),
              ),
          ],
        ),
      ],
    );
  }

  static String _formatWindows(List<ResponseTimeWindow> windows) {
    const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return windows.map((w) {
      final days = w.days.map((d) => dayNames[d - 1]).join(', ');
      return '$days ${w.start}\u2013${w.end}';
    }).join('\n');
  }
}

class _SetDefaultResponseWindow extends Command {
  _SetDefaultResponseWindow(this.priority)
    : super(
        title: 'Set to business hours',
        icon: PlotIcon.later,
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
      );

  final Priority priority;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await api.post<Map<String, dynamic>>(
        '/sync/priority-response-time',
        body: {
          'priority_id': priority.id.toString(),
          'response_window': ResponseTimeWindow.defaultBusinessHours
              .map((w) => w.toJson())
              .toList(),
          'set_response_window': true,
          'set_turnaround': false,
        },
      );
      await Priority.pull();
      return const CommandDone();
    } on ApiException catch (e) {
      return CommandMessage(e.description, title: e.title, isError: true);
    } on NetworkException catch (e) {
      return CommandMessage('Network error: ${e.message}', isError: true);
    }
  }
}

class _ShowSetTurnaroundForm extends ShowForm {
  _ShowSetTurnaroundForm(this.priority)
    : super(
        title: 'Set turnaround time',
        icon: PlotIcon.later,
        form: (context) => _buildForm(priority),
      );

  final Priority priority;

  static Future<FormData> _buildForm(Priority priority) async {
    final current = priority.turnaroundTime;

    return FormData(
      title: 'Set turnaround time',
      groups: [
        StaticFormGroup(
          items: [
            FormTextInput(
              key: 'value',
              label: 'Value',
              initialValue: current?.value.toString() ?? '2',
              required: true,
            ),
            FormSelect<TurnaroundUnit>(
              key: 'unit',
              label: 'Unit',
              initialValue: current?.unit ?? TurnaroundUnit.days,
              hasInitialValue: true,
              items: (search) async => TurnaroundUnit.values
                  .where(
                    (u) =>
                        search == null ||
                        u.label.toLowerCase().contains(search.toLowerCase()),
                  )
                  .toList(),
              titleBuilder: (u) => u.label,
            ),
            FormButton(
              key: 'save',
              buildCommand: (values) {
                final valueStr = values['value'] as String;
                final value = int.tryParse(valueStr);
                final unit = values['unit'] as TurnaroundUnit;
                if (value == null || value <= 0) {
                  return _InvalidTurnaroundCommand();
                }
                return SetTurnaround(
                  priority.id,
                  TurnaroundTime(value: value, unit: unit),
                );
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _InvalidTurnaroundCommand extends Command {
  _InvalidTurnaroundCommand()
    : super(
        title: 'Save',
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    return const CommandMessage(
      'Please enter a valid number greater than 0',
      isError: true,
    );
  }
}

class SetResponseWindow extends Command {
  SetResponseWindow(this.priorityId, this.windows)
    : super(
        title: 'Set response window',
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
      );

  final PriorityId priorityId;
  final List<ResponseTimeWindow>? windows;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await api.post<Map<String, dynamic>>(
        '/sync/priority-response-time',
        body: {
          'priority_id': priorityId.toString(),
          'response_window': windows?.map((w) => w.toJson()).toList(),
          'set_response_window': true,
          'set_turnaround': false,
        },
      );
      await Priority.pull();
      return const CommandDone();
    } on ApiException catch (e) {
      return CommandMessage(e.description, title: e.title, isError: true);
    } on NetworkException catch (e) {
      return CommandMessage('Network error: ${e.message}', isError: true);
    }
  }
}

class SetTurnaround extends Command {
  SetTurnaround(this.priorityId, this.turnaround)
    : super(
        title: 'Set turnaround',
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
      );

  final PriorityId priorityId;
  final TurnaroundTime? turnaround;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await api.post<Map<String, dynamic>>(
        '/sync/priority-response-time',
        body: {
          'priority_id': priorityId.toString(),
          'turnaround': turnaround?.toJson(),
          'set_response_window': false,
          'set_turnaround': true,
        },
      );
      await Priority.pull();
      return const CommandDone();
    } on ApiException catch (e) {
      return CommandMessage(e.description, title: e.title, isError: true);
    } on NetworkException catch (e) {
      return CommandMessage('Network error: ${e.message}', isError: true);
    }
  }
}

class ClearResponseWindow extends Command {
  ClearResponseWindow(this.priorityId)
    : super(
        title: 'Clear response window',
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
      );

  final PriorityId priorityId;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await api.post<Map<String, dynamic>>(
        '/sync/priority-response-time',
        body: {
          'priority_id': priorityId.toString(),
          'response_window': null,
          'set_response_window': true,
          'set_turnaround': false,
        },
      );
      await Priority.pull();
      return const CommandDone();
    } on ApiException catch (e) {
      return CommandMessage(e.description, title: e.title, isError: true);
    } on NetworkException catch (e) {
      return CommandMessage('Network error: ${e.message}', isError: true);
    }
  }
}

class ClearTurnaround extends Command {
  ClearTurnaround(this.priorityId)
    : super(
        title: 'Clear turnaround',
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
      );

  final PriorityId priorityId;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await api.post<Map<String, dynamic>>(
        '/sync/priority-response-time',
        body: {
          'priority_id': priorityId.toString(),
          'turnaround': null,
          'set_response_window': false,
          'set_turnaround': true,
        },
      );
      await Priority.pull();
      return const CommandDone();
    } on ApiException catch (e) {
      return CommandMessage(e.description, title: e.title, isError: true);
    } on NetworkException catch (e) {
      return CommandMessage('Network error: ${e.message}', isError: true);
    }
  }
}
