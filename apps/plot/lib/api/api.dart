import 'dart:convert';
import 'package:http/http.dart' as http;

import 'package:plot/base.dart';
import 'package:plot/env.dart';
import 'package:plot/logging.dart';

bool _isJsonContentType(String? contentType) {
  if (contentType == null) return false;
  return contentType.toLowerCase().contains('application/json');
}

T _parseResponse<T>(http.Response response) {
  if (_isJsonContentType(response.headers['content-type'])) {
    return jsonDecode(response.body) as T;
  } else if (T is String) {
    return response.body as T;
  } else {
    throw Exception(
      'Unsupported content type: ${response.headers['content-type']}',
    );
  }
}

/// Checks response for auth errors and signs out on 401 (Unauthorized)
/// Note: 403 (Forbidden) means user is authenticated but not authorized,
/// so we just let it throw - the calling code can display an error to the user
Future<void> _checkAuthError(http.Response response, String url) async {
  if (response.statusCode == 401) {
    log.warning(
      "Auth error from API: 401 Unauthorized $url ${response.body}",
    );
    try {
      await Base.client.auth.signOut();
    } catch (e, stackTrace) {
      log.warning("Error during auth failure sign-out", e, stackTrace);
    }
  }
}

Map<String, String> getHeaders() {
  final auth =
      'Bearer ${Base.client.auth.currentSession?.accessToken}/${Base.client.auth.currentSession?.refreshToken}';
  return {
    'Content-Type': 'application/json; charset=UTF-8',
    'Authorization': auth,
  };
}

Future<T> post<T>(String url, {Map<String, dynamic> body = const {}}) async {
  final response = await http.post(
    Uri.parse(Env.apiRoot + url),
    headers: getHeaders(),
    body: jsonEncode(body),
  );
  if (response.statusCode != 200) {
    await _checkAuthError(response, url);
    throw Exception('${response.statusCode} $url ${response.body}');
  }
  return _parseResponse(response);
}

Future<T> put<T>(String url, {Map<String, dynamic> body = const {}}) async {
  final response = await http.put(
    Uri.parse(Env.apiRoot + url),
    headers: getHeaders(),
    body: jsonEncode(body),
  );
  if (response.statusCode != 200) {
    await _checkAuthError(response, url);
    throw Exception('${response.statusCode} $url ${response.body}');
  }
  return _parseResponse(response);
}

Future<T> patch<T>(String url, {Map<String, dynamic> body = const {}}) async {
  final response = await http.patch(
    Uri.parse(Env.apiRoot + url),
    headers: getHeaders(),
    body: jsonEncode(body),
  );
  if (response.statusCode != 200) {
    await _checkAuthError(response, url);
    throw Exception('${response.statusCode} $url ${response.body}');
  }
  return _parseResponse(response);
}

Future<T> get<T>(String url) async {
  final response = await http.get(
    Uri.parse(Env.apiRoot + url),
    headers: getHeaders(),
  );
  if (response.statusCode != 200) {
    await _checkAuthError(response, url);
    throw Exception('${response.statusCode} $url ${response.body}');
  }
  return _parseResponse(response);
}

Future<T> delete<T>(String url) async {
  final response = await http.delete(
    Uri.parse(Env.apiRoot + url),
    headers: getHeaders(),
  );
  if (response.statusCode != 200) {
    await _checkAuthError(response, url);
    throw Exception('${response.statusCode} $url ${response.body}');
  }
  return _parseResponse(response);
}
