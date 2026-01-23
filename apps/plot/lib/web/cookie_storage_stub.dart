import 'package:supabase_flutter/supabase_flutter.dart';

/// Stub implementation of CookieLocalStorage for non-web platforms.
/// This is never actually used - native platforms use default storage.
class CookieLocalStorage extends LocalStorage {
  @override
  Future<void> initialize() async {}

  @override
  Future<String?> accessToken() async => null;

  @override
  Future<bool> hasAccessToken() async => false;

  @override
  Future<void> persistSession(String persistSessionString) async {}

  @override
  Future<void> removePersistedSession() async {}
}
