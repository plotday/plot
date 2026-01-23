import 'dart:convert';

import 'package:web/web.dart' as web;

import 'package:supabase_flutter/supabase_flutter.dart';

/// Cookie-based LocalStorage implementation for web that reads Supabase session
/// from cookies set by plot.day (the marketing site).
///
/// This enables cross-subdomain authentication where signing in on plot.day
/// automatically authenticates the user on app.plot.day.
///
/// Cookie format used by @supabase/ssr:
/// - Cookie name: `sb-<project-ref>-auth-token` (or chunks with `.0`, `.1` suffix)
/// - Cookie value: `base64-<base64url-encoded-session-json>`
class CookieLocalStorage extends LocalStorage {
  String? _cachedSession;

  @override
  Future<void> initialize() async {
    // Read session from cookies on initialization
    _cachedSession = _readSessionFromCookies();
  }

  @override
  Future<String?> accessToken() async {
    // Return cached session, or try to read from cookies again
    _cachedSession ??= _readSessionFromCookies();
    return _cachedSession;
  }

  @override
  Future<bool> hasAccessToken() async {
    _cachedSession ??= _readSessionFromCookies();
    return _cachedSession != null;
  }

  @override
  Future<void> persistSession(String persistSessionString) async {
    // Cache locally but don't write to cookies - plot.day manages cookies
    _cachedSession = persistSessionString;
  }

  @override
  Future<void> removePersistedSession() async {
    _cachedSession = null;
    // Clear Supabase auth cookies on the root domain
    _clearSupabaseAuthCookies();
  }

  /// Reads the Supabase session from cookies.
  /// Handles both single cookies and chunked cookies (for large sessions).
  String? _readSessionFromCookies() {
    final cookies = _getAllCookies();

    // Find the Supabase auth cookie - it matches pattern: sb-*-auth-token
    // First, try to find the main cookie (non-chunked)
    String? authCookieName;
    for (final name in cookies.keys) {
      if (_isSupabaseAuthCookie(name) && !name.contains('.')) {
        authCookieName = name;
        break;
      }
    }

    // If no main cookie found, look for chunked cookies
    if (authCookieName == null) {
      for (final name in cookies.keys) {
        if (_isSupabaseAuthCookie(name) && name.endsWith('.0')) {
          // Found first chunk, extract base name
          authCookieName = name.substring(0, name.length - 2);
          break;
        }
      }
    }

    if (authCookieName == null) {
      return null;
    }

    // Try to read non-chunked value first
    String? value = cookies[authCookieName];

    // If not found, read chunked values
    if (value == null) {
      final chunks = <String>[];
      for (int i = 0;; i++) {
        final chunkName = '$authCookieName.$i';
        final chunkValue = cookies[chunkName];
        if (chunkValue == null) break;
        chunks.add(chunkValue);
      }
      if (chunks.isNotEmpty) {
        value = chunks.join('');
      }
    }

    if (value == null) {
      return null;
    }

    // Decode the session value
    return _decodeSessionValue(value);
  }

  /// Checks if a cookie name matches the Supabase auth cookie pattern.
  bool _isSupabaseAuthCookie(String name) {
    // Match pattern: sb-*-auth-token (with optional .N suffix for chunks)
    final baseName = name.contains('.') ? name.split('.').first : name;
    return baseName.startsWith('sb-') && baseName.endsWith('-auth-token');
  }

  /// Decodes a Supabase session cookie value.
  /// @supabase/ssr uses base64url encoding with a 'base64-' prefix.
  String? _decodeSessionValue(String value) {
    try {
      // Check for base64 prefix (used by @supabase/ssr)
      if (value.startsWith('base64-')) {
        final encoded = value.substring(7); // Remove 'base64-' prefix
        // base64url decode
        final decoded = _base64UrlDecode(encoded);
        return decoded;
      }

      // Try URL decoding for older format
      final decoded = Uri.decodeComponent(value);

      // Verify it's valid JSON
      jsonDecode(decoded);
      return decoded;
    } catch (e) {
      // If decoding fails, return null
      return null;
    }
  }

  /// Decodes a base64url encoded string (no padding).
  String _base64UrlDecode(String encoded) {
    // Convert base64url to base64
    var base64 = encoded.replaceAll('-', '+').replaceAll('_', '/');

    // Add padding if needed
    final padLength = (4 - base64.length % 4) % 4;
    base64 += '=' * padLength;

    final bytes = base64Decode(base64);
    return utf8.decode(bytes);
  }

  /// Gets all cookies as a map of name -> value.
  Map<String, String> _getAllCookies() {
    final cookies = <String, String>{};
    final cookieString = web.document.cookie;

    if (cookieString.isEmpty) {
      return cookies;
    }

    for (final cookie in cookieString.split('; ')) {
      final equalsIndex = cookie.indexOf('=');
      if (equalsIndex > 0) {
        final name = cookie.substring(0, equalsIndex);
        final value = cookie.substring(equalsIndex + 1);
        cookies[name] = value;
      }
    }

    return cookies;
  }

  /// Clears Supabase auth cookies on the root domain.
  void _clearSupabaseAuthCookies() {
    final cookies = _getAllCookies();

    for (final name in cookies.keys) {
      if (_isSupabaseAuthCookie(name)) {
        // Set cookie to expire in the past on both specific and root domain
        final expiry = 'Thu, 01 Jan 1970 00:00:00 GMT';
        web.document.cookie = '$name=; path=/; expires=$expiry';
        web.document.cookie =
            '$name=; path=/; domain=.plot.day; expires=$expiry';
      }
    }
  }
}
