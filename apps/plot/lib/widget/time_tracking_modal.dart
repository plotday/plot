import 'dart:async';

import 'package:flutter/material.dart' show OutlineInputBorder;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:rxdart/rxdart.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/modal.dart';
import 'package:plot/widget/priority.dart' show formatTrackedDuration;
import 'package:plot/widget/scroll_edge_fade.dart';

/// Modal showing weekly + per-day time totals for a single priority.
///
/// Two columns of values: "Just NAME" (this priority's own sessions,
/// editable inline as hours + minutes) and "Total" (the priority and all
/// its descendants combined, read-only). Grouped by week, descending in
/// time, with 7 day rows per week. Edits to the per-day "Just NAME" cell
/// are stored as `source='manual'` Session rows via
/// [Session.adjustDailyTime] — see that method for clamping/rounding
/// semantics.
///
/// Pages 8 weeks at a time for infinite scroll backwards in history.
class TimeTrackingModal extends Modal {
  TimeTrackingModal({required this.priority, super.key})
    : super(
        builder: (context) => _TimeTrackingBody(priority: priority),
        header: _TimeTrackingHeader(priority: priority),
      );

  final Priority priority;
}

// Fixed column widths so column headers, day rows, and week-summary rows
// line up vertically. Day label takes the remaining flex space.
const double _selfColumnWidth = 120;
const double _totalColumnWidth = 96;

class _TimeTrackingHeader extends StatelessWidget {
  const _TimeTrackingHeader({required this.priority});

  final Priority priority;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Padding(
        // Reserve space for the floating close button rendered by Modal.
        padding: const EdgeInsets.only(right: modalCloseButtonReservedWidth),
        child: Text(
          'Time on ${priority.title}',
          style: TextStyle(
            fontSize: context.theme.typography.lg.fontSize,
            fontWeight: FontWeight.w600,
            color: context.theme.colors.foreground,
          ),
        ),
      ),
    );
  }
}

class _TimeTrackingBody extends StatefulWidget {
  const _TimeTrackingBody({required this.priority});

  final Priority priority;

  @override
  State<_TimeTrackingBody> createState() => _TimeTrackingBodyState();
}

class _TimeTrackingBodyState extends State<_TimeTrackingBody> {
  // Number of weeks (going back from this week) currently rendered.
  int _weeksLoaded = 8;
  static const int _weeksPerPage = 8;

  void _loadMore() => setState(() => _weeksLoaded += _weeksPerPage);

