// DO NOT import this file directly! Import 'idb_local_storage.dart' instead.
// Stub for non-web platforms. The custom LocalStorage is only used on web;
// native platforms use the default SharedPreferences-based storage.
import 'package:supabase_flutter/supabase_flutter.dart';

class IdbLocalStorage extends LocalStorage {
  final String persistSessionKey;

  const IdbLocalStorage({required this.persistSessionKey});

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() async => false;

  @override
  Future<String?> accessToken() async => null;

  @override
  Future<void> removePersistedSession() async {}

  @override
  Future<void> persistSession(String persistSessionString) async {}
}
