/// Exception thrown by API calls with structured error information
class ApiException implements Exception {
  final int statusCode;
  final String endpoint;
  final String title;
  final String description;

  /// PostgreSQL error code from the API (e.g. '42501', '23503')
  final String? pgCode;

  /// Machine-readable error code from the API (e.g. 'plan_limit_exceeded')
  final String? code;

  /// The type of limit that was exceeded (e.g. 'connections', 'twists')
  final String? limitType;

  /// Whether the limit applies to an organization (true) or personal account (false)
  final bool? isOrg;

  /// Whether the current user is an admin of the affected organization
  final bool? isAdmin;

  /// The organization ID associated with the limit, if applicable
  final String? organizationId;

  ApiException({
    required this.statusCode,
    required this.endpoint,
    required this.title,
    required this.description,
    this.pgCode,
    this.code,
    this.limitType,
    this.isOrg,
    this.isAdmin,
    this.organizationId,
  });

  /// Returns true if this exception represents a plan limit being exceeded
  bool get isPlanLimitExceeded => code == 'plan_limit_exceeded';

  @override
  String toString() =>
      'ApiException($statusCode $endpoint): $title - $description'
      '${pgCode != null ? ' [pg:$pgCode]' : ''}'
      '${code != null ? ' [code:$code]' : ''}';
}
