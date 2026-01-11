/// Exception thrown when network connectivity issues prevent API communication
class NetworkException implements Exception {
  final String message;
  final Exception? originalException;

  const NetworkException({
    this.message =
        'Could not connect. Check your network connection and try again.',
    this.originalException,
  });

  @override
  String toString() => 'NetworkException: $message';
}
