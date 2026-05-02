import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
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

/// Parsed structured error fields from API response JSON
typedef _ErrorFields = ({
  String? code,
  String? limitType,
  bool? isTeam,
  bool? isAdmin,
  String? teamId,
});

/// Extracts structured error fields from API response JSON
_ErrorFields _parseErrorFields(http.Response response) {
  try {
    if (_isJsonContentType(response.headers['content-type'])) {
      final json = jsonDecode(response.body);
      if (json is Map) {
        return (
          code: json['code'] as String?,
          limitType: json['limit_type'] as String?,
          isTeam: json['is_team'] as bool?,
          isAdmin: json['is_admin'] as bool?,
          teamId: json['team_id'] as String?,
        );
      }
    }
  } catch (e) {
    // Ignore parse errors
  }
  return (
    code: null,
    limitType: null,
    isTeam: null,
    isAdmin: null,
    teamId: null,
  );
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

/// On 401, verify the session with Clerk to distinguish stale-token races
/// from dead sessions. If the session is definitively invalid, triggers
/// sign-out via [Base.handleTokenResult].
///
/// If the server returns `code: "user_not_found"` (JWT valid but no matching
/// DB user — e.g. after a DB reset or account deletion), signs out immediately
/// without consulting Clerk, since no token refresh can fix a missing user row.
///
/// Returns the recheck [TokenResult] (or `null` if no recheck was performed,
/// e.g. for `user_not_found`). Callers use this to distinguish "Clerk handed
/// us a fresh token that the server still rejected" (real session death) from
/// "Clerk still couldn't produce a token" (transient SDK warmup race after
/// sign-in) so they don't escalate the latter into a forced sign-out.
Future<TokenResult?> _checkAuthError(http.Response response, String url) async {
  if (response.statusCode == 401) {
    log.warning("Auth error from API: 401 Unauthorized $url");
    if (_parseErrorFields(response).code == 'user_not_found') {
      log.warning("Auth error: user not found in DB — forcing sign-out");
      Base.handleTokenResult(
        (token: null, failure: TokenFailureReason.sessionInvalid),
      );
      return null;
    }
    final result = await Base.getSessionTokenWithReason();
    Base.handleTokenResult(result);
    return result;
  }
  return null;
}

/// On 401, refresh the token and retry once. If the retry also 401s, return it.
Future<http.Response> _retryOn401(
  Future<http.Response> Function(Map<String, String> headers) request,
  String url,
) async {
  var headers = await getHeaders();
  var response = await request(headers);

  if (response.statusCode == 401) {
    final recheck = await _checkAuthError(response, url);
    // _checkAuthError refreshes the token; retry with fresh headers
    headers = await getHeaders();
    response = await request(headers);
    // Two consecutive 401s, AND Clerk just handed us a fresh token — the
    // server is rejecting a real JWT, so the session is definitively dead.
    // If recheck couldn't produce a token (transient Clerk SDK warmup race
    // right after sign-in, network blip, etc.), the retry went out
    // anonymously, so this 401 says nothing about session validity. Let the
    // caller's own backoff handle it instead of escalating to sign-out.
    if (response.statusCode == 401 && recheck?.token != null) {
      log.warning("Auth error: 401 on retry of $url — forcing sign-out");
      Base.handleTokenResult(
        (token: null, failure: TokenFailureReason.sessionInvalid),
      );
    }
  }

  return response;
}

final _random = Random();

/// Retries a request up to 3 times on 429 with exponential backoff + jitter.
/// Returns the successful response, or the final failed response.
Future<http.Response> _retryOn429(
  Future<http.Response> Function() request,
) async {
  var response = await request();
  if (response.statusCode != 429) return response;

  final retryAfter = int.tryParse(response.headers['retry-after'] ?? '') ?? 5;

  for (var attempt = 0; attempt < 3; attempt++) {
    final backoff = retryAfter * (1 << attempt); // 5s, 10s, 20s
    final jitter = _random.nextDouble(); // 0-1s
    await Future<void>.delayed(
      Duration(milliseconds: (backoff * 1000 + jitter * 1000).round()),
    );
    response = await request();
    if (response.statusCode != 429) return response;
  }

  return response;
}

Future<Map<String, String>> getHeaders() async {
  final token = await Base.getSessionToken();
  return {
    'Content-Type': 'application/json; charset=UTF-8',
    if (token != null) 'Authorization': 'Bearer $token',
    'X-Plot-Client':
        '${AppInfo.version}/${AppInfo.buildNumber} (${AppInfo.platform})',
    'X-Plot-API-Version': '3',
  };
}

Future<T> post<T>(String url, {Object body = const <String, dynamic>{}}) async {
  try {
    final response = await _retryOn401(
      (headers) => _retryOn429(() => http.post(
        Uri.parse(Env.apiRoot + url),
        headers: headers,
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 30))),
      url,
    );
    if (response.statusCode != 200) {
      final errorMessage = _parseErrorMessage(response);
      final errorFields = _parseErrorFields(response);
      throw ApiException(
        statusCode: response.statusCode,
        endpoint: url,
        title: _getErrorTitle(response.statusCode),
        description: errorMessage,
        pgCode: _parsePgCode(response),
        code: errorFields.code,
        limitType: errorFields.limitType,
        isTeam: errorFields.isTeam,
        isAdmin: errorFields.isAdmin,
        teamId: errorFields.teamId,
      );
    }
    return _parseResponse(response);
  } on TimeoutException {
    throw const NetworkException(message: 'Request timed out. Check your network connection and try again.');
  } on SocketException catch (e) {
    throw NetworkException(originalException: e);
  } on HttpException catch (e) {
    throw NetworkException(originalException: e);
  } on http.ClientException catch (e) {
    throw NetworkException(originalException: e);
  }
}

