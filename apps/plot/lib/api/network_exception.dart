/// Exception thrown when network connectivity issues prevent API communication
class NetworkException implements Exception {
  final String message;
  final Exception? originalException;

  const NetworkException({
    this.message = 'Could not connect to the Plot server',
    this.originalException,
  });

  @override
  String toString() => 'NetworkException: $message';
}
