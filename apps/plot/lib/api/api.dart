import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';

import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/app_info.dart';
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

/// Extracts PostgreSQL error code from API response JSON (pg_code field)
String? _parsePgCode(http.Response response) {
  try {
    if (_isJsonContentType(response.headers['content-type'])) {
      final json = jsonDecode(response.body);
      if (json is Map && json.containsKey('pg_code')) {
        return json['pg_code'] as String;
      }
    }
  } catch (e) {
    // Ignore parse errors
  }
  return null;
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

/// Checks response for auth errors on 401 (Unauthorized).
/// clerk_auth handles token refresh automatically.
/// If we got a 401, the token was expired and clerk couldn't refresh it.
Future<void> _checkAuthError(http.Response response, String url) async {
  if (response.statusCode == 401) {
    log.warning("Auth error from API: 401 Unauthorized $url ${response.body}");
    // clerk_auth handles token refresh automatically.
    // Don't sign out automatically — let the user stay signed in locally.
    // The next request will try to get a fresh token from clerk_auth.
  }
}

Future<Map<String, String>> getHeaders() async {
  final token = await Base.getSessionToken();
  return {
    'Content-Type': 'application/json; charset=UTF-8',
    if (token != null) 'Authorization': 'Bearer $token',
    'X-Plot-Client':
        '${AppInfo.version}/${AppInfo.buildNumber} (${AppInfo.platform})',
  };
}

Future<T> post<T>(String url, {Map<String, dynamic> body = const {}}) async {
  try {
    final response = await http.post(
      Uri.parse(Env.apiRoot + url),
      headers: await getHeaders(),
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
        pgCode: _parsePgCode(response),
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
      headers: await getHeaders(),
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
        pgCode: _parsePgCode(response),
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
      headers: await getHeaders(),
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
        pgCode: _parsePgCode(response),
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
      headers: await getHeaders(),
    );
    if (response.statusCode != 200) {
      await _checkAuthError(response, url);
      final errorMessage = _parseErrorMessage(response);
      throw ApiException(
        statusCode: response.statusCode,
        endpoint: url,
        title: _getErrorTitle(response.statusCode),
        description: errorMessage,
        pgCode: _parsePgCode(response),
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
      headers: await getHeaders(),
    );
    if (response.statusCode != 200) {
      await _checkAuthError(response, url);
      final errorMessage = _parseErrorMessage(response);
      throw ApiException(
        statusCode: response.statusCode,
        endpoint: url,
        title: _getErrorTitle(response.statusCode),
        description: errorMessage,
        pgCode: _parsePgCode(response),
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

Future<T> deleteWithBody<T>(
  String url, {
  Map<String, dynamic> body = const {},
}) async {
  try {
    final response = await http.delete(
      Uri.parse(Env.apiRoot + url),
      headers: await getHeaders(),
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
        pgCode: _parsePgCode(response),
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

/// Upload a file attachment, returning file metadata.
Future<Map<String, dynamic>> uploadFile({
  required String filePath,
  required String fileName,
  required String priorityId,
  Uint8List? bytes,
}) async {
  try {
    final uri = Uri.parse('${Env.apiRoot}/files');
    final request = http.MultipartRequest('POST', uri);
    request.headers.addAll(await getHeaders()..remove('Content-Type'));
    request.fields['priorityId'] = priorityId;

    final contentType = lookupMimeType(fileName);
    final mediaType = contentType != null
        ? http.MediaType.parse(contentType)
        : null;

    if (bytes != null) {
      request.files.add(
        http.MultipartFile.fromBytes('file', bytes,
            filename: fileName, contentType: mediaType),
      );
    } else {
      request.files.add(
        await http.MultipartFile.fromPath('file', filePath,
            filename: fileName, contentType: mediaType),
      );
    }

    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);

    if (response.statusCode != 200) {
      await _checkAuthError(response, '/files');
      final errorMessage = _parseErrorMessage(response);
      throw ApiException(
        statusCode: response.statusCode,
        endpoint: '/files',
        title: _getErrorTitle(response.statusCode),
        description: errorMessage,
      );
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  } on SocketException catch (e) {
    throw NetworkException(originalException: e);
  } on HttpException catch (e) {
    throw NetworkException(originalException: e);
  } on http.ClientException catch (e) {
    throw NetworkException(originalException: e);
  }
}

/// Download a file attachment, returning the raw bytes.
Future<Uint8List> getFileBytes(String fileId) async {
  try {
    final headers = await getHeaders()..remove('Content-Type');
    final response = await http.get(
      Uri.parse('${Env.apiRoot}/files/$fileId'),
      headers: headers,
    );
    if (response.statusCode != 200) {
      await _checkAuthError(response, '/files/$fileId');
      final errorMessage = _parseErrorMessage(response);
      throw ApiException(
        statusCode: response.statusCode,
        endpoint: '/files/$fileId',
        title: _getErrorTitle(response.statusCode),
        description: errorMessage,
      );
    }
    return response.bodyBytes;
  } on SocketException catch (e) {
    throw NetworkException(originalException: e);
  } on HttpException catch (e) {
    throw NetworkException(originalException: e);
  } on http.ClientException catch (e) {
    throw NetworkException(originalException: e);
  }
}
