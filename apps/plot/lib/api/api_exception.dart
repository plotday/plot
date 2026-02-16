/// Exception thrown by API calls with structured error information
class ApiException implements Exception {
  final int statusCode;
  final String endpoint;
  final String title;
  final String description;

  /// PostgreSQL error code from the API (e.g. '42501', '23503')
  final String? pgCode;

  ApiException({
    required this.statusCode,
    required this.endpoint,
    required this.title,
    required this.description,
    this.pgCode,
  });

  @override
  String toString() =>
      'ApiException($statusCode $endpoint): $title - $description${pgCode != null ? ' [pg:$pgCode]' : ''}';
}
