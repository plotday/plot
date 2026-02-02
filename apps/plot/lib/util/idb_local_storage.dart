// IMPORTANT: Always import this file (idb_local_storage.dart) instead of
// idb_local_storage_stub.dart or idb_local_storage_web.dart directly.
// This file automatically exports the correct platform-specific implementation:
// - idb_local_storage_stub.dart for native platforms (no-op)
// - idb_local_storage_web.dart for web (uses IndexedDB)
export 'idb_local_storage_stub.dart'
    if (dart.library.js_interop) 'idb_local_storage_web.dart';
