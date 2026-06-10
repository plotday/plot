import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

/// Opens the Plot database on web. Unchanged from the original
/// `driftDatabase` configuration — the WAL + read-pool setup in
/// `open_connection_native.dart` is a native-only optimization (the wasm
/// build runs in a single worker and doesn't support a read pool).
QueryExecutor openPlotConnection(String name) {
  return driftDatabase(
    name: name,
    web: DriftWebOptions(
      sqlite3Wasm: Uri.parse('sqlite3.wasm'),
      driftWorker: Uri.parse('drift_worker.js'),
    ),
  );
}