  @override
  Widget build(BuildContext context) {
    // Watch enough history to cover the loaded window. The Session.watch
    // stream is local-only — no network — so this is cheap.
    final firstWeek = Week.current();
    final earliest = firstWeek.start - Duration(days: 7 * (_weeksLoaded - 1));
    final range = CustomBoundedDateRange(earliest, firstWeek.end);

    // Resolve descendants by path (canonical source) rather than the
    // in-memory `children` tree, which isn't fully hydrated on every
    // priority instance — see the docstring on
    // [Session.watchSelfAndDescendantIds].
    return StreamBuilder<(Set<PriorityId>, List<Session>)>(
      stream:
          Rx.combineLatest2<
            Set<PriorityId>,
            List<Session>,
            (Set<PriorityId>, List<Session>)
          >(
            Session.watchSelfAndDescendantIds(widget.priority),
            Session.watch(range: range),
            (ids, sessions) => (ids, sessions),
          ),
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) {
          return const SizedBox.shrink();
        }
        final allIds = data.$1;
        final hasDescendants = allIds.length > 1;
        final sessions = data.$2.where((s) => s.archivedAt == null).toList();

        final weeks = <Week>[];
        for (var i = 0; i < _weeksLoaded; i++) {
          weeks.add(Week(firstWeek.start - Duration(days: 7 * i)));
        }

        return Column(
          children: [
            _ColumnHeaders(
              priorityTitle: widget.priority.title,
              hasDescendants: hasDescendants,
            ),
            Expanded(
              child: ScrollEdgeFade(
                background: context.theme.colors.background,
                child: NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n is ScrollEndNotification &&
                        n.metrics.pixels >= n.metrics.maxScrollExtent - 80) {
                      _loadMore();
                    }
                    return false;
                  },
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    itemCount: weeks.length + 1,
                    itemBuilder: (context, idx) {
                      if (idx == weeks.length) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: FButton(
                            variant: FButtonVariant.ghost,
                            onPress: _loadMore,
                            child: const Text('Load earlier weeks'),
                          ),
                        );
                      }
                      return _WeekSection(
                        week: weeks[idx],
                        priority: widget.priority,
                        sessions: sessions,
                        allIds: allIds,
                        hasDescendants: hasDescendants,
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ColumnHeaders extends StatelessWidget {
  const _ColumnHeaders({
    required this.priorityTitle,
    required this.hasDescendants,
  });

  final String priorityTitle;
  final bool hasDescendants;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: context.theme.typography.xs.fontSize,
      fontWeight: FontWeight.w600,
      color: context.theme.colors.mutedForeground,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          const Expanded(child: SizedBox.shrink()),
          SizedBox(
            width: _selfColumnWidth,
            child: Text(
              'Just $priorityTitle',
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          if (hasDescendants)
            SizedBox(
              width: _totalColumnWidth,
              child: Text('Total', textAlign: TextAlign.right, style: style),
            ),
        ],
      ),
    );
  }
}

class _WeekSection extends StatelessWidget {
  const _WeekSection({
    required this.week,
    required this.priority,
    required this.sessions,
    required this.allIds,
    required this.hasDescendants,
  });

  final Week week;
  final Priority priority;
  final List<Session> sessions;
  final Set<PriorityId> allIds;
  final bool hasDescendants;

  @override
  Widget build(BuildContext context) {
    // Generate the 7 days in this week, newest first.
    final days = <Date>[];
    for (var d = 6; d >= 0; d--) {
      days.add(week.start + Duration(days: d));
    }

    // Per-day breakdown: (total-incl-descendants, self-only).
    final perDay = <Date, (Duration total, Duration self)>{};
    for (final day in days) {
      perDay[day] = _sumsForDay(day);
    }

    return _WeekRows(
      week: week,
      days: days,
      perDay: perDay,
      priority: priority,
      hasDescendants: hasDescendants,
    );
  }

  (Duration total, Duration self) _sumsForDay(Date day) {
    var total = Duration.zero;
    var self = Duration.zero;
    final start = day.toStart();
    final end = day.toEnd();
    for (final s in sessions) {
      // Bin by the session's local `start`. Multi-day sessions (rare for
      // active tracking) contribute their whole span to the day they
      // started in — same convention used by the weekly chip.
      if (s.start.isBefore(start) || s.start.isAfter(end)) continue;
      final pid = s.priorityId;
      if (pid == null || !allIds.contains(pid)) continue;
      final span = s.end.difference(s.start);
      if (span <= Duration.zero) continue;
      total += span;
      if (pid == priority.id) self += span;
    }
    return (total, self);
  }
}

/// Renders one week of rows. Stateful because we track per-day in-flight
/// edits so the week summary's "Just NAME" and "Total" cells update in
/// real time as the user types, before the underlying Session write
/// round-trips through the local DB stream.
class _WeekRows extends StatefulWidget {
  const _WeekRows({
    required this.week,
    required this.days,
    required this.perDay,
    required this.priority,
    required this.hasDescendants,
  });

  final Week week;
  final List<Date> days;
  final Map<Date, (Duration total, Duration self)> perDay;
  final Priority priority;
  final bool hasDescendants;

  @override
  State<_WeekRows> createState() => _WeekRowsState();
}

class _WeekRowsState extends State<_WeekRows> {
  // Overrides keyed by day: a non-null value means the user is mid-edit
  // (or the most recent commit hasn't landed in the stream yet) and the
  // input/summary should display this value instead of the prop's `self`.
  final Map<Date, Duration> _selfOverride = {};

  void _onSelfChanged(Date day, Duration value) {
    setState(() => _selfOverride[day] = value);
  }

  void _onSelfSettled(Date day, Duration committed) {
    // Once the stream catches up with the committed value, drop the
    // override so future external updates (e.g. sync) propagate.
    final prop = widget.perDay[day]?.$2 ?? Duration.zero;
    if (prop == committed) {
      setState(() => _selfOverride.remove(day));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;

    // Compute the effective per-day values using any active overrides.
    Duration effectiveSelf(Date day) =>
        _selfOverride[day] ?? widget.perDay[day]!.$2;
    Duration effectiveTotal(Date day) {
      final raw = widget.perDay[day]!;
      // descendants part of the total is (raw.total - raw.self); the
      // self part is replaced by the override when present.
      return (raw.$1 - raw.$2) + effectiveSelf(day);
    }

    var weekTotal = Duration.zero;
    var weekSelf = Duration.zero;
    for (final day in widget.days) {
      weekTotal += effectiveTotal(day);
      weekSelf += effectiveSelf(day);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Week header row — uses the same column layout as day rows so
        // the week totals align with the per-day "Just NAME" / "Total"
        // columns instead of floating to the right edge. Extra bottom
        // padding anchors the week as a heading over its days.
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 20, 0, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.week.format(),
                  style: TextStyle(
                    fontSize: theme.typography.sm.fontSize,
                    fontWeight: FontWeight.w600,
                    color: theme.colors.foreground,
                  ),
                ),
              ),
              SizedBox(
                width: _selfColumnWidth,
                child: Text(
                  weekSelf > Duration.zero
                      ? formatTrackedDuration(weekSelf)
                      : '',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: theme.typography.sm.fontSize,
                    fontWeight: FontWeight.w600,
                    color: theme.colors.foreground,
                  ),
                ),
              ),
              if (widget.hasDescendants)
                SizedBox(
                  width: _totalColumnWidth,
                  child: Text(
                    weekTotal > Duration.zero
                        ? formatTrackedDuration(weekTotal)
                        : '',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: theme.typography.sm.fontSize,
                      fontWeight: FontWeight.w600,
                      color: theme.colors.foreground,
                    ),
                  ),
                ),
            ],
          ),
        ),
        for (final day in widget.days)
          _DayRow(
            key: ValueKey(day),
            day: day,
            priority: widget.priority,
            propSelf: widget.perDay[day]!.$2,
            displayedTotal: effectiveTotal(day),
            hasDescendants: widget.hasDescendants,
            onSelfChanged: (v) => _onSelfChanged(day, v),
            onSelfSettled: (v) => _onSelfSettled(day, v),
          ),
      ],
    );
  }
}

