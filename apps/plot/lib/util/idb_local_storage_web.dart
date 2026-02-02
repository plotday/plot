// DO NOT import this file directly! Import 'idb_local_storage.dart' instead.
// Web implementation of LocalStorage using IndexedDB for session persistence.
// IndexedDB is not subject to Safari's ITP/localStorage clearing policies,
// so sessions survive mobile Safari's aggressive cleanup.
import 'dart:async';
import 'dart:js_interop';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web/web.dart';

const _dbName = 'supabase_auth';
const _storeName = 'sessions';
const _dbVersion = 1;

class IdbLocalStorage extends LocalStorage {
  final String persistSessionKey;

  const IdbLocalStorage({required this.persistSessionKey});

  @override
  Future<void> initialize() async {
    // Migrate from localStorage if IndexedDB doesn't have a session yet.
    final existing = await accessToken();
    if (existing == null) {
      final old = window.localStorage.getItem(persistSessionKey);
      if (old != null) {
        await persistSession(old);
        window.localStorage.removeItem(persistSessionKey);
      }
    }
  }

  @override
  Future<bool> hasAccessToken() async {
    final token = await accessToken();
    return token != null;
  }

  @override
  Future<String?> accessToken() async {
    final db = await _openDb();
    try {
      final tx = db.transaction(_storeName.toJS, 'readonly');
      final store = tx.objectStore(_storeName);
      final result = await _idbRequest(store.get(persistSessionKey.toJS));
      if (result == null || result.isUndefinedOrNull) return null;
      return (result as JSString).toDart;
    } finally {
      db.close();
    }
  }

  @override
  Future<void> removePersistedSession() async {
    final db = await _openDb();
    try {
      final tx = db.transaction(_storeName.toJS, 'readwrite');
      final store = tx.objectStore(_storeName);
      await _idbRequest(store.delete(persistSessionKey.toJS));
    } finally {
      db.close();
    }
  }

  @override
  Future<void> persistSession(String persistSessionString) async {
    final db = await _openDb();
    try {
      final tx = db.transaction(_storeName.toJS, 'readwrite');
      final store = tx.objectStore(_storeName);
      await _idbRequest(
        store.put(persistSessionString.toJS, persistSessionKey.toJS),
      );
    } finally {
      db.close();
    }
  }

  Future<IDBDatabase> _openDb() async {
    final request = window.indexedDB.open(_dbName, _dbVersion);
    request.onupgradeneeded = (Event event) {
      final db = request.result as IDBDatabase;
      if (!db.objectStoreNames.contains(_storeName)) {
        db.createObjectStore(_storeName);
      }
    }.toJS;
    final result = await _idbRequest(request);
    return result as IDBDatabase;
  }
}

/// Converts an IDBRequest to a Future by listening for success/error events.
Future<JSAny?> _idbRequest(IDBRequest request) {
  final completer = Completer<JSAny?>();
  request.onsuccess = (Event event) {
    completer.complete(request.result);
  }.toJS;
  request.onerror = (Event event) {
    completer.completeError(request.error ?? event);
  }.toJS;
  return completer.future;
}
