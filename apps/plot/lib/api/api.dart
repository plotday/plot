import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
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

/// Extracts error message from API response
/// Looks for JSON { "message": "..." } or { "error": "..." }, falls back to raw body
String _parseErrorMessage(http.Response response) {
  try {
    if (_isJsonContentType(response.headers['content-type'])) {
      final json = jsonDecode(response.body);
      if (json is Map) {
        if (json.containsKey('message')) {
          return json['message'] as String;
        }
        if (json.containsKey('error')) {
          return json['error'] as String;
        }
      }
    }
  } catch (e) {
    // JSON parsing failed, fall back to raw body
  }
  return response.body;
}

/// Maps HTTP status codes to user-friendly error titles
String _getErrorTitle(int statusCode) {
  switch (statusCode) {
    case 400:
      return 'Invalid Request';
    case 401:
      return 'Unauthorized';
    case 403:
      return 'Access Denied';
    case 404:
      return 'Not Found';
    case 500:
      return 'Server Error';
    default:
      return 'Error';
  }
}

/// Checks response for auth errors and signs out on 401 (Unauthorized)
/// Note: 403 (Forbidden) means user is authenticated but not authorized,
/// so we just let it throw - the calling code can display an error to the user
Future<void> _checkAuthError(http.Response response, String url) async {
  if (response.statusCode == 401) {
    log.warning("Auth error from API: 401 Unauthorized $url ${response.body}");
    try {
      await Base.signOut();
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
  try {
    final response = await http.post(
      Uri.parse(Env.apiRoot + url),
      headers: getHeaders(),
      body: jsonEncode(body),
    );
    if (response.statusCode != 200) {
      await _checkAuthError(response, url);
      final errorMessage = _parseErrorMessage(response);
      throw ApiException(
        statusCode: response.statusCode,
        endpoint: url,
        title: _getErrorTitle(response.statusCode),
        description: errorMessage,
      );
    }
    return _parseResponse(response);
  } on SocketException catch (e) {
    throw NetworkException(originalException: e);
  } on HttpException catch (e) {
    throw NetworkException(originalException: e);
  } on http.ClientException catch (e) {
    throw NetworkException(originalException: e);
  }
}

Future<T> put<T>(String url, {Map<String, dynamic> body = const {}}) async {
  try {
    final response = await http.put(
      Uri.parse(Env.apiRoot + url),
      headers: getHeaders(),
      body: jsonEncode(body),
    );
    if (response.statusCode != 200) {
      await _checkAuthError(response, url);
      final errorMessage = _parseErrorMessage(response);
      throw ApiException(
        statusCode: response.statusCode,
        endpoint: url,
        title: _getErrorTitle(response.statusCode),
        description: errorMessage,
      );
    }
    return _parseResponse(response);
  } on SocketException catch (e) {
    throw NetworkException(originalException: e);
  } on HttpException catch (e) {
    throw NetworkException(originalException: e);
  } on http.ClientException catch (e) {
    throw NetworkException(originalException: e);
  }
}

Future<T> patch<T>(String url, {Map<String, dynamic> body = const {}}) async {
  try {
    final response = await http.patch(
      Uri.parse(Env.apiRoot + url),
      headers: getHeaders(),
      body: jsonEncode(body),
    );
    if (response.statusCode != 200) {
      await _checkAuthError(response, url);
      final errorMessage = _parseErrorMessage(response);
      throw ApiException(
        statusCode: response.statusCode,
        endpoint: url,
        title: _getErrorTitle(response.statusCode),
        description: errorMessage,
      );
    }
    return _parseResponse(response);
  } on SocketException catch (e) {
    throw NetworkException(originalException: e);
  } on HttpException catch (e) {
    throw NetworkException(originalException: e);
  } on http.ClientException catch (e) {
    throw NetworkException(originalException: e);
  }
}

Future<T> get<T>(String url) async {
  try {
    final response = await http.get(
      Uri.parse(Env.apiRoot + url),
      headers: getHeaders(),
    );
    if (response.statusCode != 200) {
      await _checkAuthError(response, url);
      final errorMessage = _parseErrorMessage(response);
      throw ApiException(
        statusCode: response.statusCode,
        endpoint: url,
        title: _getErrorTitle(response.statusCode),
        description: errorMessage,
      );
    }
    return _parseResponse(response);
  } on SocketException catch (e) {
    throw NetworkException(originalException: e);
  } on HttpException catch (e) {
    throw NetworkException(originalException: e);
  } on http.ClientException catch (e) {
    throw NetworkException(originalException: e);
  }
}

Future<T> delete<T>(String url) async {
  try {
    final response = await http.delete(
      Uri.parse(Env.apiRoot + url),
      headers: getHeaders(),
    );
    if (response.statusCode != 200) {
      await _checkAuthError(response, url);
      final errorMessage = _parseErrorMessage(response);
      throw ApiException(
        statusCode: response.statusCode,
        endpoint: url,
        title: _getErrorTitle(response.statusCode),
        description: errorMessage,
      );
    }
    return _parseResponse(response);
  } on SocketException catch (e) {
    throw NetworkException(originalException: e);
  } on HttpException catch (e) {
    throw NetworkException(originalException: e);
  } on http.ClientException catch (e) {
    throw NetworkException(originalException: e);
  }
}
