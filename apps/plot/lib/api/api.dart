import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';

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
    request.headers.addAll(getHeaders()..remove('Content-Type'));
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
    final headers = getHeaders()..remove('Content-Type');
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
