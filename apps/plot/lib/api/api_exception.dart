/// Exception thrown by API calls with structured error information
class ApiException implements Exception {
  final int statusCode;
  final String endpoint;
  final String title;
  final String description;

  ApiException({
    required this.statusCode,
    required this.endpoint,
    required this.title,
    required this.description,
  });

  @override
  String toString() =>
      'ApiException($statusCode $endpoint): $title - $description';
}
