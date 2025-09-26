import 'dart:convert';
import 'package:http/http.dart' as http;

import 'package:plot/base.dart';
import 'package:plot/env.dart';

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
    throw Exception('${response.statusCode} $url ${response.body}');
  }
  return _parseResponse(response);
}
