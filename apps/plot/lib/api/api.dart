import 'dart:convert';
import 'package:http/http.dart' as http;

import 'package:plot/base.dart';

import '../env.dart';

Map<String, String> getHeaders() {
  final auth =
      'Bearer ${Base.client.auth.currentSession?.accessToken}/${Base.client.auth.currentSession?.refreshToken}';
  return {
    'Content-Type': 'application/json; charset=UTF-8',
    'Authorization': auth,
  };
}

Future<Map<String, dynamic>> post(String url,
    {Map<String, dynamic> body = const {}}) async {
  final response = await http.post(
    Uri.parse(Env.apiRoot + url),
    headers: getHeaders(),
    body: jsonEncode(body),
  );
  if (response.statusCode != 200) {
    throw Exception('${response.statusCode} $url ${response.body}');
  }
  return jsonDecode(response.body) as Map<String, dynamic>;
}

Future<Map<String, dynamic>> put(String url,
    {Map<String, dynamic> body = const {}}) async {
  final response = await http.put(
    Uri.parse(Env.apiRoot + url),
    headers: getHeaders(),
    body: jsonEncode(body),
  );
  if (response.statusCode != 200) {
    throw Exception('${response.statusCode} $url ${response.body}');
  }
  return jsonDecode(response.body) as Map<String, dynamic>;
}

Future<Map<String, dynamic>> patch(String url,
    {Map<String, dynamic> body = const {}}) async {
  final response = await http.patch(
    Uri.parse(Env.apiRoot + url),
    headers: getHeaders(),
    body: jsonEncode(body),
  );
  if (response.statusCode != 200) {
    throw Exception('${response.statusCode} $url ${response.body}');
  }
  return jsonDecode(response.body) as Map<String, dynamic>;
}

Future<dynamic> get(String url) async {
  final response = await http.get(
    Uri.parse(Env.apiRoot + url),
    headers: getHeaders(),
  );
  if (response.statusCode != 200) {
    throw Exception('${response.statusCode} $url ${response.body}');
  }
  return jsonDecode(response.body);
}

Future<dynamic> delete(String url) async {
  final response = await http.delete(
    Uri.parse(Env.apiRoot + url),
    headers: getHeaders(),
  );
  if (response.statusCode != 200) {
    throw Exception('${response.statusCode} $url ${response.body}');
  }
  return jsonDecode(response.body);
}