class _DayRow extends StatefulWidget {
  const _DayRow({
    required Key key,
    required this.day,
    required this.priority,
    required this.propSelf,
    required this.displayedTotal,
    required this.hasDescendants,
    required this.onSelfChanged,
    required this.onSelfSettled,
  }) : super(key: key);

  final Date day;
  final Priority priority;
  final Duration propSelf;
  final Duration displayedTotal;
  final bool hasDescendants;
  final ValueChanged<Duration> onSelfChanged;
  final ValueChanged<Duration> onSelfSettled;

  @override
  State<_DayRow> createState() => _DayRowState();
}

class _DayRowState extends State<_DayRow> {
  late TextEditingController _hoursController;
  late TextEditingController _minutesController;
  late FocusNode _hoursFocus;
  late FocusNode _minutesFocus;

  // The value most recently committed (delta written). Used to compute
  // the next delta — without this, rapid keystrokes would each diff
  // against a stale prop and overshoot.
  Duration _lastCommitted = Duration.zero;
  Timer? _debounce;
  Future<void> _writeChain = Future.value();
  bool _suppressListener = false;

  @override
  void initState() {
    super.initState();
    _lastCommitted = widget.propSelf;
    final (h, m) = _split(widget.propSelf);
    _hoursController = TextEditingController(text: _formatField(h));
    _minutesController = TextEditingController(text: _formatField(m));
    _hoursFocus = FocusNode();
    _minutesFocus = FocusNode();
    _hoursController.addListener(_onTextChanged);
    _minutesController.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(_DayRow old) {
    super.didUpdateWidget(old);
    // External (stream-driven) update of the prop. Adopt it into the
    // input only if the user is not actively editing and there's no
    // pending debounced write — otherwise we'd clobber their typing.
    final editing =
        _hoursFocus.hasFocus || _minutesFocus.hasFocus || _debounce != null;
    if (!editing && widget.propSelf != _lastCommitted) {
      _lastCommitted = widget.propSelf;
      _setControllers(widget.propSelf);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _hoursController.dispose();
    _minutesController.dispose();
    _hoursFocus.dispose();
    _minutesFocus.dispose();
    super.dispose();
  }

  (int, int) _split(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes - h * 60;
    return (h, m);
  }

  // Render zero as empty (let the muted hint show through) so days with
  // no logged time don't shout "0h 0m" down the whole modal.
  String _formatField(int n) => n == 0 ? '' : n.toString();

  void _setControllers(Duration d) {
    _suppressListener = true;
    try {
      final (h, m) = _split(d);
      _hoursController.text = _formatField(h);
      _minutesController.text = _formatField(m);
    } finally {
      _suppressListener = false;
    }
  }

  Duration _parse() {
    final h = int.tryParse(_hoursController.text.trim()) ?? 0;
    final m = int.tryParse(_minutesController.text.trim()) ?? 0;
    final total = Duration(hours: h, minutes: m);
    return total < Duration.zero ? Duration.zero : total;
  }

  void _onTextChanged() {
    if (_suppressListener) return;
    final newSelf = _parse();
    widget.onSelfChanged(newSelf);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _commit);
  }

  void _commit() {
    _debounce = null;
    final newSelf = _parse();
    final delta = newSelf - _lastCommitted;
    if (delta == Duration.zero) {
      widget.onSelfSettled(newSelf);
      return;
    }
    _lastCommitted = newSelf;
    final priorityId = widget.priority.id;
    final day = widget.day;
    _writeChain = _writeChain.then((_) async {
      await Session.adjustDailyTime(
        priorityId: priorityId,
        day: day,
        delta: delta,
      );
      if (mounted) widget.onSelfSettled(newSelf);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final muted = theme.colors.mutedForeground;
    final fg = theme.colors.foreground;
    final smallFontSize = theme.typography.sm.fontSize;

    return Row(
      children: [
        Expanded(
          child: Text(
            widget.day.format(format: 'EEE, MMM d'),
            style: TextStyle(fontSize: smallFontSize, color: muted),
          ),
        ),
        SizedBox(
          width: _selfColumnWidth,
          child: _DurationFields(
            hoursController: _hoursController,
            minutesController: _minutesController,
            hoursFocus: _hoursFocus,
            minutesFocus: _minutesFocus,
          ),
        ),
        if (widget.hasDescendants)
          SizedBox(
            width: _totalColumnWidth,
            child: Text(
              widget.displayedTotal == Duration.zero
                  ? ''
                  : formatTrackedDuration(widget.displayedTotal),
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: smallFontSize, color: fg),
            ),
          ),
      ],
    );
  }
}

/// Compact `[hh] h [mm] m` input pair used in each day row's "Just NAME"
/// cell. No clamping, no chevrons — just two number fields. Empty is
/// treated as zero so days with no time show a calm hint instead of
/// "0h 0m" everywhere.
class _DurationFields extends StatelessWidget {
  const _DurationFields({
    required this.hoursController,
    required this.minutesController,
    required this.hoursFocus,
    required this.minutesFocus,
  });

  final TextEditingController hoursController;
  final TextEditingController minutesController;
  final FocusNode hoursFocus;
  final FocusNode minutesFocus;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 52,
          child: _field(
            controller: hoursController,
            focusNode: hoursFocus,
            suffix: 'h',
            theme: theme,
          ),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 52,
          child: _field(
            controller: minutesController,
            focusNode: minutesFocus,
            suffix: 'm',
            theme: theme,
          ),
        ),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required FocusNode focusNode,
    required String suffix,
    required FThemeData theme,
  }) {
    return FTextField(
      control: .managed(controller: controller),
      focusNode: focusNode,
      textAlign: TextAlign.right,
      keyboardType: const TextInputType.numberWithOptions(
        decimal: false,
        signed: false,
      ),
      hint: '0',
      style: FTextFieldStyleDelta.delta(
        contentPadding: EdgeInsetsGeometryDelta.value(
          const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        ),
        border: FVariantsValueDelta.delta([
          FVariantValueDeltaOperation.all(
            const OutlineInputBorder(
              borderSide: BorderSide(width: 0, style: BorderStyle.none),
            ),
          ),
        ]),
      ),
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(3),
      ],
      suffixBuilder: (_, _, _) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Text(
          suffix,
          style: theme.typography.sm.copyWith(
            color: theme.colors.mutedForeground,
          ),
        ),
      ),
    );
  }
}
