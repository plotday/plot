/// Collects one catch-up sweep's timing for the `sync_catchup` analytics
/// event (prod p50/p95 dashboard for app-open sync latency). Installed as
/// [current] by Store's catch-up sweep and read by Store.pull; broadcast
/// subset syncs never install it. The sweep is coalesced (one at a time),
/// so a plain static is safe; concurrent broadcast-driven pulls landing
/// mid-sweep add slight noise, which is acceptable for a latency metric.
class SyncCatchupStats {
  SyncCatchupStats(this.trigger);

  static SyncCatchupStats? current;

  final String trigger;
  final Stopwatch _total = Stopwatch()..start();
  final Map<String, int> _waveMs = {};
  int _requests = 0;
  int _pages = 0;
  int _rows = 0;
  int _threadsMs = 0;
  int _notesMs = 0;

  /// Set by Store's catch-up sweep when the sweep errored (auth failure, RLS
  /// violation, or a transient network/5xx). A failed sweep often bails out
  /// early, so its `total_ms` is small — without this flag those short,
  /// failed runs skew the p50/p95 latency dashboard optimistically.
  bool failed = false;

  void recordPull(String entity, int ms, int pages, int rows) {
    // One HTTP request per page (prefetched first pages count as a page but
    // skip the HTTP call — rare outside per-thread fetches).
    _requests += pages;
    _pages += pages;
    _rows += rows;
    if (entity == 'threads') _threadsMs = ms;
    if (entity == 'notes') _notesMs = ms;
  }

  void recordWave(int index, int ms) => _waveMs['wave${index + 1}_ms'] = ms;

  Map<String, dynamic> finish() => {
        'trigger': trigger,
        'ok': !failed,
        'total_ms': _total.elapsedMilliseconds,
        'threads_ms': _threadsMs,
        'notes_ms': _notesMs,
        ..._waveMs,
        'requests': _requests,
        'pages': _pages,
        'rows_total': _rows,
      };
}
