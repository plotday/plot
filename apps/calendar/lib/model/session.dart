import 'model.dart';
import 'context.dart';
import 'package:plot/util/time.dart';

class Session extends Model {
  static const threshold = Duration(minutes: 5);

  // We keep one session above the threshold and everything newer, with the
  // newest session first.
  static List<Session> _cache = [];

  static final store = SingleStore<Session?>(load: () async {
    try {
      await Context.store.load();
      final rows = await base
          .from('session')
          .select()
          .eq('user_id', base.auth.currentUser!.id)
          .order('at', ascending: false)
          .limit(10);
      _cache = rows.map(Session.fromJson).toList();
      _cache.sort((a, b) => b.at.end.compareTo(a.at.end));
      bool found = false;
      _cache = _cache.takeWhile((session) {
        if (found) return false;
        if (session.at.duration >= threshold) {
          found = true;
        }
        return true;
      }).toList();
      return _cache.firstOrNull;
    } catch (e) {
      print('Loading sessions failed');
      print(e);
    }
    return null;
  });

  static Session startOrContinue(Context? context, DateTime? end) {
    final now = DateTime.now();
    return _cache
        .firstWhere(
          (session) => session.context == context,
          orElse: () => Session(
            context: context,
            at: DateTimeRange(now, end ?? now),
          ),
        )
        .copyWith(end: end ?? now);
  }

  const Session({
    super.id,
    required this.context,
    required this.at,
    this.pomodoroStart,
    this.pomodoroLength,
    Duration? paused,
  }) : paused = paused ?? Duration.zero;

  Session.fromJson(Map<String, dynamic> json)
      : context = json['context_id']
            ? Context.store.get(json['context_id'] as int)
            : null,
        at = DateTimeRange.fromString(json['at'] as String),
        paused = durationFromString(json['planned'] as String),
        pomodoroStart = json['pomodoro_start']
            ? DateTime.parse(json['pomodoro_start'] as String)
            : null,
        pomodoroLength = json['pomodoro_length']
            ? durationFromString(json['pomodoro_length'] as String)
            : null,
        super(id: json['id'] as int);

  final Context? context;
  final DateTimeRange at;
  final Duration paused;
  final DateTime? pomodoroStart;
  final Duration? pomodoroLength;

  @override
  List<Object?> get props =>
      super.props +
      [context?.id ?? 0, at, paused, pomodoroStart ?? 0, pomodoroLength ?? 0];

  Session copyWith({
    DateTime? end,
    DateTime? pomodoroStart,
    Duration? pomodoroLength,
  }) {
    final at = end == null ? this.at : DateTimeRange(this.at.start, end);
    return Session(
      id: id,
      context: context,
      at: at,
      paused: paused,
      pomodoroStart: pomodoroStart ?? this.pomodoroStart,
      pomodoroLength: pomodoroLength ?? this.pomodoroLength,
    );
  }

  Session copyStopped() {
    return copyWith(
      end: DateTime.now(),
    );
  }

  static void _updateCache(List<Session> sessions) {
    // Insert session into _cache, ordered by at.end (descending).
    for (final session in sessions) {
      _cache = [
        ..._cache.where(
            (s) => s.id != session.id && s.at.end.isAfter(session.at.end)),
        session,
        ..._cache.where(
            (s) => s.id != session.id && s.at.end.isBefore(session.at.end)),
      ];
    }
    if (_cache.first != store.get()) {
      store.set(_cache.first);
    }
  }

  static Future<List<Session>> saveList(List<Session> items) async {
    _updateCache(items);
    final newItems =
        await Model.saveListToBase(items, 'session', Session.fromJson);
    _updateCache(newItems);
    return newItems;
  }

  @override
  Future<Session> save() async {
    final [session] = await saveList([this]);
    return session;
  }

  Duration get duration => at.end.diff(at.start);

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'user_id': base.auth.currentUser!.id,
        'context_id': context?.id,
        'at': at.toString(),
        'pomodoro_start': pomodoroStart?.toIso8601String(),
        'pomodoro_length': pomodoroLength?.toDb(),
      };
}
