import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../env.dart';

final supabase = Supabase.instance.client;

Map<String, String> _getHeaders() {
  final auth =
      'Bearer ${supabase.auth.currentSession?.accessToken}/${supabase.auth.currentSession?.refreshToken}';
  return {
    'Content-Type': 'application/json; charset=UTF-8',
    'Authorization': auth,
  };
}

Future<Map<String, dynamic>> post(String url,
    {Map<String, String> body = const {}}) async {
  final response = await http.post(
    Uri.parse(Env.apiRoot + url),
    headers: _getHeaders(),
    body: jsonEncode(body),
  );
  if (response.statusCode != 200) {
    throw Exception('${response.statusCode} $url ${response.body}');
  }
  return jsonDecode(response.body);
}

Future<Map<String, dynamic>> put(String url,
    {Map<String, String> body = const {}}) async {
  final response = await http.put(
    Uri.parse(Env.apiRoot + url),
    headers: _getHeaders(),
    body: jsonEncode(body),
  );
  if (response.statusCode != 200) {
    throw Exception('${response.statusCode} $url ${response.body}');
  }
  return jsonDecode(response.body);
}