Future<T> put<T>(String url, {Object body = const <String, dynamic>{}}) async {
  try {
    final response = await _retryOn401(
      (headers) => _retryOn429(() => http.put(
        Uri.parse(Env.apiRoot + url),
        headers: headers,
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 30))),
      url,
    );
    if (response.statusCode != 200) {
      final errorMessage = _parseErrorMessage(response);
      final errorFields = _parseErrorFields(response);
      throw ApiException(
        statusCode: response.statusCode,
        endpoint: url,
        title: _getErrorTitle(response.statusCode),
        description: errorMessage,
        pgCode: _parsePgCode(response),
        code: errorFields.code,
        limitType: errorFields.limitType,
        isTeam: errorFields.isTeam,
        isAdmin: errorFields.isAdmin,
        teamId: errorFields.teamId,
      );
    }
    return _parseResponse(response);
  } on TimeoutException {
    throw const NetworkException(message: 'Request timed out. Check your network connection and try again.');
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
    final response = await _retryOn401(
      (headers) => _retryOn429(() => http.patch(
        Uri.parse(Env.apiRoot + url),
        headers: headers,
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 30))),
      url,
    );
    if (response.statusCode != 200) {
      final errorMessage = _parseErrorMessage(response);
      final errorFields = _parseErrorFields(response);
      throw ApiException(
        statusCode: response.statusCode,
        endpoint: url,
        title: _getErrorTitle(response.statusCode),
        description: errorMessage,
        pgCode: _parsePgCode(response),
        code: errorFields.code,
        limitType: errorFields.limitType,
        isTeam: errorFields.isTeam,
        isAdmin: errorFields.isAdmin,
        teamId: errorFields.teamId,
      );
    }
    return _parseResponse(response);
  } on TimeoutException {
    throw const NetworkException(message: 'Request timed out. Check your network connection and try again.');
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
    final response = await _retryOn401(
      (headers) => _retryOn429(() => http.get(
        Uri.parse(Env.apiRoot + url),
        headers: headers,
      ).timeout(const Duration(seconds: 30))),
      url,
    );
    if (response.statusCode != 200) {
      final errorMessage = _parseErrorMessage(response);
      final errorFields = _parseErrorFields(response);
      throw ApiException(
        statusCode: response.statusCode,
        endpoint: url,
        title: _getErrorTitle(response.statusCode),
        description: errorMessage,
        pgCode: _parsePgCode(response),
        code: errorFields.code,
        limitType: errorFields.limitType,
        isTeam: errorFields.isTeam,
        isAdmin: errorFields.isAdmin,
        teamId: errorFields.teamId,
      );
    }
    return _parseResponse(response);
  } on TimeoutException {
    throw const NetworkException(message: 'Request timed out. Check your network connection and try again.');
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
    final response = await _retryOn401(
      (headers) => _retryOn429(() => http.delete(
        Uri.parse(Env.apiRoot + url),
        headers: headers,
      ).timeout(const Duration(seconds: 30))),
      url,
    );
    if (response.statusCode != 200) {
      final errorMessage = _parseErrorMessage(response);
      final errorFields = _parseErrorFields(response);
      throw ApiException(
        statusCode: response.statusCode,
        endpoint: url,
        title: _getErrorTitle(response.statusCode),
        description: errorMessage,
        pgCode: _parsePgCode(response),
        code: errorFields.code,
        limitType: errorFields.limitType,
        isTeam: errorFields.isTeam,
        isAdmin: errorFields.isAdmin,
        teamId: errorFields.teamId,
      );
    }
    return _parseResponse(response);
  } on TimeoutException {
    throw const NetworkException(message: 'Request timed out. Check your network connection and try again.');
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
    final response = await _retryOn401(
      (headers) => _retryOn429(() => http.delete(
        Uri.parse(Env.apiRoot + url),
        headers: headers,
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 30))),
      url,
    );
    if (response.statusCode != 200) {
      final errorMessage = _parseErrorMessage(response);
      final errorFields = _parseErrorFields(response);
      throw ApiException(
        statusCode: response.statusCode,
        endpoint: url,
        title: _getErrorTitle(response.statusCode),
        description: errorMessage,
        pgCode: _parsePgCode(response),
        code: errorFields.code,
        limitType: errorFields.limitType,
        isTeam: errorFields.isTeam,
        isAdmin: errorFields.isAdmin,
        teamId: errorFields.teamId,
      );
    }
    return _parseResponse(response);
  } on TimeoutException {
    throw const NetworkException(message: 'Request timed out. Check your network connection and try again.');
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

    final streamed = await request.send().timeout(const Duration(seconds: 120));
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
  } on TimeoutException {
    throw const NetworkException(message: 'Upload timed out. Check your network connection and try again.');
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
    ).timeout(const Duration(seconds: 120));
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
  } on TimeoutException {
    throw const NetworkException(message: 'Download timed out. Check your network connection and try again.');
  } on SocketException catch (e) {
    throw NetworkException(originalException: e);
  } on HttpException catch (e) {
    throw NetworkException(originalException: e);
  } on http.ClientException catch (e) {
    throw NetworkException(originalException: e);
  }
}
